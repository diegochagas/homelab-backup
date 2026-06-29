#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

########################################
# Homelab Backup
#
# Main entry point.
########################################


# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/config.sh"

readonly VERSION="1.0.0"
readonly REMOTE="$REMOTE_USER@$REMOTE_HOST"
readonly START_TIME=$(date +%s)

########################################
# Runtime options
########################################

SERVICE="all"
DRY_RUN=false
declare LOG_FILE=""

declare -a SUMMARY=()

########################################
# Functions
########################################

print_info() {
    echo "$@"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$@" >> "$LOG_FILE"
    fi
}

########################################
# Initializes the log file.
########################################
initialize_logging() {
    mkdir -p "$LOG_DIR"

    LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S).log"

    : > "$LOG_FILE"
}

########################################
# Writes the log header.
########################################
write_log_header() {
    {
        echo "========================================"
        echo "Homelab Backup v$VERSION"
        echo "========================================"
        echo

        echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host:        $(hostname)"
        echo "Mode:        $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Backup")"
        echo "Service:     $SERVICE"
        echo "Destination: $LOCAL_BACKUP"

        echo
        echo "========================================"
        echo
    } >> "$LOG_FILE"
}

write_log_footer() {
    local elapsed="$1"

    {
        echo
        echo "========================================"
        echo "Finished"
        echo "========================================"
        echo

        echo "Status:      SUCCESS"
        echo "Elapsed:     $(format_time "$elapsed")"
        echo
    } >> "$LOG_FILE"
}

########################################
# Handles unexpected errors.
#
# Arguments:
#   $1 - Exit code
#   $2 - Line number
#   $3 - Command
########################################
handle_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    print_info
    print_info "❌ Backup failed!"
    print_info

    print_field "Exit code:" "$exit_code"
    print_field "Line:" "$line"
    print_field "Command:" "$command"

    print_info
    print_info "See log:"
    print_info "  $LOG_FILE"

    exit "$exit_code"
}

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
# Prints a formatted field.
#
# Arguments:
#   $1 - Label
#   $2 - Value
########################################
print_field() {
    printf "%-18s %s\n" "$1" "$2"

    if [[ -n "$LOG_FILE" ]]; then
        printf "%-18s %s\n" "$1" "$2" >> "$LOG_FILE"
    fi
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
    print_info "Checking dependencies..."

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

    print_info "✅ Dependencies OK"
}

test_ssh_connection() {
    print_info
    print_info "Testing SSH connection..."

    if ssh \
        -p "$SSH_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$REMOTE" \
        "echo Connected" >/dev/null 2>&1
    then
        print_info "✅ Connected to ZimaOS"
    else
        print_info "❌ Could not connect to ZimaOS"
        exit 1
    fi
}

create_backup_directory() {
    print_info
    print_info "Creating backup directory..."

    mkdir -p "$LOCAL_BACKUP"

    print_info "✅ Backup directory ready"
}

########################################
# Prints a section header.
#
# Arguments:
#   $1 - Section title
########################################
print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
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
                print_info "❌ Unknown argument: $1"
                echo
                echo "Run './backup.sh --help' for usage information."
                exit 1
                ;;
        esac
    done
}

########################################
# Returns the size of a remote directory.
#
# Arguments:
#   $1 - Remote directory
########################################
get_remote_size() {
    ssh \
        -p "$SSH_PORT" \
        "$REMOTE" \
        "du -sh \"$1\" 2>/dev/null | cut -f1"
}

########################################
# Returns the size of a remote directory
# in bytes.
#
# Arguments:
#   $1 - Remote directory
########################################
get_remote_size_bytes() {
    ssh \
        -p "$SSH_PORT" \
        "$REMOTE" \
        "du -sb \"$1\" 2>/dev/null | cut -f1"
}

########################################
# Returns the available space on the
# destination filesystem.
########################################
get_available_space() {
    df -B1 --output=avail "$LOCAL_BACKUP" | tail -n 1
}

########################################
# Checks whether there is enough free
# space to perform the backup.
########################################
check_disk_space() {
    print_info
    print_info "Checking available disk space..."

    local required=0

    case "$SERVICE" in
        all)
            required=$((required + $(get_remote_size_bytes "$JELLYFIN_MEDIA")))
            required=$((required + $(get_remote_size_bytes "$JELLYFIN_CONFIG")))
            required=$((required + $(get_remote_size_bytes "$IMMICH_MEDIA")))
            required=$((required + $(get_remote_size_bytes "$IMMICH_DATABASE")))
            required=$((required + $(get_remote_size_bytes "$VAULTWARDEN_DATA")))
            ;;

        jellyfin)
            required=$((required + $(get_remote_size_bytes "$JELLYFIN_MEDIA")))
            required=$((required + $(get_remote_size_bytes "$JELLYFIN_CONFIG")))
            ;;

        immich)
            required=$((required + $(get_remote_size_bytes "$IMMICH_MEDIA")))
            required=$((required + $(get_remote_size_bytes "$IMMICH_DATABASE")))
            ;;

        vaultwarden)
            required=$((required + $(get_remote_size_bytes "$VAULTWARDEN_DATA")))
            ;;
    esac

    local available
    available=$(get_available_space)

    print_field "Required:" "$(numfmt --to=iec "$required")"
    print_field "Available:" "$(numfmt --to=iec "$available")"

    if (( available < required )); then
        print_field "Status:" "❌ Not enough disk space"
        exit 1
    fi

    print_field "Status:" "✅ Enough disk space"
    echo
}

########################################
# Synchronizes a directory from the
# remote server to the local backup.
#
# Arguments:
#   $1 - Service name
#   $2 - Display name
#   $3 - Remote path
#   $4 - Remote source
#   $5 - Local destination
########################################
sync_directory() {
    local service="$1"
    local name="$2"
    local remote_path="$3"
    local source="$4"
    local destination="$5"

    print_info "📂 $name"

    local size
    size=$(get_remote_size "$remote_path")

    print_field "   Size:" "$size"

    local options=(
        -a
        --human-readable
        --delete
        --info=progress2
        --stats
    )

    if [[ "$DRY_RUN" == true ]]; then
        options+=(-n)
    fi

    if rsync "${options[@]}" "$source" "$destination" >>"$LOG_FILE" 2>&1; then
        print_field "  Status:" "✅ OK"
        SUMMARY+=("$service|$name|$size|✅ OK")
    else
        print_field "  Status:" "❌ Failed"
        SUMMARY+=("$service|$name|$size|❌ Failed")
        return 1
    fi
    
    print_info
}

########################################
# Backs up the Jellyfin media library and
# configuration from the ZimaOS server.
########################################
backup_jellyfin() {
    print_section "Backing up Jellyfin"

    local start_time=$(date +%s)

    mkdir -p "$LOCAL_MEDIA/jellyfin"
    mkdir -p "$LOCAL_APPDATA/jellyfin"

    sync_directory \
        "Jellyfin" \
        "Media" \
        "$JELLYFIN_MEDIA" \
        "$REMOTE:$JELLYFIN_MEDIA/" \
        "$LOCAL_MEDIA/jellyfin/" || return 1

    sync_directory \
        "Jellyfin" \
        "Configuration" \
        "$JELLYFIN_CONFIG" \
        "$REMOTE:$JELLYFIN_CONFIG/" \
        "$LOCAL_APPDATA/jellyfin/" || return 1

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo
    print_field "Completed in:" "$(format_time "$elapsed")"
}

########################################
# Backs up the Immich data and configuration
# from the ZimaOS server.
########################################
backup_immich() {
    print_section "Backing up Immich"

    local start_time=$(date +%s)

    mkdir -p "$LOCAL_MEDIA/immich"
    mkdir -p "$LOCAL_APPDATA/immich"

    sync_directory \
        "Immich" \
        "Photos" \
        "$IMMICH_MEDIA" \
        "$REMOTE:$IMMICH_MEDIA/" \
        "$LOCAL_MEDIA/immich/" || return 1

    sync_directory \
        "Immich" \
        "Database" \
        "$IMMICH_DATABASE" \
        "$REMOTE:$IMMICH_DATABASE/" \
        "$LOCAL_APPDATA/immich/" || return 1

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo
    print_field "Completed in:" "$(format_time "$elapsed")"
}

########################################
# Backs up the Vaultwarden data.
########################################
backup_vaultwarden() {
    print_section "Backing up Vaultwarden"

    local start_time=$(date +%s)

    mkdir -p "$LOCAL_APPDATA/vaultwarden"

    sync_directory \
        "Vaultwarden" \
        "Data" \
        "$VAULTWARDEN_DATA" \
        "$REMOTE:$VAULTWARDEN_DATA/" \
        "$LOCAL_APPDATA/vaultwarden/" || return 1

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo
    print_field "Completed in:" "$(format_time "$elapsed")"
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

########################################
# Prints the summary entries for a
# specific service.
#
# Arguments:
#   $1 - Service name
########################################
print_service_summary() {
    local service="$1"

    local found=false

    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r item_service name size status <<< "$item"

        if [[ "$item_service" == "$service" ]]; then
            if [[ "$found" == false ]]; then
                echo "$service"
                found=true
            fi

            echo "  • $name"
            print_field "    Size:" "$size"
            print_field "    Status:" "$status"
            echo
        fi
    done
}

########################################
# Prints the backup summary.
########################################
print_summary() {
    local elapsed="$1"
    print_section "Summary"

    print_service_summary "Jellyfin"
    print_service_summary "Immich"
    print_service_summary "Vaultwarden"

    echo

    print_field "Mode:" \
        "$([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Backup")"

    print_field "Destination:" "$LOCAL_BACKUP"
    print_field "Elapsed:" "$(format_time "$elapsed")"
}

initialize() {
    print_section "Initialization"

    check_dependencies

    test_ssh_connection

    create_backup_directory

    check_disk_space
}
main() {
    parse_arguments "$@"

    initialize_logging

    write_log_header

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
            print_info "❌ Unknown service: $SERVICE"
            print_info
            print_info "Available services:"
            print_info "  all"
            print_info "  jellyfin"
            print_info "  immich"
            print_info "  vaultwarden"
            exit 1
            ;;
    esac

    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    echo
    print_info "🎉 Backup completed!"
    echo

    print_summary "$elapsed"

    echo

    write_log_footer "$elapsed"
}

main "$@"