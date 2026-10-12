#!/usr/bin/env bash

set -Eeuo pipefail
trap 'handle_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR

########################################
# Homelab Restore
#
# Disaster-recovery counterpart to backup.sh: pushes the local
# backup (pulled by backup.sh) back to the ZimaOS server, each
# folder to its respective remote location.
########################################
# The logic lives in lib/*.sh; this file wires it together.

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
# shellcheck source=lib/arguments.sh
source "$SCRIPT_DIR/lib/arguments.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/summary.sh
source "$SCRIPT_DIR/lib/summary.sh"
# shellcheck source=lib/restore-cli.sh
source "$SCRIPT_DIR/lib/restore-cli.sh"
# shellcheck source=lib/restore-targets.sh
source "$SCRIPT_DIR/lib/restore-targets.sh"
# shellcheck source=lib/restore-appdata.sh
source "$SCRIPT_DIR/lib/restore-appdata.sh"

readonly VERSION="1.0.0"
readonly SCRIPT_TITLE="Homelab Restore"
readonly MODE_LABEL="Restore"
readonly LOG_PREFIX="restore_"

# Load configuration
load_config
require_config_values REMOTE_HOST REMOTE_USER SSH_PORT REMOTE_ROOT REMOTE_APPDATA \
    APPS LOCAL_BACKUP FOLDERS LOG_DIR

START_TIME=$(date +%s)
readonly START_TIME

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
# Main
########################################

# Pre-flight: tools and the ssh connection.
#   initialize
initialize() {
    print_section "Initialization"

    check_dependencies ssh rsync du

    test_ssh_connection
}

# Restores every selected target, stopping at the first failure.
#   restore_selected_targets
restore_selected_targets() {
    local target
    for target in "${SELECTED[@]}"; do
        restore_target "$target" || exit 1
    done
}

# Console summary and log footer for a finished run.
#   report_completion
report_completion() {
    local elapsed
    elapsed=$(($(date +%s) - START_TIME))

    echo
    print_info "🎉 Restore completed!"
    echo

    print_summary "$elapsed" "Source:" "$LOCAL_BACKUP"

    echo

    write_log_footer "$elapsed"
}

main() {
    parse_arguments "$@"

    initialize_logging
    write_log_header "Target:      $TARGET" "Source:      $LOCAL_BACKUP"
    print_header

    select_targets target appdata "${FOLDERS[@]}"
    initialize
    confirm_restore
    restore_selected_targets
    report_completion
}

main "$@"
