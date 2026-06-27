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
        echo
        echo "Try connecting manually:"
        echo
        echo "ssh $REMOTE_USER@$REMOTE_HOST"
        exit 1
    fi
}

create_backup_directory() {
    echo "Checking backup directory..."

    mkdir -p "$LOCAL_BACKUP"

    echo "✅ $LOCAL_BACKUP"
}

########################################
# Main
########################################

print_header

check_dependencies

test_ssh_connection

create_backup_directory

echo
echo "🎉 Ready to start backups!"
echo