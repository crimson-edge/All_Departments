#!/usr/bin/env bash
# =============================================================================
# CEV System Restore Script
# =============================================================================
# Performs full system recovery on a fresh Linux/WSL2/macOS machine from a
# CEV backup tarball.
#
# PREREQUISITES (user installs manually):
#   - curl, git, build-essential (Linux/WSL2)
#   - curl, git (macOS)
#   - Nothing else -- this script handles the rest
#
# USAGE:
#   ./restore-stack.sh cev-stack-backup-20260425.tar.gz.gpg
#
# The script decrypts with gpg, extracts, installs, restores, and verifies.
# MUST be idempotent -- safe to run on a partially restored system.
# =============================================================================

set -euo pipefail

# ────────────────────────────
# Configuration
# ────────────────────────────
SCRIPT_NAME="$(basename "$0")"
RESTORE_DIR="/tmp/cev-restore-$$"
LOG_FILE="/tmp/cev-restore.log"
HEALTH_PORT_PAPERCLIP=3100
HEALTH_PORT_HERMES=3000
HEALTH_PORT_OLLAMA=11434

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ────────────────────────────
# Helpers
# ────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
info()  { echo -e "${BLUE}[INFO]${NC}  $1"  | tee -a "$LOG_FILE"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"  | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}[ERR]${NC}   $1"   | tee -a "$LOG_FILE"; }

fail() {
  err "$1"
  echo "See log: $LOG_FILE"
  exit 1
}

command_exists() { command -v "$1" &>/dev/null; }

# ────────────────────────────
# 1. Detect OS
# ────────────────────────────
detect_os() {
  info "Detecting operating system..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
      OS="wsl2"
      info "Detected: WSL2 (Ubuntu/Debian-based)"
    else
      OS="linux"
      info "Detected: Linux (Ubuntu/Debian-based)"
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
    info "Detected: macOS"
  else
    fail "Unsupported OS: $OSTYPE"
  fi
}

# ────────────────────────────
# 2. Install Base Dependencies
# ────────────────────────────
install_node() {
  if command_exists node && node --version | grep -q "v22"; then
    ok "Node.js 22 already installed: $(node --version)"
    return
  fi

  info "Installing Node.js 22..."
  if [[ "$OS" == "macos" ]]; then
    if ! command_exists brew; then
      fail "Homebrew is required on macOS. Install from https://brew.sh"
    fi
    brew install node@22
    brew link --overwrite node@22 2>/dev/null || true
  else
    # Ubuntu/Debian/WSL2
    if ! grep -q "nodesource" /etc/apt/sources.list.d/*.list 2>/dev/null; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    fi
    sudo apt-get update -qq
    sudo apt-get install -y -qq nodejs
  fi

  ok "Node.js installed: $(node --version)"
}

install_pnpm() {
  if command_exists pnpm && pnpm --version | grep -q "^10"; then
    ok "pnpm 10 already installed: $(pnpm --version)"
    return
  fi

  info "Installing pnpm..."
  if ! command_exists corepack; then
    info "Enabling corepack..."
    sudo npm install -g corepack 2>/dev/null || npm install -g corepack
  fi
  corepack enable pnpm
  corepack install -g pnpm@10.33.0 2>/dev/null || true

  # Ensure pnpm is in PATH
  PNPM_DIR="$HOME/.local/share/pnpm"
  mkdir -p "$PNPM_DIR"
  export PATH="$PNPM_DIR:$PATH"

  if command_exists pnpm; then
    ok "pnpm installed: $(pnpm --version)"
  else
    fail "pnpm installation failed"
  fi
}

install_python() {
  if command_exists python3 && python3 --version | grep -qE "3\.(1[1-9]|[2-9][0-9])"; then
    ok "Python 3.11+ already installed: $(python3 --version)"
    return
  fi

  info "Installing Python 3.11+..."
  if [[ "$OS" == "macos" ]]; then
    brew install python@3.12
  else
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3 python3-venv python3-pip python3-dev
  fi

  ok "Python installed: $(python3 --version)"
}

install_postgresql() {
  if command_exists psql; then
    ok "PostgreSQL already installed: $(psql --version | head -1)"
    return
  fi

  info "Installing PostgreSQL..."
  if [[ "$OS" == "macos" ]]; then
    brew install postgresql@16
    brew services start postgresql@16 2>/dev/null || true
  else
    # Ubuntu/Debian
    if ! grep -q "postgresql" /etc/apt/sources.list.d/*.list 2>/dev/null; then
      sudo apt-get install -y -qq postgresql-common
      sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y 2>/dev/null || true
    fi
    sudo apt-get update -qq
    sudo apt-get install -y -qq postgresql-16 postgresql-client-16
    sudo systemctl enable postgresql 2>/dev/null || true
    sudo systemctl start postgresql 2>/dev/null || true
  fi

  ok "PostgreSQL installed"
}

install_nginx() {
  if command_exists nginx; then
    ok "nginx already installed: $(nginx -v 2>&1 | head -1)"
    return
  fi

  info "Installing nginx..."
  if [[ "$OS" == "macos" ]]; then
    brew install nginx
    brew services start nginx 2>/dev/null || true
  else
    sudo apt-get update -qq
    sudo apt-get install -y -qq nginx
    sudo systemctl enable nginx 2>/dev/null || true
    sudo systemctl start nginx 2>/dev/null || true
  fi

  ok "nginx installed"
}

install_snap() {
  if [[ "$OS" == "macos" ]]; then
    info "Skipping snap -- not available on macOS"
    return
  fi

  if command_exists snap; then
    ok "snap already installed"
  else
    info "Installing snapd..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq snapd
    sudo systemctl enable --now snapd.socket 2>/dev/null || true
  fi
}

install_build_tools() {
  if [[ "$OS" == "macos" ]]; then
    if ! command_exists gcc; then
      info "Installing Xcode Command Line Tools..."
      xcode-select --install 2>/dev/null || true
    fi
    ok "Build tools available"
    return
  fi

  if dpkg -l | grep -q "build-essential" 2>/dev/null; then
    ok "build-essential already installed"
  else
    info "Installing build-essential..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq build-essential curl git
  fi
}

# ────────────────────────────
# 3. Install Snap Packages
# ────────────────────────────
install_snap_packages() {
  if [[ "$OS" == "macos" ]]; then
    info "Installing Ollama via Homebrew (snap alternative)..."
    if ! command_exists ollama; then
      brew install ollama 2>/dev/null || true
    fi
    ok "Ollama installed"
    return
  fi

  info "Installing snap packages..."
  sudo snap install ollama
  sudo snap start ollama 2>/dev/null || true
  ok "Snap packages installed"
}

# ────────────────────────────
# 4. Restore PostgreSQL
# ────────────────────────────
restore_postgresql() {
  info "Restoring PostgreSQL databases..."

  local DB_DIR="$RESTORE_DIR/postgresql"
  if [[ ! -d "$DB_DIR" ]]; then
    warn "No PostgreSQL backup found at $DB_DIR -- skipping database restore"
    return
  fi

  # Ensure PostgreSQL is running
  if [[ "$OS" == "macos" ]]; then
    brew services start postgresql@16 2>/dev/null || true
  else
    sudo systemctl start postgresql 2>/dev/null || true
  fi
  sleep 2

  # Create databases if they don't exist
  for db in paperclip carrier_reputation; do
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db"; then
      info "Database '$db' already exists"
    else
      info "Creating database: $db"
      sudo -u postgres psql -c "CREATE DATABASE $db;" 2>/dev/null || \
        sudo -u postgres psql -c "CREATE DATABASE $db OWNER $(whoami);"
    fi

    # Restore dump if present
    local DUMP_FILE="$DB_DIR/${db}.sql"
    if [[ -f "$DUMP_FILE" ]]; then
      info "Restoring $db from dump..."
      sudo -u postgres psql "$db" < "$DUMP_FILE"
      ok "Database '$db' restored"
    else
      warn "No dump file found for '$db'"
    fi
  done
}

# ────────────────────────────
# 5. Extract Tarball
# ────────────────────────────
extract_tarball() {
  local INPUT="$1"

  info "Preparing restore directory: $RESTORE_DIR"
  mkdir -p "$RESTORE_DIR"

  if [[ "$INPUT" == *.gpg ]]; then
    info "Decrypting GPG-encrypted tarball..."
    local DECRYPTED="${RESTORE_DIR}/backup.tar.gz"
    gpg --batch --yes --decrypt -o "$DECRYPTED" "$INPUT" || fail "GPG decryption failed"
    INPUT="$DECRYPTED"
  fi

  info "Extracting tarball..."
  tar -xzf "$INPUT" -C "$RESTORE_DIR" --no-same-owner || fail "Extraction failed"

  ok "Backup extracted to $RESTORE_DIR"
}

restore_filesystem() {
  info "Restoring filesystem paths..."

  local paths=(
    "home/openclaw"
    "home/hermes"
    "home/scripts"
    "home/systemd-user"
    "home/crontab"
    "etc/nginx"
  )

  for src in "${paths[@]}"; do
    local src_path="$RESTORE_DIR/$src"
    if [[ ! -e "$src_path" ]]; then
      warn "Backup path not found: $src -- skipping"
      continue
    fi

    case "$src" in
      "home/openclaw")
        mkdir -p "$HOME/.openclaw"
        rsync -av --delete "$src_path/" "$HOME/.openclaw/" 2>/dev/null || \
          cp -r "$src_path/." "$HOME/.openclaw/" 2>/dev/null || warn "Could not restore ~/.openclaw"
        ok "Restored ~/.openclaw"
        ;;

      "home/hermes")
        mkdir -p "$HOME/.hermes"
        rsync -av --delete "$src_path/" "$HOME/.hermes/" 2>/dev/null || \
          cp -r "$src_path/." "$HOME/.hermes/" 2>/dev/null || warn "Could not restore ~/.hermes"
        ok "Restored ~/.hermes"
        ;;

      "home/scripts")
        mkdir -p "$HOME/scripts"
        rsync -av --delete "$src_path/" "$HOME/scripts/" 2>/dev/null || \
          cp -r "$src_path/." "$HOME/scripts/" 2>/dev/null || warn "Could not restore ~/scripts"
        ok "Restored ~/scripts"
        ;;

      "home/systemd-user")
        mkdir -p "$HOME/.config/systemd/user"
        if [[ "$OS" == "macos" ]]; then
          warn "systemd not available on macOS -- skipping service files"
        else
          rsync -av "$src_path/" "$HOME/.config/systemd/user/" 2>/dev/null || \
            cp -r "$src_path/." "$HOME/.config/systemd/user/" 2>/dev/null || warn "Could not restore systemd units"
          systemctl --user daemon-reload 2>/dev/null || true
          ok "Restored systemd user services"
        fi
        ;;

      "home/crontab")
        if [[ -f "$src_path" ]]; then
          crontab "$src_path" 2>/dev/null || warn "Could not restore crontab"
          ok "Restored crontab"
        fi
        ;;

      "etc/nginx")
        if [[ "$OS" != "macos" ]]; then
          sudo rsync -av --delete "$src_path/" "/etc/nginx/" 2>/dev/null || \
            sudo cp -r "$src_path/." "/etc/nginx/" 2>/dev/null || warn "Could not restore /etc/nginx"
          sudo nginx -t 2>/dev/null || warn "nginx config test failed -- check manually"
          ok "Restored /etc/nginx"
        fi
        ;;
    esac
  done
}

# ────────────────────────────
# 6. Rebuild Installable Components
# ────────────────────────────
rebuild_paperclip() {
  local PC_DIR="$HOME/.openclaw/workspace/paperclip"
  if [[ ! -f "$PC_DIR/package.json" ]]; then
    warn "Paperclip workspace not found at $PC_DIR -- skipping pnpm install"
    return
  fi

  info "Rebuilding Paperclip workspace..."
  cd "$PC_DIR"

  # Clean and reinstall
  rm -rf node_modules packages/*/node_modules 2>/dev/null || true
  pnpm install --frozen-lockfile || pnpm install
  ok "Paperclip dependencies installed"
}

rebuild_hermes() {
  local HERMES_DIR="$HOME/.hermes/hermes-agent"
  if [[ ! -f "$HERMES_DIR/pyproject.toml" && ! -f "$HERMES_DIR/setup.py" ]]; then
    warn "Hermes agent not found at $HERMES_DIR -- skipping Python install"
    return
  fi

  info "Rebuilding Hermes agent..."
  cd "$HERMES_DIR"

  # Recreate venv
  rm -rf venv 2>/dev/null || true
  python3 -m venv venv
  source venv/bin/activate

  if [[ -f "pyproject.toml" ]]; then
    pip install -e .[dev,messaging,cron,slack,matrix,cli,tts-premium,voice,pty,honcho] || \
      pip install -e .
  else
    pip install -e .
  fi

  deactivate
  ok "Hermes agent rebuilt"
}

# ────────────────────────────
# 7. Pull Ollama Models
# ────────────────────────────
pull_ollama_models() {
  if ! command_exists ollama; then
    warn "Ollama not found -- skipping model pulls"
    return
  fi

  info "Checking Ollama service..."
  if ! curl -s "http://localhost:$HEALTH_PORT_OLLAMA/api/tags" >/dev/null 2>&1; then
    if [[ "$OS" != "macos" ]]; then
      sudo snap start ollama 2>/dev/null || true
    else
      brew services start ollama 2>/dev/null || true
    fi
    sleep 5
  fi

  local MANIFEST="$RESTORE_DIR/ollama/manifest.json"
  if [[ ! -f "$MANIFEST" ]]; then
    warn "No Ollama manifest found -- skipping model pulls"
    return
  fi

  info "Pulling Ollama models from manifest..."
  local models
  models=$(jq -r '.models[]' "$MANIFEST" 2>/dev/null) || \
    models=$(cat "$MANIFEST" | grep -o '"[^"]*"' | tr -d '"' | grep -v models)

  for model in $models; do
    info "Pulling: $model"
    ollama pull "$model" || warn "Failed to pull model: $model"
  done

  ok "Ollama models pulled"
}

# ────────────────────────────
# 8. Enable and Start systemd Services
# ────────────────────────────
enable_services() {
  if [[ "$OS" == "macos" ]]; then
    info "Skipping systemd services (macOS uses launchd)"
    return
  fi

  info "Enabling systemd user services..."
  local services=(
    "hermes-gateway"
    "camofox"
    "paperclip"
    "openclaw-gateway"
  )

  for svc in "${services[@]}"; do
    local svc_file="$HOME/.config/systemd/user/${svc}.service"
    if [[ -f "$svc_file" ]]; then
      systemctl --user enable "$svc" 2>/dev/null || warn "Could not enable $svc"
      systemctl --user start "$svc" 2>/dev/null || warn "Could not start $svc"
      ok "Enabled and started: $svc"
    else
      warn "Service file not found: ${svc}.service"
    fi
  done
}

# ────────────────────────────
# 9. Start Paperclip
# ────────────────────────────
start_paperclip() {
  local PC_DIR="$HOME/.openclaw/workspace/paperclip"
  if [[ ! -d "$PC_DIR" ]]; then
    warn "Paperclip workspace not found -- skipping start"
    return
  fi

  info "Starting Paperclip (dev:once)..."
  cd "$PC_DIR"

  # Check if already running
  if curl -s "http://localhost:$HEALTH_PORT_PAPERCLIP/api/health" >/dev/null 2>&1; then
    ok "Paperclip already running"
    return
  fi

  # Start in background and wait for health
  nohup pnpm run dev:once > "$HOME/.openclaw/logs/paperclip-restore.log" 2>&1 &
  local PID=$!

  info "Waiting for Paperclip to come up (PID: $PID)..."
  for i in {1..60}; do
    if curl -s "http://localhost:$HEALTH_PORT_PAPERCLIP/api/health" >/dev/null 2>&1; then
      ok "Paperclip started successfully"
      return
    fi
    sleep 2
  done

  warn "Paperclip did not start within 2 minutes -- check logs: $HOME/.openclaw/logs/paperclip-restore.log"
}

# ────────────────────────────
# 10. Health Check
# ────────────────────────────
HEALTH_PAPERCLIP="UNKNOWN"
HEALTH_HERMES="UNKNOWN"
HEALTH_OLLAMA="UNKNOWN"
HEALTH_DB="UNKNOWN"
HEALTH_HERMES_SVC="UNKNOWN"

check_health() {
  info "Running health checks..."
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "            CEV RESTORE HEALTH CHECK"
  echo "═══════════════════════════════════════════════════════"

  # Paperclip
  if curl -s "http://localhost:$HEALTH_PORT_PAPERCLIP/api/health" >/dev/null 2>&1; then
    HEALTH_PAPERCLIP="OK"
    ok "Paperclip     : http://localhost:$HEALTH_PORT_PAPERCLIP/api/health"
  else
    HEALTH_PAPERCLIP="FAIL"
    err "Paperclip     : http://localhost:$HEALTH_PORT_PAPERCLIP/api/health"
  fi

  # Hermes Gateway
  local HERMES_RESP
  HERMES_RESP=$(curl -s "http://localhost:$HEALTH_PORT_HERMES" 2>/dev/null | head -c 50 || true)
  if [[ -n "$HERMES_RESP" ]]; then
    HEALTH_HERMES="OK"
    ok "Hermes        : http://localhost:$HEALTH_PORT_HERMES"
  else
    HEALTH_HERMES="FAIL"
    err "Hermes        : http://localhost:$HEALTH_PORT_HERMES"
  fi

  # Ollama
  if curl -s "http://localhost:$HEALTH_PORT_OLLAMA/api/tags" >/dev/null 2>&1; then
    HEALTH_OLLAMA="OK"
    ok "Ollama        : http://localhost:$HEALTH_PORT_OLLAMA/api/tags"
  else
    HEALTH_OLLAMA="FAIL"
    err "Ollama        : http://localhost:$HEALTH_PORT_OLLAMA/api/tags"
  fi

  # PostgreSQL
  local DB_COUNT
  DB_COUNT=$(sudo -u postgres psql -d carrier_reputation -tc "SELECT count(*) FROM phone_numbers" 2>/dev/null | xargs || true)
  if [[ -n "$DB_COUNT" ]]; then
    HEALTH_DB="OK ($DB_COUNT rows)"
    ok "PostgreSQL    : carrier_reputation.phone_numbers = $DB_COUNT rows"
  else
    HEALTH_DB="FAIL"
    err "PostgreSQL    : carrier_reputation.phone_numbers query failed"
  fi

  # Hermes Gateway service
  if [[ "$OS" != "macos" ]]; then
    if systemctl --user is-active hermes-gateway >/dev/null 2>&1; then
      HEALTH_HERMES_SVC="OK"
      ok "Hermes Svc    : systemctl --user status hermes-gateway = active"
    else
      HEALTH_HERMES_SVC="FAIL"
      err "Hermes Svc    : systemctl --user status hermes-gateway = inactive"
    fi
  else
    HEALTH_HERMES_SVC="N/A (macOS)"
    ok "Hermes Svc    : N/A (macOS)"
  fi

  echo "═══════════════════════════════════════════════════════"
}

# ────────────────────────────
# 11. Final Status Report
# ────────────────────────────
print_report() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "            CEV RESTORE STATUS REPORT"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  local overall="GREEN"
  for check in "$HEALTH_PAPERCLIP" "$HEALTH_HERMES" "$HEALTH_OLLAMA" "$HEALTH_DB" "$HEALTH_HERMES_SVC"; do
    if [[ "$check" == FAIL* ]]; then
      overall="RED"
      break
    fi
  done

  if [[ "$overall" == "GREEN" ]]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  STATUS: ALL CHECKS PASSED  🟢${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  STATUS: SOME CHECKS FAILED  🔴${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  fi

  echo ""
  echo "  Paperclip Dashboard : http://localhost:$HEALTH_PORT_PAPERCLIP"
  echo "  Hermes Gateway      : http://localhost:$HEALTH_PORT_HERMES"
  echo "  Ollama API          : http://localhost:$HEALTH_PORT_OLLAMA"
  echo ""
  echo "  Log file: $LOG_FILE"
  echo "═══════════════════════════════════════════════════════"
  echo ""
}

# ────────────────────────────
# Main
# ────────────────────────────
main() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: $SCRIPT_NAME <backup-tarball.tar.gz[.gpg]>"
    echo ""
    echo "Prerequisites (install manually before running):"
    echo "  - curl, git, build-essential (Linux/WSL2)"
    echo "  - curl, git (macOS)"
    echo ""
    exit 1
  fi

  local INPUT_FILE="$1"
  if [[ ! -f "$INPUT_FILE" ]]; then
    fail "Backup file not found: $INPUT_FILE"
  fi

  info "CEV System Restore starting..."
  info "Backup file: $INPUT_FILE"
  info "Log file: $LOG_FILE"
  echo ""

  # Phase 1: OS Detection
  detect_os

  # Phase 2: Install Base Dependencies
  install_build_tools
  install_node
  install_pnpm
  install_python
  install_postgresql
  install_nginx
  install_snap

  # Phase 3: Install Snap Packages
  install_snap_packages

  # Phase 4: Extract Backup
  extract_tarball "$INPUT_FILE"

  # Phase 5: Restore Filesystem
  restore_filesystem

  # Phase 6: Restore PostgreSQL
  restore_postgresql

  # Phase 7: Rebuild Components
  rebuild_paperclip
  rebuild_hermes

  # Phase 8: Pull Ollama Models
  pull_ollama_models

  # Phase 9: Enable Services
  enable_services

  # Phase 10: Start Paperclip
  start_paperclip

  # Phase 11: Health Check
  check_health

  # Report
  print_report

  # Cleanup
  rm -rf "$RESTORE_DIR"
  info "Cleanup complete. Restore directory removed."
}

main "$@"
