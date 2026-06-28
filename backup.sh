#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Homelab Backup
#
# Main entry point.
########################################

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/config.sh"

########################################
# Functions
########################################

print_header() {
    echo
    echo "=========================================="
    echo "        Homelab Backup v0.1"
    echo "=========================================="
    echo
}

check_dependencies() {
    echo "Checking dependencies..."

    local dependencies=(
        ssh
        rsync
        du
    )

    for command in "${dependencies[@]}"; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "❌ Missing dependency: $command"
            exit 1
        fi
    done

    echo "✅ Dependencies OK"
}

test_ssh_connection() {
    echo "Testing SSH connection..."

    if ssh \
        -p "$SSH_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$REMOTE_USER@$REMOTE_HOST" \
        "echo Connected" >/dev/null 2>&1
    then
        echo "✅ Connected to ZimaOS"
    else
        echo "❌ Could not connect to ZimaOS"
        exit 1
    fi
}

create_backup_directory() {
    echo "Checking backup directory..."

    mkdir -p "$LOCAL_BACKUP"

    echo "✅ $LOCAL_BACKUP"
}

########################################
# Prints a section header.
#
# Arguments:
#   $1 - Section title
########################################
print_section() {
  echo
  echo "========================================"
  echo "$1"
  echo "========================================"
}

########################################
# Synchronizes a directory from the
# remote server to the local backup.
#
# Arguments:
#   $1 - Remote source
#   $2 - Local destination
########################################
backup_directory() {
    local source="$1"
    local destination="$2"

    local options=(-avh --delete)

    if [[ "$DRY_RUN" == true ]]; then
        options+=(-n)
    fi

    rsync "${options[@]}" "$source" "$destination"
}

########################################
# Backs up the Jellyfin media library and
# configuration from the ZimaOS server.
########################################
backup_jellyfin() {
    mkdir -p "$LOCAL_BACKUP/jellyfin"
    mkdir -p "$LOCAL_BACKUP/appdata/jellyfin"

    print_section "Backing up Jellyfin"

    local remote="$REMOTE_USER@$REMOTE_HOST"

    echo "• Media..."

    if backup_directory \
        "$remote:$JELLYFIN_MEDIA/" \
        "$LOCAL_BACKUP/jellyfin/"
    then
        echo "✅ Jellyfin media OK"
    else
        echo "❌ Jellyfin media failed"
        exit 1
    fi

    echo "• Configuration..."

    if backup_directory \
        "$remote:$JELLYFIN_CONFIG/" \
        "$LOCAL_BACKUP/appdata/jellyfin/"
    then
        echo "✅ Jellyfin configuration OK"
    else
        echo "❌ Jellyfin configuration failed"
        exit 1
    fi
}

########################################
# Main
########################################

main() {
  print_header

  check_dependencies

  test_ssh_connection

  create_backup_directory

  backup_jellyfin

  # backup_immich
  # backup_nextcloud

  echo
  echo "🎉 Backup completed!"
  echo
}

main
