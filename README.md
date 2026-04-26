# All_Departments

CEV shared resources — restore scripts, recovery docs, and cross-department assets.

## Files

| File | Purpose |
|------|---------|
| `cev-restore.sh` | Standalone system restore script for new machine recovery |
| `backup-stack.sh` | Companion script to create full system backups |
| `BACKUP-RECOVERY.md` | Plain-English recovery guide for non-technical users |

## Quick Start (Recovery)

```bash
curl -sL https://raw.githubusercontent.com/crimson-edge/All_Departments/main/cev-restore.sh | bash -s cev-stack-backup-20260425.tar.gz.gpg
```

See [BACKUP-RECOVERY.md](BACKUP-RECOVERY.md) for full step-by-step instructions.
