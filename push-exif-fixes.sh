#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=lib/output.sh
source "$SCRIPT_DIR/lib/output.sh"
# shellcheck source=lib/logging.sh
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=lib/config-loader.sh
source "$SCRIPT_DIR/lib/config-loader.sh"
# shellcheck source=lib/remote.sh
source "$SCRIPT_DIR/lib/remote.sh"
# shellcheck source=lib/transfer.sh
source "$SCRIPT_DIR/lib/transfer.sh"
# shellcheck source=lib/arguments.sh
source "$SCRIPT_DIR/lib/arguments.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"

readonly VERSION="1.0.0"
readonly SCRIPT_TITLE="Push EXIF Fixes"
readonly MODE_LABEL="Push"
readonly LOG_PREFIX="push-exif-fixes_"

# Load configuration (same config.sh used by backup.sh/restore.sh)
load_config
require_config_values REMOTE_HOST REMOTE_USER SSH_PORT REMOTE_ROOT LOCAL_BACKUP LOG_DIR

START_TIME=$(date +%s)
readonly START_TIME
readonly FILE_LIST="$SCRIPT_DIR/exif-fixes/relpaths.txt"
readonly REMOTE_GALLERY="$REMOTE_ROOT/Gallery"

########################################
# Runtime options
########################################

DRY_RUN=false
ASSUME_YES=false
STOP_IMMICH=false
declare LOG_FILE=""

# Listed files absent from the local Gallery (set by warn_missing_files).
MISSING_FILES=0

# True while Immich is stopped, so the EXIT trap restarts it even when the
# transfer fails.
IMMICH_STOPPED=false

# rsync wrappers (lib/transfer.sh) record outcomes here; unused by this
# script's single transfer but required by the shared helpers.
declare -a SUMMARY=()

########################################
# Functions
########################################

# clean-code-audit: allow-long -- heredoc help text, no logic
print_help() {
    cat <<EOF
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

# Parses the command line into STOP_IMMICH, ASSUME_YES and DRY_RUN.
#   parse_arguments "$@"
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stop-immich) STOP_IMMICH=true && shift ;;
            --yes) ASSUME_YES=true && shift ;;
            --dry-run) DRY_RUN=true && shift ;;
            --help) print_help && exit 0 ;;
            --version) print_version && exit 0 ;;
            *)
                print_info "❌ Unknown argument: $1"
                exit_with_usage_hint
                ;;
        esac
    done
}

# Exits 1 without a file list; otherwise reports how many files it names
# and how many are missing locally.
#   check_file_list
check_file_list() {
    if [[ ! -s "$FILE_LIST" ]]; then
        print_info "❌ Missing or empty file list: $FILE_LIST"
        exit 1
    fi

    warn_missing_files

    print_field "Files listed:" "$(grep -c . "$FILE_LIST")"
    if ((MISSING_FILES > 0)); then
        print_field "Missing locally:" "$MISSING_FILES"
    fi
}

# Warns about every listed file absent from the local Gallery and counts
# them in MISSING_FILES (rsync --files-from skips them).
#   warn_missing_files
warn_missing_files() {
    MISSING_FILES=0

    local rel
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ ! -f "$LOCAL_BACKUP/Gallery/$rel" ]] || continue

        print_info "   ⚠️  Not found locally, skipping: $rel"
        MISSING_FILES=$((MISSING_FILES + 1))
    done <"$FILE_LIST"
}

# Typed confirmation before overwriting files on the server.
#   confirm_push
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

# Stops Immich on the server (with --stop-immich, never on a dry run) and
# arms the EXIT trap that restarts it.
#   stop_immich_if_requested
stop_immich_if_requested() {
    [[ "$STOP_IMMICH" == true ]] && [[ "$DRY_RUN" == false ]] || return 0

    trap restart_immich_if_stopped EXIT
    print_info "Stopping immich-server / immich-postgres on ZimaOS..."
    remote_docker_stop "immich-server immich-postgres"
    IMMICH_STOPPED=true
}

# Restarts Immich (postgres first) when stop_immich_if_requested stopped it;
# also the EXIT trap.
#   restart_immich_if_stopped
restart_immich_if_stopped() {
    [[ "$IMMICH_STOPPED" == true ]] || return 0

    print_info "Restarting immich-server / immich-postgres on ZimaOS..."
    remote_docker_start "immich-postgres immich-server"
    IMMICH_STOPPED=false
    trap - EXIT
}

# rsync --files-from push of the listed Gallery files.
#   push_files || exit 1
push_files() {
    print_section "Pushing fixed files -> $REMOTE_GALLERY"

    build_rsync_options --rsync-path="sudo /usr/bin/rsync" --files-from="$FILE_LIST"
    print_transfer_start "Transferring..."

    if run_rsync "$LOCAL_BACKUP/Gallery/" "$REMOTE:$REMOTE_GALLERY/"; then
        print_info "✅ Push OK"
    else
        print_info "❌ Push failed"
        return 1
    fi
}

# Elapsed time, then (after a real push) how to make Immich pick the
# changes up.
#   print_completion
print_completion() {
    local elapsed=$(($(date +%s) - START_TIME))

    echo
    print_info "🎉 Push completed!"
    print_field "Elapsed:" "$(format_time "$elapsed")"
    echo

    if [[ "$DRY_RUN" == false ]]; then
        print_next_steps
    fi
}

# Immich keeps a checksum per asset; the edited files need a metadata
# refresh so it matches again.
#   print_next_steps
# shellcheck disable=SC2016,SC1003 # a literal curl command for the user to paste
print_next_steps() {
    print_info "Next: refresh Immich's metadata for these assets so its"
    print_info "stored checksum matches the edited files:"
    print_info
    print_info '  KEY="<your-immich-api-key>"'
    print_info '  curl -X POST -H "x-api-key: $KEY" -H "Content-Type: application/json" \'
    print_info '    -d @exif-fixes/refresh_asset_ids.json \'
    print_info "    http://$REMOTE_HOST:2283/api/assets/jobs"
    echo
}

main() {
    parse_arguments "$@"
    initialize_logging
    print_header

    print_section "Initialization"
    check_dependencies ssh rsync
    test_ssh_connection
    check_file_list

    confirm_push

    stop_immich_if_requested
    push_files || exit 1
    restart_immich_if_stopped

    print_completion
}

main "$@"
