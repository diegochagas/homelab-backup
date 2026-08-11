#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

########################################
# Homelab Restore
#
# Disaster-recovery counterpart to backup.sh: pushes the local
# backup (pulled by backup.sh) back to the ZimaOS server, each
# folder to its respective remote location.
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

TARGET="all"
DRY_RUN=false
DELETE=false
ASSUME_YES=false
declare LOG_FILE=""

# Targets selected for this run: folder names from FOLDERS,
# plus the synthetic "appdata" target.
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

initialize_logging() {
    mkdir -p "$LOG_DIR"

    LOG_FILE="$LOG_DIR/restore_$(date +%Y-%m-%d_%H-%M-%S).log"

    : > "$LOG_FILE"
}

write_log_header() {
    {
        echo "========================================"
        echo "Homelab Restore v$VERSION"
        echo "========================================"
        echo

        echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host:        $(hostname)"
        echo "Mode:        $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Restore")"
        echo "Target:      $TARGET"
        echo "Source:      $LOCAL_BACKUP"

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

handle_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    print_info
    print_info "❌ Restore failed!"
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
    echo "        Homelab Restore v$VERSION"
    echo "=========================================="
    echo "Mode: $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Restore")"
    echo
}

print_field() {
    printf "%-18s %s\n" "$1" "$2"

    if [[ -n "$LOG_FILE" ]]; then
        printf "%-18s %s\n" "$1" "$2" >> "$LOG_FILE"
    fi
}

print_help() {
    cat << EOF
Homelab Restore v$VERSION

Pushes the local backup (created by backup.sh) back to the
ZimaOS server, restoring each folder to its respective remote
location. Use this after a drive failure or a fresh ZimaOS
install to bring the server back to its last backed-up state.

Usage:
    ./restore.sh [options]

Options:
    --target <name>      Restore only one target.
    --delete              Remove remote files that no longer exist
                           locally (exact mirror restore). Off by
                           default: restore only adds/updates files.
    --yes                 Skip the interactive confirmation prompt.
    --dry-run             Simulate the restore.
    --help                 Show help.
    --version              Show version.

Available targets:
    all
    appdata      -> $REMOTE_APPDATA (live app data, containers stopped/restarted)
$(printf '    %s\n' "${FOLDERS[@]}")

Examples:
    ./restore.sh --dry-run

    ./restore.sh --target appdata

$(printf '    ./restore.sh --target %s\n\n' "${FOLDERS[@]}")
EOF
}

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
# Verifies that the local source for a
# target exists and is not empty, so an
# empty/missing folder can never wipe
# out the remote copy with --delete.
#
# Arguments:
#   $1 - Local path (relative to LOCAL_BACKUP)
########################################
check_local_source() {
    local path="$1"
    local full="$LOCAL_BACKUP/$path"

    if [[ ! -d "$full" ]] || [[ -z "$(find "$full" -mindepth 1 -print -quit)" ]]; then
        print_info "❌ Local source is missing or empty: $full"
        print_info "   Refusing to restore from it."
        exit 1
    fi
}

print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
}

########################################
# Resolves the --target argument into
# the list of targets to restore.
########################################
select_targets() {
    local -a available=("appdata" "${FOLDERS[@]}")

    if [[ "$TARGET" == "all" ]]; then
        SELECTED=("${available[@]}")
        return
    fi

    for target in "${available[@]}"; do
        if [[ "${target,,}" == "${TARGET,,}" ]]; then
            SELECTED=("$target")
            return
        fi
    done

    print_info "❌ Unknown target: $TARGET"
    print_info
    print_info "Available targets:"
    print_info "  all"

    for target in "${available[@]}"; do
        print_info "  $target"
    done

    exit 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                TARGET="$2"
                shift 2
                ;;

            --delete)
                DELETE=true
                shift
                ;;

            --yes)
                ASSUME_YES=true
                shift
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
                echo "Run './restore.sh --help' for usage information."
                exit 1
                ;;
        esac
    done
}

########################################
# Shows what is about to happen and
# requires a typed confirmation before
# any remote data gets overwritten.
########################################
confirm_restore() {
    if [[ "$DRY_RUN" == true ]] || [[ "$ASSUME_YES" == true ]]; then
        return
    fi

    print_info "⚠️  This will push local data to $REMOTE, overwriting files there."
    if [[ "$DELETE" == true ]]; then
        print_info "⚠️  --delete is set: remote files with no local counterpart will be REMOVED."
    fi
    print_info "   Targets: ${SELECTED[*]}"
    print_info

    read -r -p "Type 'restore' to continue: " reply
    if [[ "$reply" != "restore" ]]; then
        print_info "Aborted."
        exit 1
    fi
}

get_local_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

get_local_size_bytes() {
    du -sb "$1" 2>/dev/null | cut -f1
}

get_remote_available_bytes() {
    ssh \
        -p "$SSH_PORT" \
        "$REMOTE" \
        "df -B1 --output=avail \"$1\" 2>/dev/null | tail -n 1"
}

check_disk_space() {
    local local_path="$1"
    local remote_path="$2"

    print_info
    print_info "Checking available disk space on ZimaOS..."

    local required
    required=$(get_local_size_bytes "$local_path")

    local available
    available=$(get_remote_available_bytes "$remote_path")

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
# Pushes a local directory to a remote
# path, showing overall transfer progress.
#
# Arguments:
#   $1 - Local source (relative to LOCAL_BACKUP)
#   $2 - Remote destination (absolute)
#   $3 - Label
########################################
push_path() {
    local local_rel="$1"
    local remote_path="$2"
    local label="$3"

    local source="$LOCAL_BACKUP/$local_rel"

    print_info "📂 $label"

    local size
    size=$(get_local_size "$source")

    print_field "   Size:" "$size"

    ssh -p "$SSH_PORT" "$REMOTE" "sudo mkdir -p '$remote_path'"

    local options=(
        -a
        --human-readable
        --rsync-path="sudo /usr/bin/rsync"
    )

    if [[ "$DELETE" == true ]]; then
        options+=(--delete)
    fi

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
        print_info "Restoring..."
    fi

    if rsync "${options[@]}" "$source/" "$REMOTE:$remote_path/"; then
        print_field "  Status:" "✅ OK"
        SUMMARY+=("$label|$size|✅ OK")
    else
        print_field "  Status:" "❌ Failed"
        SUMMARY+=("$label|$size|❌ Failed")
        return 1
    fi

    print_info
}

########################################
# Restores live AppData, stopping and
# restarting the app containers around
# the transfer so files aren't restored
# under an app that's actively writing.
########################################
restore_appdata() {
    print_section "Restoring AppData -> $REMOTE_APPDATA"

    check_local_source "Backups/AppData"
    check_disk_space "$LOCAL_BACKUP/Backups/AppData" "$REMOTE_APPDATA"

    local start_time=$(date +%s)
    local apps_stopped=false

    restart_remote_apps() {
        if [[ "$apps_stopped" == true ]]; then
            print_info "Restarting remote containers..."
            ssh -p "$SSH_PORT" "$REMOTE" "for c in $APPS; do docker start \"\$c\" || true; done"
            apps_stopped=false
        fi
    }
    trap restart_remote_apps EXIT

    if [[ "$DRY_RUN" == false ]]; then
        print_info "Stopping remote containers..."
        ssh -p "$SSH_PORT" "$REMOTE" "for c in $APPS; do docker stop \"\$c\" || true; done"
        apps_stopped=true
    fi

    push_path "Backups/AppData" "$REMOTE_APPDATA" "AppData" || return 1

    restart_remote_apps
    trap - EXIT

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo
    print_field "Completed in:" "$(format_time "$elapsed")"
}

########################################
# Restores a top-level backup folder to
# REMOTE_ROOT/<folder>.
#
# Arguments:
#   $1 - Folder name
########################################
restore_folder() {
    local folder="$1"

    print_section "Restoring $folder -> $REMOTE_ROOT/$folder"

    check_local_source "$folder"
    check_disk_space "$LOCAL_BACKUP/$folder" "$REMOTE_ROOT"

    local start_time=$(date +%s)

    push_path "$folder" "$REMOTE_ROOT/$folder" "$folder" || return 1

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo
    print_field "Completed in:" "$(format_time "$elapsed")"
}

restore_target() {
    local target="$1"

    if [[ "$target" == "appdata" ]]; then
        restore_appdata
    else
        restore_folder "$target"
    fi
}

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
        "$([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Restore")"

    print_field "Source:" "$LOCAL_BACKUP"
    print_field "Elapsed:" "$(format_time "$elapsed")"
}

initialize() {
    print_section "Initialization"

    check_dependencies

    test_ssh_connection
}

main() {
    parse_arguments "$@"

    initialize_logging

    write_log_header

    print_header

    select_targets

    initialize

    confirm_restore

    for target in "${SELECTED[@]}"; do
        restore_target "$target" || exit 1
    done

    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    echo
    print_info "🎉 Restore completed!"
    echo

    print_summary "$elapsed"

    echo

    write_log_footer "$elapsed"
}

main "$@"
