#!/usr/bin/env bash
# Thin ssh wrappers around the ZimaOS server: every remote command the
# workstation scripts run goes through here, so tests/fakes/ssh can answer
# them and no test reaches the real server. Sourced, never executed.
#
# Expects from the entry script: REMOTE (user@host, set by load_config) and
# SSH_PORT (config.sh).

# Runs one command line on the server.
#   remote_run "stat -c %Y \"$SERVER_BACKUP_LOG\""
remote_run() {
    ssh -p "$SSH_PORT" "$REMOTE" "$1"
}

# Like remote_run, but never prompts and gives up after 5s: for the first
# contact, so a password prompt or a sleeping server cannot hang the run.
#   remote_run_unattended "echo Connected"
remote_run_unattended() {
    ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" "$1"
}

# True when the server answers over ssh.
#   remote_is_reachable || exit 1
remote_is_reachable() {
    remote_run_unattended "echo Connected" >/dev/null 2>&1
}

# True when the remote directory exists.
#   remote_dir_exists "$REMOTE_ROOT/Gallery"
remote_dir_exists() {
    remote_run "[ -d \"$1\" ]"
}

# True when the remote path is a mountpoint (a drive, not a plain folder).
#   remote_is_mountpoint "$PUSH_TARGET"
remote_is_mountpoint() {
    remote_run "mountpoint -q \"$1\""
}

# Modification time (epoch seconds) of a remote file; empty when absent.
#   remote_file_mtime "$SERVER_BACKUP_LOG"
remote_file_mtime() {
    remote_run "stat -c %Y \"$1\" 2>/dev/null"
}

########################################
# Returns the size of a remote directory.
#
# Arguments:
#   $1 - Remote directory
########################################
#   remote_size_human "$REMOTE_ROOT/Gallery"   # 1.2G
remote_size_human() {
    remote_run "du -sh \"$1\" 2>/dev/null | cut -f1"
}

########################################
# Returns the size of a remote directory
# in bytes.
#
# Arguments:
#   $1 - Remote directory
########################################
#   remote_size_bytes "$REMOTE_ROOT/Gallery"
remote_size_bytes() {
    remote_run "du -sb \"$1\" 2>/dev/null | cut -f1"
}

# Free bytes on the filesystem holding a remote path.
#   remote_available_bytes "$REMOTE_ROOT"
remote_available_bytes() {
    remote_run "df -B1 --output=avail \"$1\" 2>/dev/null | tail -n 1"
}

# "USED AVAIL" bytes of the filesystem holding a remote path.
#   read -r used avail < <(remote_used_and_available_bytes "$PUSH_TARGET")
remote_used_and_available_bytes() {
    remote_run "df -B1 --output=used,avail \"$1\" | tail -n 1"
}

# Creates a remote directory as root (restore targets live on root-owned
# drives).
#   remote_mkdir "$REMOTE_APPDATA"
remote_mkdir() {
    remote_run "sudo mkdir -p '$1'"
}

# Stops the given containers on the server, one by one, ignoring the ones
# that are not running.
#   remote_docker_stop "$APPS"
remote_docker_stop() {
    remote_docker stop "$1"
}

# Starts the given containers on the server, one by one.
#   remote_docker_start "immich-postgres immich-server"
remote_docker_start() {
    remote_docker start "$1"
}

# remote_docker VERB "name1 name2": runs `docker VERB` per container; a
# missing container never aborts the loop.
remote_docker() {
    remote_run "for c in $2; do docker $1 \"\$c\" || true; done"
}
