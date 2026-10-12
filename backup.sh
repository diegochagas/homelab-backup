#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR

########################################
# Homelab Backup
#
# Main entry point.
########################################
# Stage 2 of the backup chain (see README): pulls FOLDERS from the ZimaOS
# server into LOCAL_BACKUP, then pushes PUSH_SOURCE back onto a server
# drive. The logic lives in lib/*.sh; this file wires it together.

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
# shellcheck source=lib/disk-space.sh
source "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/telegram.sh
source "$SCRIPT_DIR/lib/telegram.sh"
# shellcheck source=lib/arguments.sh
source "$SCRIPT_DIR/lib/arguments.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/summary.sh
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=lib/backup-cli.sh
source "$SCRIPT_DIR/lib/backup-cli.sh"
# shellcheck source=lib/backup-checks.sh
source "$SCRIPT_DIR/lib/backup-checks.sh"
# shellcheck source=lib/backup-pull.sh
source "$SCRIPT_DIR/lib/backup-pull.sh"
# shellcheck source=lib/backup-push.sh
source "$SCRIPT_DIR/lib/backup-push.sh"
# shellcheck source=lib/backup-report.sh
source "$SCRIPT_DIR/lib/backup-report.sh"

readonly VERSION="2.1.0"
readonly SCRIPT_TITLE="Homelab Backup"
readonly MODE_LABEL="Backup"
readonly LOG_PREFIX=""

# Load configuration
load_config
require_config_values REMOTE_HOST REMOTE_USER SSH_PORT REMOTE_ROOT LOCAL_BACKUP \
    FOLDERS LOG_DIR SERVER_BACKUP_LOG MAX_SERVER_BACKUP_AGE_HOURS

# Optional reverse push (Linux Mint -> ZimaOS), see config.sh.example.
PUSH_SOURCE="${PUSH_SOURCE:-}"
PUSH_TARGET="${PUSH_TARGET:-}"
[[ -v PUSH_EXCLUDES ]] || declare -a PUSH_EXCLUDES=()
START_TIME=$(date +%s)
readonly START_TIME

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
# Main
########################################

# Pre-flight: tools, server, remote folders, destination, free space.
#   initialize
initialize() {
    print_section "Initialization"

    check_dependencies ssh rsync du

    test_ssh_connection

    check_server_backup_freshness

    check_remote_folders

    create_backup_directory

    check_pull_disk_space
}

# Pulls every selected folder, then pushes PUSH_SOURCE on full runs.
#   run_stages
run_stages() {
    local folder
    for folder in "${SELECTED[@]}"; do
        backup_folder "$folder" || exit 1
    done

    # A single --folder run is a partial backup; the push belongs to full runs.
    if [[ "$TARGET" == "all" ]]; then
        push_local_data || exit 1
    fi
}

# Console summary, log footer and Telegram message for a finished run.
#   report_completion
report_completion() {
    local elapsed
    elapsed=$(($(date +%s) - START_TIME))

    echo
    print_info "🎉 Backup completed!"
    echo

    print_summary "$elapsed" "Destination:" "$LOCAL_BACKUP"

    echo

    write_log_footer "$elapsed"
    notify_success "$elapsed"
}

main() {
    parse_arguments "$@"

    initialize_logging
    write_log_header "Folder:      $TARGET" "Destination: $LOCAL_BACKUP"
    print_header

    select_targets folder "${FOLDERS[@]}"
    initialize
    run_stages
    report_completion
}

main "$@"
