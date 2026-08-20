#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

########################################
# Push EXIF Fixes
#
# One-off companion to restore.sh: pushes ONLY the specific
# Gallery files listed in exif-fixes/relpaths.txt back to the
# ZimaOS server, instead of restore.sh's full-folder sync.
#
# Source: these files already had date/GPS EXIF written into
# them locally (via exiftool, sourced from Immich's own database)
# under $LOCAL_BACKUP/Gallery. This pushes that exact byte content
# onto the live copy ZimaOS/Immich reads from.
########################################

# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration (same config.sh used by backup.sh/restore.sh)
source "$SCRIPT_DIR/config.sh"

readonly VERSION="1.0.0"
readonly REMOTE="$REMOTE_USER@$REMOTE_HOST"
readonly START_TIME=$(date +%s)
readonly FILE_LIST="$SCRIPT_DIR/exif-fixes/relpaths.txt"
readonly REMOTE_GALLERY="$REMOTE_ROOT/Gallery"

########################################
# Runtime options
########################################

DRY_RUN=false
ASSUME_YES=false
STOP_IMMICH=false
declare LOG_FILE=""

########################################
# Functions (mirrors restore.sh's helpers)
########################################

print_info() {
    echo "$@"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$@" >> "$LOG_FILE"
    fi
}

print_field() {
    printf "%-18s %s\n" "$1" "$2"
    if [[ -n "$LOG_FILE" ]]; then
        printf "%-18s %s\n" "$1" "$2" >> "$LOG_FILE"
    fi
}

print_section() {
    print_info
    print_info "========================================"
    print_info "$1"
    print_info "========================================"
    print_info
}

initialize_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/push-exif-fixes_$(date +%Y-%m-%d_%H-%M-%S).log"
    : > "$LOG_FILE"
}

format_time() {
    local seconds="$1"
    printf "%02d:%02d:%02d\n" \
        $((seconds/3600)) \
        $(((seconds%3600)/60)) \
        $((seconds%60))
}

handle_error() {
    local exit_code="$1" line="$2" command="$3"
    print_info
    print_info "❌ Push failed!"
    print_info
    print_field "Exit code:" "$exit_code"
    print_field "Line:" "$line"
    print_field "Command:" "$command"
    print_info
    print_info "See log:"
    print_info "  $LOG_FILE"
    exit "$exit_code"
}

print_header() {
    echo
    echo "=========================================="
    echo "        Push EXIF Fixes v$VERSION"
    echo "=========================================="
    echo "Mode: $([[ "$DRY_RUN" == true ]] && echo "Simulation" || echo "Push")"
    echo
}

print_help() {
    cat << EOF
Push EXIF Fixes v$VERSION

Pushes only the files listed in exif-fixes/relpaths.txt from
\$LOCAL_BACKUP/Gallery to \$REMOTE_ROOT/Gallery on ZimaOS -
unlike restore.sh, this does not touch anything else in Gallery.

Usage:
    ./push-exif-fixes.sh [options]

Options:
    --stop-immich   Stop/restart immich-server + immich-postgres
                     around the transfer. Not required - rsync
                     writes each file via a temp-file-then-rename,
                     so Immich never sees a partially-written file -
                     but available for extra caution.
    --yes            Skip the interactive confirmation prompt.
    --dry-run        Simulate the push (rsync -n --stats).
    --help           Show help.
    --version        Show version.

Examples:
    ./push-exif-fixes.sh --dry-run
    ./push-exif-fixes.sh
EOF
}

print_version() { echo "$VERSION"; }

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stop-immich) STOP_IMMICH=true; shift ;;
            --yes) ASSUME_YES=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --help) print_help; exit 0 ;;
            --version) print_version; exit 0 ;;
            *)
                print_info "❌ Unknown argument: $1"
                echo
                echo "Run './push-exif-fixes.sh --help' for usage information."
                exit 1
                ;;
        esac
    done
}

check_dependencies() {
    print_info "Checking dependencies..."
    for command in ssh rsync; do
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
    if ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" "echo Connected" >/dev/null 2>&1; then
        print_info "✅ Connected to ZimaOS"
    else
        print_info "❌ Could not connect to ZimaOS"
        exit 1
    fi
}

check_file_list() {
    if [[ ! -s "$FILE_LIST" ]]; then
        print_info "❌ Missing or empty file list: $FILE_LIST"
        exit 1
    fi

    local missing=0
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if [[ ! -f "$LOCAL_BACKUP/Gallery/$rel" ]]; then
            print_info "   ⚠️  Not found locally, skipping: $rel"
            missing=$((missing+1))
        fi
    done < "$FILE_LIST"

    local total
    total=$(grep -c . "$FILE_LIST")
    print_field "Files listed:" "$total"
    if (( missing > 0 )); then
        print_field "Missing locally:" "$missing"
    fi
}

confirm_push() {
    if [[ "$DRY_RUN" == true ]] || [[ "$ASSUME_YES" == true ]]; then
        return
    fi

    print_info "⚠️  This will overwrite $(grep -c . "$FILE_LIST") specific files under"
    print_info "   $REMOTE:$REMOTE_GALLERY with the locally-fixed versions."
    if [[ "$STOP_IMMICH" == true ]]; then
        print_info "⚠️  immich-server/immich-postgres will be stopped and restarted around the transfer."
    fi
    print_info

    read -r -p "Type 'push' to continue: " reply
    if [[ "$reply" != "push" ]]; then
        print_info "Aborted."
        exit 1
    fi
}

stop_immich() {
    print_info "Stopping immich-server / immich-postgres on ZimaOS..."
    ssh -p "$SSH_PORT" "$REMOTE" "docker stop immich-server immich-postgres || true"
}

start_immich() {
    print_info "Restarting immich-server / immich-postgres on ZimaOS..."
    ssh -p "$SSH_PORT" "$REMOTE" "docker start immich-postgres immich-server || true"
}

push_files() {
    print_section "Pushing fixed files -> $REMOTE_GALLERY"

    local options=(
        -a
        --human-readable
        --rsync-path="sudo /usr/bin/rsync"
        --files-from="$FILE_LIST"
    )

    if [[ "$DRY_RUN" == true ]]; then
        options+=(-n --stats)
    else
        options+=(--info=progress2,name0)
        print_info "Transferring..."
    fi

    if rsync "${options[@]}" "$LOCAL_BACKUP/Gallery/" "$REMOTE:$REMOTE_GALLERY/"; then
        print_info "✅ Push OK"
    else
        print_info "❌ Push failed"
        return 1
    fi
}

main() {
    parse_arguments "$@"
    initialize_logging
    print_header

    print_section "Initialization"
    check_dependencies
    test_ssh_connection
    check_file_list

    confirm_push

    local immich_stopped=false
    if [[ "$STOP_IMMICH" == true ]] && [[ "$DRY_RUN" == false ]]; then
        restart_on_exit() {
            if [[ "$immich_stopped" == true ]]; then
                start_immich
            fi
        }
        trap restart_on_exit EXIT
        stop_immich
        immich_stopped=true
    fi

    push_files || exit 1

    if [[ "$immich_stopped" == true ]]; then
        start_immich
        immich_stopped=false
        trap - EXIT
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    echo
    print_info "🎉 Push completed!"
    print_field "Elapsed:" "$(format_time "$elapsed")"
    echo

    if [[ "$DRY_RUN" == false ]]; then
        print_info "Next: refresh Immich's metadata for these assets so its"
        print_info "stored checksum matches the edited files:"
        print_info
        print_info '  KEY="<your-immich-api-key>"'
        print_info '  curl -X POST -H "x-api-key: $KEY" -H "Content-Type: application/json" \'
        print_info '    -d @exif-fixes/refresh_asset_ids.json \'
        print_info "    http://$REMOTE_HOST:2283/api/assets/jobs"
        echo
    fi
}

main "$@"
