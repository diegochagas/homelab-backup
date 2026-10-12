#!/usr/bin/env bash
# Server-side checks backup.sh runs before pulling: the remote folders
# exist, the server's own backup is fresh, the destination has room.
# Sourced by backup.sh, never executed.
#
# Expects from backup.sh: SELECTED, REMOTE_ROOT, LOCAL_BACKUP,
# SERVER_BACKUP_LOG and MAX_SERVER_BACKUP_AGE_HOURS (config.sh).

########################################
# Verifies that the selected remote
# folders exist before starting.
########################################
#   check_remote_folders
check_remote_folders() {
    print_info
    print_info "Checking remote folders..."

    local folder
    for folder in "${SELECTED[@]}"; do
        if ! remote_dir_exists "$REMOTE_ROOT/$folder"; then
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
#   check_server_backup_freshness
check_server_backup_freshness() {
    print_info
    print_info "Checking server-side backup age..."

    local log_mtime
    log_mtime=$(remote_file_mtime "$SERVER_BACKUP_LOG" || true)

    if [[ -z "$log_mtime" ]]; then
        print_info "⚠️  Server backup log not found: $SERVER_BACKUP_LOG"
        print_info "⚠️  Has zimaos/backup.sh ever run on the server?"
        return 0
    fi

    report_server_backup_age "$((($(date +%s) - log_mtime) / 3600))"
}

# Prints the fresh/stale verdict for a server backup that is $1 hours old.
#   report_server_backup_age 36
report_server_backup_age() {
    local age_hours="$1"

    if ((age_hours > MAX_SERVER_BACKUP_AGE_HOURS)); then
        print_info "⚠️  WARNING: server-side backup is ${age_hours}h old ($((age_hours / 24)) days)"
        print_info "⚠️  The 4am cron job may be gone — ZimaOS updates wipe root's crontab."
        print_info "⚠️  Check on the server: sudo crontab -l"
    else
        print_field "Last run:" "${age_hours}h ago"
        print_info "✅ Server-side backup is fresh"
    fi
}

# Creates LOCAL_BACKUP (the destination of the pull).
#   create_backup_directory
create_backup_directory() {
    print_info
    print_info "Creating backup directory..."

    mkdir -p "$LOCAL_BACKUP"

    print_info "✅ Backup directory ready"
}

########################################
# Checks whether there is enough free
# space to perform the backup.
########################################
#   check_pull_disk_space
check_pull_disk_space() {
    print_info
    print_info "Checking available disk space..."

    local folder required=0
    for folder in "${SELECTED[@]}"; do
        required=$((required + $(remote_size_bytes "$REMOTE_ROOT/$folder")))
    done

    require_free_space "$required" "$(local_available_bytes "$LOCAL_BACKUP")"
}
