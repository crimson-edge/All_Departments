#!/usr/bin/env bash
# =============================================================================
# CEV System Backup Script
# =============================================================================
# Creates a full backup tarball of the CEV tech stack for disaster recovery.
#
# USAGE:
#   ./backup-stack.sh [output-dir]
#
# OUTPUT:
#   cev-stack-backup-YYYYMMDD.tar.gz
#   cev-stack-backup-YYYYMMDD.tar.gz.gpg (if GPG_KEY_ID is set)
#
# BACKUP INCLUDES:
#   - ~/.openclaw/     (workspace, agents, skills, configs, cron)
#   - ~/.hermes/       (config, sessions, hermes-agent)
#   - ~/scripts/       (all scripts)
#   - ~/.config/systemd/user/ (service files)
#   - /etc/nginx/      (nginx configs)
#   - crontab          (current user's cron jobs)
#   - PostgreSQL dumps (paperclip, carrier_reputation)
#   - Ollama model manifest (list of pulled models)
#   - snap package list
#   - system package manifest
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
OUTPUT_DIR="${1:-/home/walt/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="cev-stack-backup-${TIMESTAMP}"
WORK_DIR="/tmp/${BACKUP_NAME}-$$"
TARBALL="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
info() { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC}   $1"; }

fail() { err "$1"; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ────────────────────────────
# Setup
# ────────────────────────────
info "CEV System Backup starting..."
info "Backup name: $BACKUP_NAME"
info "Output: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$WORK_DIR"

# ────────────────────────────
# 1. Home directories
# ────────────────────────────
info "Backing up home directories..."

if [[ -d "$HOME/.openclaw" ]]; then
  cp -a "$HOME/.openclaw" "$WORK_DIR/home/openclaw"
  ok "Backed up ~/.openclaw"
else
  warn "~/.openclaw not found -- skipping"
fi

if [[ -d "$HOME/.hermes" ]]; then
  cp -a "$HOME/.hermes" "$WORK_DIR/home/hermes"
  ok "Backed up ~/.hermes"
else
  warn "~/.hermes not found -- skipping"
fi

if [[ -d "$HOME/scripts" ]]; then
  cp -a "$HOME/scripts" "$WORK_DIR/home/scripts"
  ok "Backed up ~/scripts"
else
  warn "~/scripts not found -- skipping"
fi

# ────────────────────────────
# 2. systemd user services
# ────────────────────────────
info "Backing up systemd user services..."

if [[ -d "$HOME/.config/systemd/user" ]]; then
  mkdir -p "$WORK_DIR/home/systemd-user"
  cp -a "$HOME/.config/systemd/user/"*.service "$WORK_DIR/home/systemd-user/" 2>/dev/null || true
  ok "Backed up systemd user services"
else
  warn "systemd user services not found -- skipping"
fi

# ────────────────────────────
# 3. Crontab
# ────────────────────────────
info "Backing up crontab..."

if crontab -l &>/dev/null; then
  crontab -l > "$WORK_DIR/home/crontab"
  ok "Backed up crontab"
else
  warn "No crontab found -- skipping"
fi

# ────────────────────────────
# 4. nginx configs
# ────────────────────────────
info "Backing up nginx configs..."

if [[ -d "/etc/nginx" ]]; then
  if command_exists sudo; then
    sudo cp -a /etc/nginx "$WORK_DIR/etc/nginx"
    sudo chown -R "$(whoami):" "$WORK_DIR/etc/nginx"
    ok "Backed up /etc/nginx"
  else
    warn "sudo not available -- skipping nginx backup"
  fi
else
  warn "/etc/nginx not found -- skipping"
fi

# ────────────────────────────
# 5. PostgreSQL dumps
# ────────────────────────────
info "Backing up PostgreSQL databases..."

mkdir -p "$WORK_DIR/postgresql"

for db in paperclip carrier_reputation; do
  if command_exists pg_dump; then
    if pg_dump "$db" > "$WORK_DIR/postgresql/${db}.sql" 2>/dev/null; then
      ok "Dumped database: $db"
    else
      warn "Could not dump database: $db"
    fi
  else
    warn "pg_dump not found -- skipping PostgreSQL backup"
    break
  fi
done

# ────────────────────────────
# 6. Ollama model manifest
# ────────────────────────────
info "Creating Ollama model manifest..."

mkdir -p "$WORK_DIR/ollama"
if command_exists ollama; then
  ollama list | tail -n +2 | awk '{print $1}' > "$WORK_DIR/ollama/models.txt" 2>/dev/null || true
  jq -R -s '{models: split("\n") | map(select(. != ""))}' "$WORK_DIR/ollama/models.txt" \
    > "$WORK_DIR/ollama/manifest.json" 2>/dev/null || \
    echo '{"models":[]}' > "$WORK_DIR/ollama/manifest.json"
  ok "Created Ollama model manifest"
else
  warn "Ollama not found -- skipping model manifest"
fi

# ────────────────────────────
# 7. Snap packages
# ────────────────────────────
info "Recording snap packages..."

if command_exists snap; then
  snap list > "$WORK_DIR/snap-packages.txt" 2>/dev/null || true
  ok "Recorded snap packages"
else
  warn "snap not found -- skipping"
fi

# ────────────────────────────
# 8. System package manifest
# ────────────────────────────
info "Recording system package manifest..."

if command_exists dpkg; then
  dpkg -l > "$WORK_DIR/dpkg-packages.txt" 2>/dev/null || true
  ok "Recorded dpkg packages"
elif command_exists brew; then
  brew list > "$WORK_DIR/brew-packages.txt" 2>/dev/null || true
  ok "Recorded brew packages"
fi

# ────────────────────────────
# 9. Create tarball
# ────────────────────────────
info "Creating tarball..."

cd "$WORK_DIR"
tar -czf "$TARBALL" .
ok "Created tarball: $TARBALL"

# ────────────────────────────
# 10. Optional GPG encryption
# ────────────────────────────
if [[ -n "${GPG_KEY_ID:-}" ]]; then
  info "Encrypting tarball with GPG..."
  gpg --batch --yes --recipient "$GPG_KEY_ID" --encrypt "$TARBALL"
  rm -f "$TARBALL"
  ok "Encrypted tarball: ${TARBALL}.gpg"
  FINAL_OUTPUT="${TARBALL}.gpg"
else
  FINAL_OUTPUT="$TARBALL"
fi

# ────────────────────────────
# Cleanup
# ────────────────────────────
rm -rf "$WORK_DIR"
ok "Cleanup complete"

# ────────────────────────────
# Report
# ────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "            CEV BACKUP COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  File: $FINAL_OUTPUT"
echo "  Size: $(du -h "$FINAL_OUTPUT" | cut -f1)"
echo ""
echo "  To restore, run:"
echo "    ./restore-stack.sh $FINAL_OUTPUT"
echo ""
echo "═══════════════════════════════════════════════════════"
