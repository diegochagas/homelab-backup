# Homelab Backup

![Bash](https://img.shields.io/badge/Bash-5%2B-green)
![License](https://img.shields.io/github/license/diegochagas/homelab-backup)
![Version](https://img.shields.io/badge/version-1.0.0-blue)

A lightweight, modular and extensible Bash backup utility for self-hosted homelabs.

**Homelab Backup** securely synchronizes data from a remote **ZimaOS** server to a local backup drive using **SSH** and **rsync**. It is designed to provide reliable, incremental backups with a clean command-line interface, detailed logging, automatic disk space verification, and centralized error handling.

---

## Features

- ✅ Incremental backups using `rsync`
- ✅ SSH-based remote synchronization
- ✅ Backup multiple services independently
- ✅ Backup all services with a single command
- ✅ Dry Run mode for safe testing
- ✅ Automatic disk space verification
- ✅ Detailed execution logs
- ✅ Backup summary
- ✅ Centralized error handling using `trap`
- ✅ Configuration separated from source code
- ✅ Modular architecture for easy expansion

---

## Supported Services

| Service                   |   Status   |
| ------------------------- | :--------: |
| Jellyfin                  |     ✅     |
| Immich                    |     ✅     |
| Vaultwarden               |     ✅     |
| Nextcloud (Configuration) | 🚧 Planned |

> **Note**
>
> Nextcloud files are **not** backed up by this project because they are already synchronized to the local machine using the Nextcloud Desktop Client.
>
> This avoids storing duplicate copies of large datasets while still allowing future backup of server-specific configuration and databases.

---

# Project Structure

```
homelab-backup/
│
├── backup.sh
├── config.sh.example
├── LICENSE
├── README.md
├── .gitignore
│
└── logs/
```

---

# Backup Structure

The backup is organized into two main categories:

```
/mnt/data/backup
│
├── media
│   ├── jellyfin
│   └── immich
│
└── appdata
    ├── jellyfin
    ├── immich
    └── vaultwarden
```

This mirrors the remote server while separating user data from application data.

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

---

# Installation

Clone the repository:

```bash
git clone https://github.com/diegochagas/homelab-backup.git

cd homelab-backup
```

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

REMOTE_MEDIA
REMOTE_APPDATA

LOCAL_BACKUP
```

---

# Usage

## Backup everything

```bash
./backup.sh
```

---

## Backup a single service

### Jellyfin

```bash
./backup.sh --service jellyfin
```

### Immich

```bash
./backup.sh --service immich
```

### Vaultwarden

```bash
./backup.sh --service vaultwarden
```

---

## Simulate a backup

Dry Run allows you to verify everything that will happen without copying or deleting any files.

```bash
./backup.sh --dry-run
```

Dry Run can also be combined with a service:

```bash
./backup.sh --service jellyfin --dry-run
```

---

## Help

```bash
./backup.sh --help
```

---

## Version

```bash
./backup.sh --version
```

---

# Example Output

```text
==========================================
        Homelab Backup v1.0.0
==========================================
Mode: Backup

========================================
Initialization
========================================

Checking dependencies...
✅ Dependencies OK

Testing SSH connection...
✅ Connected to ZimaOS

Creating backup directory...
✅ Backup directory ready

Checking available disk space...

Required:          285G
Available:         719G

Status:            ✅ Enough disk space

========================================
Backing up Jellyfin
========================================

📂 Media
Size:              249G
Status:            ✅ OK

📂 Configuration
Size:              43M
Status:            ✅ OK

Completed in:      00:00:18

🎉 Backup completed!

========================================
Summary
========================================

Jellyfin
• Media
Size:              249G
Status:            ✅ OK

• Configuration
Size:              43M
Status:            ✅ OK

Mode:              Backup
Destination:       /mnt/data/backup
Elapsed:           00:00:18
```

---

# Logging

Every execution generates a timestamped log file.

```
logs/
└── 2026-06-29_20-13-09.log
```

The log contains:

- Execution information
- Service results
- Backup summary
- Errors
- Execution time

---

# Safety Features

Homelab Backup includes several protections to prevent common backup issues.

## Dry Run

Preview all operations before executing them.

## Disk Space Verification

Checks whether the destination has enough available space before starting.

## SSH Validation

Verifies the remote server is reachable before beginning the backup.

## Incremental Synchronization

Uses `rsync` to transfer only changed files.

## Automatic Cleanup

Files removed from the remote server are also removed locally using:

```text
--delete
```

keeping the backup synchronized.

## Error Handling

Unexpected failures are automatically reported using Bash's `trap` mechanism.

The script displays:

- Exit code
- Failed command
- Line number
- Log file location

---

# Architecture

The project follows a modular architecture.

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
Service Backups
        │
        ▼
Summary
```

Each function has a single responsibility, making the project easy to maintain and extend.

---

# Roadmap

## Current

- [x] Jellyfin backup
- [x] Immich backup
- [x] Vaultwarden backup
- [x] Dry Run
- [x] Logging
- [x] Backup summary
- [x] Disk space verification
- [x] Error handling
- [x] SSH validation

## Planned

- [ ] Nextcloud configuration backup
- [ ] Compression support
- [ ] Email notifications
- [ ] Restore utility
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
