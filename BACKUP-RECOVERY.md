# CEV Backup & Recovery Guide

**For:** Walt Rines  
**Last updated:** April 2026  
**What this is:** Step-by-step instructions to restore the entire CEV tech stack on a brand new machine with nothing on it.

---

## What You Need Before Starting

Three things. That's it.

1. **Google Drive access** — your personal Gmail account
2. **GPG password** — stored in your password manager (the backup is encrypted with it)
3. **Internet connection** — for downloading the backup and installing software

That's all. You don't need Node.js, PostgreSQL, or anything else installed. The restore script handles everything.

---

## Step 1: Get a New Machine Ready

Install one of these:

- **Windows with WSL2** (recommended): Open PowerShell as admin, run `wsl --install`, then `wsl --install -d Ubuntu`.
- **Ubuntu/Debian Linux** (desktop or server).
- **macOS** (Apple Silicon or Intel both work).

Once you're at a terminal, you're ready.

---

## Step 2: Download Your Backup

Open Chrome and go to your Google Drive.

Find the most recent backup file. It looks like this:

```
cev-stack-backup-20260425.tar.gz.gpg
```

Download it to your new machine. Put it somewhere easy to find, like:

```
/home/walt/Downloads/cev-stack-backup-20260425.tar.gz.gpg
```

> **Tip:** The date in the filename is the backup date. Use the newest one.

---

## Step 3: Run the Restore Script

Copy this entire command, paste it into your terminal, and press Enter:

```bash
curl -sL https://raw.githubusercontent.com/MagneticEnergy/All_Departments/main/cev-restore.sh | bash -s ~/Downloads/cev-stack-backup-20260425.tar.gz.gpg
```

Replace `20260425` with the actual date from your backup file.

When prompted, type your **GPG password** (the one from your password manager). You won't see characters as you type — that's normal. Press Enter.

Now wait. The script will:

1. Figure out what kind of computer you have (Linux, WSL2, or Mac)
2. Install everything you need — Node.js 22, Python, PostgreSQL, nginx, Ollama
3. Decrypt and unpack your backup
4. Restore all your files, databases, and settings
5. Start everything up
6. Print a health check report

This takes **20–30 minutes** depending on your internet speed. Go make coffee.

---

## Step 4: Check the Health Report

When the script finishes, you'll see a big status report. It looks like this:

```
═══════════════════════════════════════════════
            CEV RESTORE STATUS REPORT
═══════════════════════════════════════════════
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STATUS: ALL CHECKS PASSED  🟢
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Paperclip Dashboard : http://localhost:3100
  Hermes Gateway      : http://localhost:3000
  Ollama API          : http://localhost:11434
```

If you see the green checkmark, you're done. Everything is running.

If you see red, scroll up to read which check failed. Common fixes:

| Problem | Fix |
|---------|-----|
| PostgreSQL not running | `sudo systemctl start postgresql` (Linux/WSL2) |
| Paperclip didn't start | `cd ~/.openclaw/workspace/paperclip && pnpm run dev:once` |
| Ollama not responding | `sudo snap start ollama` (Linux/WSL2) or `brew services start ollama` (Mac) |

If you can't fix it, the log file is at `/tmp/cev-restore.log`.

---

## What Got Restored

Here's everything the script put back on your machine:

| What | Where |
|------|-------|
| OpenClaw workspace, agents, skills | `~/.openclaw/` |
| Hermes agent config and sessions | `~/.hermes/` |
| All scripts (health-check, daily-updates, etc.) | `~/scripts/` |
| systemd user services (hermes-gateway, camofox, paperclip) | `~/.config/systemd/user/` |
| nginx web server config | `/etc/nginx/` |
| PostgreSQL databases (paperclip, carrier_reputation) | Inside PostgreSQL |
| Crontab (scheduled tasks) | Your user's crontab |
| Ollama AI models | Downloaded fresh from manifest |

---

## How to Make a New Backup

After you've made changes to the system, create a fresh backup:

```bash
# Basic backup
./backup-stack.sh

# With GPG encryption (recommended)
GPG_KEY_ID=your-gpg-key-id ./backup-stack.sh
```

The script creates:
- `cev-stack-backup-YYYYMMDD_HHMMSS.tar.gz` (unencrypted)
- `cev-stack-backup-YYYYMMDD_HHMMSS.tar.gz.gpg` (if you set GPG_KEY_ID)

Upload the `.gpg` file to Google Drive. Delete older backups to save space.

---

## Files Involved

| File | Location | What it does |
|------|----------|--------------|
| `cev-restore.sh` | GitHub: `MagneticEnergy/All_Departments` | The bootstrap script you curl and run |
| `restore-stack.sh` | `~/scripts/` | Local version of the restore script (same code) |
| `backup-stack.sh` | `~/scripts/` | Creates a new backup tarball |
| `BACKUP-RECOVERY.md` | `~/.openclaw/workspace/` | This document |

---

## If Something Goes Wrong

1. **Check the log:** `cat /tmp/cev-restore.log`
2. **The script is safe to re-run.** It's idempotent — running it again won't break anything already working.
3. **Ask for help:** Post in the `#tech-support` channel or open a Paperclip issue.

---

*Document maintained by Ada Nexus, CTO.*
