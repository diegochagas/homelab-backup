#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Homelab Backup
#
# Main entry point.
########################################


# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/config.sh"

readonly VERSION="0.1.0"
readonly REMOTE="$REMOTE_USER@$REMOTE_HOST"
readonly START_TIME=$(date +%s)

########################################
# Runtime options
########################################

SERVICE="all"
DRY_RUN=false

########################################
# Functions
########################################

format_time() {
    local seconds="$1"

    printf "%02d:%02d:%02d\n" \
        $((seconds/3600)) \
        $(((seconds%3600)/60)) \
        $((seconds%60))
}

print_header() {
    echo
    echo "=========================================="
    echo "        Homelab Backup v$VERSION"
    echo "=========================================="
    echo "Mode: $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Backup")"
    echo
}

########################################
# Prints the help message.
########################################
print_help() {
    cat << EOF
Homelab Backup v$VERSION

Usage:
    ./backup.sh [options]

Options:
    --service <name>    Backup only one service.
    --dry-run           Simulate the backup.
    --help              Show help.
    --version           Show version.

Available services:
    all
    jellyfin
    immich
    vaultwarden

Examples:
    ./backup.sh

    ./backup.sh --service jellyfin

    ./backup.sh --service immich
EOF
}

########################################
# Prints the current version.
########################################
print_version() {
    echo "$VERSION"
}

check_dependencies() {
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
        "$REMOTE" \
        "echo Connected" >/dev/null 2>&1
    then
        echo "✅ Connected to ZimaOS"
    else
        echo "❌ Could not connect to ZimaOS"
        exit 1
    fi
}

create_backup_directory() {
    echo "Creating backup directory..."

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
# Parses command-line arguments.
#
# Options:
#   --service <name>
########################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                SERVICE="$2"
                shift 2
                ;;

            --dry-run)
                DRY_RUN=true
                shift
                ;;

            --help)
                print_help
                exit 0
                ;;

            --version)
                echo "$VERSION"
                exit 0
                ;;

            *)
                echo "❌ Unknown argument: $1"
                echo
                echo "Run './backup.sh --help' for usage information."
                exit 1
                ;;
        esac
    done
}

########################################
# Synchronizes a directory from the
# remote server to the local backup.
#
# Arguments:
#   $1 - Display name
#   $2 - Remote source
#   $3 - Local destination
########################################
sync_directory() {
    local name="$1"
    local source="$2"
    local destination="$3"

    echo "• $name..."

    local options=(-a --human-readable --delete --stats)

    if [[ "$DRY_RUN" == true ]]; then
        options+=(-n)
    fi

    if rsync "${options[@]}" "$source" "$destination"; then
        echo "  ✅ OK"
    else
        echo "  ❌ Failed"
        return 1
    fi
}

########################################
# Backs up the Jellyfin media library and
# configuration from the ZimaOS server.
########################################
backup_jellyfin() {
    print_section "Backing up Jellyfin"

    mkdir -p "$LOCAL_MEDIA/jellyfin"
    mkdir -p "$LOCAL_APPDATA/jellyfin"

    sync_directory \
        "Media" \
        "$REMOTE:$JELLYFIN_MEDIA/" \
        "$LOCAL_MEDIA/jellyfin/" || return 1

    sync_directory \
        "Configuration" \
        "$REMOTE:$JELLYFIN_CONFIG/" \
        "$LOCAL_APPDATA/jellyfin/" || return 1
}

########################################
# Backs up the Immich data and configuration
# from the ZimaOS server.
########################################
backup_immich() {
    print_section "Backing up Immich"

    mkdir -p "$LOCAL_MEDIA/immich"
    mkdir -p "$LOCAL_APPDATA/immich"

    sync_directory \
        "Photos" \
        "$REMOTE:$IMMICH_MEDIA/" \
        "$LOCAL_MEDIA/immich/" || return 1

    sync_directory \
        "Database" \
        "$REMOTE:$IMMICH_DATABASE/" \
        "$LOCAL_APPDATA/immich/" || return 1
}

########################################
# Backs up the Vaultwarden data.
########################################
backup_vaultwarden() {
    print_section "Backing up Vaultwarden"

    mkdir -p "$LOCAL_APPDATA/vaultwarden"

    sync_directory \
        "Data" \
        "$REMOTE:$VAULTWARDEN_DATA/" \
        "$LOCAL_APPDATA/vaultwarden/" || return 1
}

########################################
# TODO
#
# Nextcloud files are already synchronized
# to this machine through the Nextcloud
# Desktop client.
#
# At the moment, backing them up again
# would only duplicate ~190 GB of data.
#
# If the server ever stores unique data
# (database, configuration, apps,
# certificates, etc.), implement:
#
# backup_nextcloud()
########################################

########################################
# Main
########################################

initialize() {
    print_section "Initialization"

    check_dependencies

    test_ssh_connection

    create_backup_directory
}

main() {
    parse_arguments "$@"

    print_header

    initialize

    case "$SERVICE" in
        all)
            backup_jellyfin || exit 1
            backup_immich || exit 1
            backup_vaultwarden || exit 1
            ;;

        jellyfin)
            backup_jellyfin || exit 1
            ;;

        immich)
            backup_immich || exit 1
            ;;

        vaultwarden)
            backup_vaultwarden || exit 1
            ;;
        *)
            echo "❌ Unknown service: $SERVICE"
            echo
            echo "Available services:"
            echo "  all"
            echo "  jellyfin"
            echo "  immich"
            echo "  vaultwarden"
            exit 1
            ;;
    esac

    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    echo
    echo "🎉 Backup completed!"
    echo "Elapsed time: $(format_time "$elapsed")"
    echo
}

main "$@"