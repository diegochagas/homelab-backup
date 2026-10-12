#!/usr/bin/env bash
# The AppData target of restore.sh: live app data on the server, restored
# with the containers stopped. Sourced by restore.sh, never executed.
#
# Expects from restore.sh: LOCAL_BACKUP, REMOTE_APPDATA, APPS and DRY_RUN.

# True while the containers are stopped, so the EXIT trap restarts them
# whatever happens in between - including a failed transfer that makes
# main exit after restore_appdata has already returned.
APPS_STOPPED=false

########################################
# Restores live AppData, stopping and
# restarting the app containers around
# the transfer so files aren't restored
# under an app that's actively writing.
########################################
#   restore_appdata || exit 1
restore_appdata() {
    print_section "Restoring AppData -> $REMOTE_APPDATA"

    check_local_source "Backups/AppData"
    check_restore_disk_space "$LOCAL_BACKUP/Backups/AppData" "$REMOTE_APPDATA"

    local start_time
    start_time=$(date +%s)

    trap restart_remote_apps EXIT
    stop_remote_apps
    push_path "Backups/AppData" "$REMOTE_APPDATA" "AppData" || return 1
    restart_remote_apps
    trap - EXIT

    print_completed_in "$start_time"
}

# Stops APPS on the server (a dry run leaves them running).
#   stop_remote_apps
stop_remote_apps() {
    [[ "$DRY_RUN" == false ]] || return 0

    print_info "Stopping remote containers..."
    remote_docker_stop "$APPS"
    APPS_STOPPED=true
}

# Starts APPS again when stop_remote_apps stopped them; also the EXIT trap.
#   restart_remote_apps
restart_remote_apps() {
    [[ "$APPS_STOPPED" == true ]] || return 0

    print_info "Restarting remote containers..."
    remote_docker_start "$APPS"
    APPS_STOPPED=false
}
