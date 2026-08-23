# Homelab Backup

![Bash](https://img.shields.io/badge/Bash-5%2B-green)
![License](https://img.shields.io/github/license/diegochagas/homelab-backup)
![Version](https://img.shields.io/badge/version-2.0.0-blue)

A lightweight, modular and extensible Bash backup utility for self-hosted homelabs.

**Homelab Backup** covers the full backup chain for a **ZimaOS** server: backing
up its live app data locally, pulling an offsite copy down to a Linux Mint
workstation, restoring that copy back after a failure, and mirroring it onto
cold/offline external drives.

---

## The Backup Chain

```
┌─────────────────────────┐        ┌──────────────────────────┐
│  ZimaOS server           │        │  Linux Mint workstation   │
│                           │        │                            │
│  /DATA/AppData  ───────┐ │        │                            │
│         (live app data)│ │        │                            │
│                         ▼ │        │                            │
│  zimaos/backup.sh          │        │                            │
│         │                 │        │                            │
│         ▼                 │        │                            │
│  DATA4TB/Backups/AppData   │        │                            │
│  DATA4TB/Backups           │  SSH   │                            │
│  DATA4TB/Gallery      ─────┼───────▶│  backup.sh                 │
│         │                 │  pull  │       │                     │
│         ▼                 │        │       ▼                     │
│  BACKUP4TB (full mirror)   │        │  /mnt/data/backup           │
│                           │        │       │                     │
│         ▲                 │  SSH   │       │                     │
│         └─────────────────┼────────┤  restore.sh (DR only)       │
│                           │  push  │       │                     │
│                           │        │       ▼                     │
│                           │        │  mirror-to-external.sh       │
│                           │        │       │                     │
│                           │        │       ▼                     │
│                           │        │  external USB drive          │
└─────────────────────────┘        └──────────────────────────┘
```

| Stage | Script | Runs on | Direction | Purpose |
| ----- | ------ | ------- | --------- | ------- |
| 1 | `zimaos/backup.sh` | ZimaOS (cron) | `/DATA/AppData` + `/DATA/Projects` → `DATA4TB`, `DATA4TB` → `BACKUP4TB` | Consistent local copy + local mirror |
| 2 | `backup.sh` | Linux Mint (systemd timer) | `DATA4TB` → `/mnt/data/backup` | Offsite copy |
| 3 | `restore.sh` | Linux Mint (manual) | `/mnt/data/backup` → ZimaOS | Disaster recovery |
| — | `mirror-to-external.sh` | Linux Mint (manual) | local or ZimaOS → external USB drive | Ad-hoc cold/offline copies |
| — | `notify.sh` | Both | Telegram | Called by the backup scripts to report a finished/failed run |

---

## Features

- ✅ Incremental backups using `rsync`
- ✅ SSH-based remote synchronization
- ✅ Live transfer progress
- ✅ Folder-based backups — everything inside each folder is included
- ✅ Backup a single folder or all folders with one command
- ✅ Push-based restore for disaster recovery, with container-safe AppData handling
- ✅ Profile-based mirroring to external drives, with drive auto-detection and destructive-action confirmation
- ✅ Dry Run mode for safe testing on every script
- ✅ Automatic disk space verification
- ✅ Remote folder validation
- ✅ Detailed execution logs
- ✅ Backup summary
- ✅ Centralized error handling using `trap`
- ✅ Configuration separated from source code
- ✅ Modular architecture for easy expansion
- ✅ Telegram notification when each backup stage finishes or fails

---

## Backed-up Folders

The backup is **folder-based**: each entry in `FOLDERS` (in `config.sh`) is a top-level folder of the ZimaOS external drive, synchronized in full — no matter what is inside it.

| Folder     | Status |
| ---------- | :----: |
| `Backups`  |   ✅   |
| `Gallery`  |   ✅   |

Adding a new folder to the backup is a one-line change in `config.sh`.

---

# Project Structure

```
homelab-backup/
│
├── backup.sh                  # Stage 2: pull ZimaOS -> Linux Mint
├── restore.sh                 # Stage 3: push Linux Mint -> ZimaOS (DR)
├── mirror-to-external.sh      # Ad-hoc: mirror a profile onto an external drive
├── config.sh.example
├── profiles.conf.example
│
├── zimaos/
│   ├── backup.sh               # Stage 1: runs on the ZimaOS server itself
│   └── config.sh.example
│
├── notify.sh                   # Telegram message helper used by the scripts
├── telegram.env.example
│
├── LICENSE
├── README.md
├── .gitignore
│
└── logs/
```

---

# Backup Structure

The local backup mirrors the top-level folders of the remote drive:

```
/mnt/data/backup
│
├── Backups
│   └── AppData        # mirrors /DATA/AppData on ZimaOS
│
└── Gallery
```

---

# Requirements

- Linux
- Bash 5+
- SSH access to the remote server
- rsync
- Enough free disk space for the backup

Required commands:

- ssh
- rsync
- du
- df
- lsblk *(mirror-to-external.sh only)*

---

# Installation

Clone the repository:

```bash
git clone https://github.com/diegochagas/homelab-backup.git

cd homelab-backup
```

## Linux Mint side (backup.sh, restore.sh, mirror-to-external.sh)

Create your configuration file:

```bash
cp config.sh.example config.sh
```

Edit the configuration:

```bash
nano config.sh
```

Adjust the following values:

```bash
REMOTE_HOST
REMOTE_USER

REMOTE_ROOT
REMOTE_APPDATA
APPS

LOCAL_BACKUP

FOLDERS
```

If you plan to use `mirror-to-external.sh`, also create its profiles file:

```bash
cp profiles.conf.example profiles.conf
nano profiles.conf
```

## ZimaOS side (zimaos/backup.sh)

Copy `zimaos/` onto the ZimaOS server (e.g. `scp -r zimaos/ diegochagas@192.168.15.8:~/backup/`), then on the server:

```bash
cd backup
cp config.sh.example config.sh
nano config.sh
```

Schedule it with cron (or ZimaOS's own Task Scheduler) to run daily before `backup.sh`'s pull.

## Telegram notifications (optional)

`backup.sh` and `zimaos/backup.sh` send a Telegram message when a run
finishes (✅ with the per-folder summary and elapsed time) or fails (🚨 with
the exit code, line and command). Dry runs never notify.

On each machine that runs a backup script:

```bash
cp telegram.env.example telegram.env
chmod 600 telegram.env
nano telegram.env     # TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID
```

Test it with `./notify.sh "hello"`. Without `telegram.env` the scripts
behave exactly as before.

For on-demand status, automatic alerts and stale-backup detection, see the
companion [homelab-monitor](https://github.com/diegochagas/homelab-monitor),
which reads this project's logs.

---

# Usage

## Stage 1 — ZimaOS local backup (on the server)

```bash
./zimaos/backup.sh
```

Stops the configured app containers, mirrors `/DATA/AppData` onto the external
drive, restarts the containers, mirrors `/DATA/Projects` (gitignored files like
`.env.docker` only exist there) onto the external drive, then mirrors the whole
external drive onto a second drive. Intended to run via cron on the ZimaOS box
itself.

## Stage 2 — Pull to Linux Mint

### Backup everything

```bash
./backup.sh
```

### Backup a single folder

```bash
./backup.sh --folder Backups
./backup.sh --folder Gallery
```

### Simulate a backup

Dry Run allows you to verify everything that will happen without copying or deleting any files.

```bash
./backup.sh --dry-run
```

Dry Run can also be combined with a folder:

```bash
./backup.sh --folder Gallery --dry-run
```

## Stage 3 — Restore to ZimaOS (disaster recovery)

Pushes `/mnt/data/backup` back to the ZimaOS server, restoring each folder to
its respective remote location. Use this after a drive failure or a fresh
ZimaOS install.

```bash
# Always dry-run first
./restore.sh --dry-run

# Restore everything
./restore.sh

# Restore only the live app data (containers are stopped/restarted around it)
./restore.sh --target appdata

# Restore only one folder
./restore.sh --target Gallery

# Exact mirror restore (also removes remote files with no local counterpart)
./restore.sh --delete
```

By default `restore.sh` only adds/updates files; pass `--delete` for an exact
mirror. It always asks for a typed confirmation before touching remote data
unless `--dry-run` or `--yes` is given.

## Ad-hoc — Mirror to an external drive

Connect an external USB drive to Linux Mint, then:

```bash
# See what's configured
./mirror-to-external.sh --list

# Preview
./mirror-to-external.sh nextcloud --dry-run

# Wipe the connected drive and copy the Nextcloud data onto it
./mirror-to-external.sh nextcloud

# Wipe the connected drive and copy ZimaOS's Media folder onto it
./mirror-to-external.sh media
```

The script auto-detects mounted removable drives (asking you to pick if more
than one is connected) and always requires you to type the drive's label back
before erasing anything — there is no way to skip this prompt.

## Help

```bash
./backup.sh --help
./restore.sh --help
./mirror-to-external.sh --help
```

## Version

```bash
./backup.sh --version
```

---

# Example Output

```text
==========================================
        Homelab Backup v2.0.0
==========================================
Mode: Backup

========================================
Initialization
========================================

Checking dependencies...
✅ Dependencies OK

Testing SSH connection...
✅ Connected to ZimaOS

Checking remote folders...
✅ Remote folders OK

Creating backup directory...
✅ Backup directory ready

Checking available disk space...

Required:          1.2T
Available:         2.4T

Status:            ✅ Enough disk space

========================================
Backing up Backups
========================================

📂 Backups
Size:              830G

Synchronizing...
  623.10G  74%  112.03MB/s    0:23:41

Status:            ✅ OK

Completed in:      01:31:12

🎉 Backup completed!

========================================
Summary
========================================

• Backups
Size:              830G
Status:            ✅ OK

• Gallery
Size:              412G
Status:            ✅ OK

Mode:              Backup
Destination:       /mnt/data/backup
Elapsed:           02:14:37
```

---

# Logging

Every execution generates a timestamped log file.

```
logs/
├── 2026-08-08_10-00-00.log            # backup.sh
├── restore_2026-08-08_10-00-00.log     # restore.sh
└── mirror_2026-08-08_10-00-00.log      # mirror-to-external.sh
```

The log contains:

- Execution information
- Folder/target results
- Backup summary
- Errors
- Execution time

---

# Safety Features

Homelab Backup includes several protections to prevent common backup issues.

## Dry Run

Preview all operations before executing them, on every script.

## Disk Space Verification

Checks whether the destination has enough available space (or, for
`mirror-to-external.sh`, capacity) before starting.

## SSH Validation

Verifies the remote server is reachable before beginning the backup or restore.

## Server-side Backup Freshness

`backup.sh` checks the modification time of the server-side backup log and
warns when `zimaos/backup.sh` hasn't run within `MAX_SERVER_BACKUP_AGE_HOURS`
(default 48h) — catching a dead cron job (ZimaOS updates wipe root's crontab)
within a day instead of silently losing backups.

## Remote Folder Validation

Verifies every selected folder exists on the server before any file is transferred, preventing `--delete` from wiping a local copy because of a wrong path.

## Empty-Source Guard

`restore.sh` and `mirror-to-external.sh` refuse to run if their source is
missing or empty, so a mistaken path can never mass-delete the destination.

## Typed Confirmation

`restore.sh` and `mirror-to-external.sh` require typing a confirmation phrase
(the drive label, for `mirror-to-external.sh`) before touching remote data or
erasing a drive. `--dry-run` never needs confirmation.

## Incremental Synchronization

Uses `rsync` to transfer only changed files.

## Automatic Cleanup

Files removed from the source are also removed at the destination when
`--delete` is used, keeping the two sides synchronized.

## Error Handling

Unexpected failures are automatically reported using Bash's `trap` mechanism.

The script displays:

- Exit code
- Failed command
- Line number
- Log file location

---

# Architecture

Each script follows the same modular architecture.

```
Configuration
        │
        ▼
Logging
        │
        ▼
Formatting
        │
        ▼
Validation
        │
        ▼
Synchronization Engine
        │
        ▼
Folder/Target/Profile Backups
        │
        ▼
Summary
```

Each function has a single responsibility, making the project easy to maintain and extend.

---

# Roadmap

## Current

- [x] Folder-based backups
- [x] Live transfer progress
- [x] Dry Run
- [x] Logging
- [x] Backup summary
- [x] Disk space verification
- [x] Remote folder validation
- [x] Error handling
- [x] SSH validation
- [x] ZimaOS-side backup script (`zimaos/backup.sh`)
- [x] Restore utility (`restore.sh`)
- [x] Ad-hoc external drive mirroring (`mirror-to-external.sh`)

## Planned

- [ ] Compression support
- [ ] Email notifications
- [ ] Backup verification
- [ ] Configuration validation
- [ ] Optional parallel backups

---

# Contributing

Contributions, bug reports, and suggestions are welcome.

If you'd like to contribute:

1. Fork the repository.
2. Create a feature branch.
3. Commit your changes.
4. Open a Pull Request.

---

# License

This project is licensed under the MIT License.

See the [LICENSE](LICENSE) file for details.

---

# Author

**Diego Chagas**

Senior Developer passionate about self-hosting, automation, open source, and building reliable tools for personal infrastructure.

GitHub:
https://github.com/diegochagas
