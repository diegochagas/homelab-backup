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

readonly VERSION="2.0.0"
readonly REMOTE="$REMOTE_USER@$REMOTE_HOST"
readonly START_TIME=$(date +%s)

########################################
# Runtime options
########################################

TARGET="all"
DRY_RUN=false
declare LOG_FILE=""

# Folders selected for this run
declare -a SELECTED=()

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
# Sends a Telegram message through
# notify.sh (no-op when telegram.env
# isn't configured).
########################################
notify() {
    local script="$SCRIPT_DIR/notify.sh"

    [[ -x "$script" ]] || return 0

    "$script" "$@" >/dev/null 2>&1 || true
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
        echo "Folder:      $TARGET"
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

    if [[ "$DRY_RUN" != true ]]; then
        notify "🚨 BACKUP FAILED — $(hostname -s)

Folder:    $TARGET
Exit code: $exit_code
Line:      $line
Command:   $command

Log: $(basename "$LOG_FILE")"
    fi

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
    --folder <name>     Backup only one folder.
    --dry-run           Simulate the backup.
    --help              Show help.
    --version           Show version.

Available folders:
    all
$(printf '    %s\n' "${FOLDERS[@]}")

Examples:
    ./backup.sh

$(printf '    ./backup.sh --folder %s\n\n' "${FOLDERS[@]}")
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

########################################
# Verifies that the selected remote
# folders exist before starting.
########################################
check_remote_folders() {
    print_info
    print_info "Checking remote folders..."

    for folder in "${SELECTED[@]}"; do
        if ! ssh \
            -p "$SSH_PORT" \
            "$REMOTE" \
            "[ -d \"$REMOTE_ROOT/$folder\" ]"
        then
            print_info "❌ Remote folder not found: $REMOTE_ROOT/$folder"
            exit 1
        fi
    done

    print_info "✅ Remote folders OK"
}

########################################
# Warns when the server-side backup
# (zimaos/backup.sh) hasn't run recently
# — e.g. after a ZimaOS update wiped
# root's crontab.
########################################
check_server_backup_freshness() {
    print_info
    print_info "Checking server-side backup age..."

    local log_mtime
    log_mtime=$(ssh \
        -p "$SSH_PORT" \
        "$REMOTE" \
        "stat -c %Y \"$SERVER_BACKUP_LOG\" 2>/dev/null" || true)

    if [[ -z "$log_mtime" ]]; then
        print_info "⚠️  Server backup log not found: $SERVER_BACKUP_LOG"
        print_info "⚠️  Has zimaos/backup.sh ever run on the server?"
        return 0
    fi

    local age_hours=$(( ($(date +%s) - log_mtime) / 3600 ))

    if (( age_hours > MAX_SERVER_BACKUP_AGE_HOURS )); then
        print_info "⚠️  WARNING: server-side backup is ${age_hours}h old ($((age_hours / 24)) days)"
        print_info "⚠️  The 4am cron job may be gone — ZimaOS updates wipe root's crontab."
        print_info "⚠️  Check on the server: sudo crontab -l"
    else
        print_field "Last run:" "${age_hours}h ago"
        print_info "✅ Server-side backup is fresh"
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
# Resolves the --folder argument into
# the list of folders to back up.
########################################
select_folders() {
    if [[ "$TARGET" == "all" ]]; then
        SELECTED=("${FOLDERS[@]}")
        return
    fi

    for folder in "${FOLDERS[@]}"; do
        if [[ "${folder,,}" == "${TARGET,,}" ]]; then
            SELECTED=("$folder")
            return
        fi
    done

    print_info "❌ Unknown folder: $TARGET"
    print_info
    print_info "Available folders:"
    print_info "  all"

    for folder in "${FOLDERS[@]}"; do
        print_info "  $folder"
    done

    exit 1
}

########################################
# Parses command-line arguments.
#
# Options:
#   --folder <name>
########################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --folder)
                TARGET="$2"
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
                print_version
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

    for folder in "${SELECTED[@]}"; do
        required=$((required + $(get_remote_size_bytes "$REMOTE_ROOT/$folder")))
    done

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
# Synchronizes a folder from the remote
# server to the local backup, showing
# overall transfer progress.
#
# Arguments:
#   $1 - Folder name
########################################
sync_folder() {
    local folder="$1"

    local remote_path="$REMOTE_ROOT/$folder"
    local destination="$LOCAL_BACKUP/$folder"

    print_info "📂 $folder"

    local size
    size=$(get_remote_size "$remote_path")

    print_field "   Size:" "$size"

    mkdir -p "$destination"

    local options=(
        -a
        --human-readable
        --delete
        --rsync-path="sudo /usr/bin/rsync"
    )

    if [[ "$DRY_RUN" == true ]]; then
        options+=(
            -n
            --stats
        )
    else
        options+=(
            --info=progress2,name0
        )

        print_info
        print_info "Synchronizing..."
    fi

    # rsync exit 24 (source files vanished mid-transfer) is expected when
    # pulling folders the server's apps are still writing to - treat it as OK.
    local rc=0
    rsync "${options[@]}" "$REMOTE:$remote_path/" "$destination/" || rc=$?

    if [[ "$rc" -eq 0 || "$rc" -eq 24 ]]; then
        print_field "  Status:" "✅ OK"
        SUMMARY+=("$folder|$size|✅ OK")
    else
        print_field "  Status:" "❌ Failed"
        SUMMARY+=("$folder|$size|❌ Failed")
        return 1
    fi

    print_info
}

########################################
# Backs up a folder from the ZimaOS
# server.
#
# Arguments:
#   $1 - Folder name
########################################
backup_folder() {
    local folder="$1"

    print_section "Backing up $folder"

    local start_time=$(date +%s)

    sync_folder "$folder" || return 1

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo
    print_field "Completed in:" "$(format_time "$elapsed")"
}

########################################
# Main
########################################

########################################
# Prints the backup summary.
########################################
print_summary() {
    local elapsed="$1"
    print_section "Summary"

    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r name size status <<< "$item"

        print_info "• $name"
        print_field "    Size:" "$size"
        print_field "    Status:" "$status"
        print_info
    done

    echo

    print_field "Mode:" \
        "$([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Backup")"

    print_field "Destination:" "$LOCAL_BACKUP"
    print_field "Elapsed:" "$(format_time "$elapsed")"
}

########################################
# Builds the Telegram summary sent when
# the backup finishes.
#
# Arguments:
#   $1 - Elapsed seconds
########################################
build_notification() {
    local elapsed="$1"

    echo "✅ BACKUP FINISHED — $(hostname -s)"
    echo
    echo "ZimaOS → $LOCAL_BACKUP"
    echo

    for item in "${SUMMARY[@]}"; do
        IFS="|" read -r name size status <<< "$item"
        echo "$status $name ($size)"
    done

    echo
    echo "Elapsed: $(format_time "$elapsed")"
}

initialize() {
    print_section "Initialization"

    check_dependencies

    test_ssh_connection

    check_server_backup_freshness

    check_remote_folders

    create_backup_directory

    check_disk_space
}

main() {
    parse_arguments "$@"

    initialize_logging

    write_log_header

    print_header

    select_folders

    initialize

    for folder in "${SELECTED[@]}"; do
        backup_folder "$folder" || exit 1
    done

    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    echo
    print_info "🎉 Backup completed!"
    echo

    print_summary "$elapsed"

    echo

    write_log_footer "$elapsed"

    if [[ "$DRY_RUN" != true ]]; then
        notify "$(build_notification "$elapsed")"
    fi
}

main "$@"
