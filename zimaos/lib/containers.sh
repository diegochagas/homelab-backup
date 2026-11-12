#!/bin/sh
# Container helpers shared by failover-check.sh and failback.sh: which
# containers must stop before the data drive is swapped, which ones must run
# again afterwards, and which ones stayed down.
#
# Why not just $APPS: on 2026-11-12 two containers outside that list kept the
# returned data drive mounted read-only (failback could not mount it), and a
# third one died with its database and nothing started it again. So the stop
# list is $APPS plus whatever binds a path on the drive, and the start list is
# $APPS plus the containers that ran at the last healthy check.
#
# Needs `run` from lib/drive.sh (prints only when DRY_RUN=1).
DRY_RUN="${DRY_RUN:-0}"
APPS_SETTLE="${APPS_SETTLE:-20}" # seconds containers get before they are checked

# containers_running — names of the running containers, one per line.
#   containers_running | grep -qx nextcloud
containers_running() { docker ps --format '{{.Names}}' 2>/dev/null; }

# containers_using_path PATH — running containers with a bind mount at or
# under PATH, one per line.
#   containers_using_path /media/YOUR-DATA-DRIVE
containers_using_path() {
    for c in $(containers_running); do
        docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$c" 2>/dev/null |
            grep -q -e "^$1/" -e "^$1\$" && echo "$c"
    done
    return 0
}

# containers_snapshot FILE — remembers which containers run right now; call
# it only while the data drive is healthy. An empty answer keeps the old file.
#   containers_snapshot "$STATE_DIR/containers.running"
containers_snapshot() {
    [ "$DRY_RUN" = 1 ] && return 0
    names=$(containers_running)
    [ -n "$names" ] || return 0
    echo "$names" >"$1.tmp" && mv "$1.tmp" "$1"
}

# containers_expected FILE — $APPS first (databases before their clients),
# then the snapshot, without duplicates, one per line.
#   containers_expected "$STATE_DIR/containers.running"
containers_expected() {
    {
        for c in $APPS; do echo "$c"; done
        cat "$1" 2>/dev/null
    } | awk 'NF && !seen[$0]++'
}

# containers_stop_for_drive PATH — stops $APPS and every other running
# container that binds a path under PATH.
#   containers_stop_for_drive "$SRC_DATA"
containers_stop_for_drive() {
    users=$(containers_using_path "$1")
    # docker prints the container name; its stderr is noise when a container is already stopped.
    for c in $(echo "$APPS $users" | tr ' ' '\n' | awk 'NF && !seen[$0]++'); do
        run docker stop "$c" 2>/dev/null || true
    done
}

# containers_start_expected FILE — starts everything containers_expected lists.
#   containers_start_expected "$STATE_DIR/containers.running"
containers_start_expected() {
    for c in $(containers_expected "$1"); do
        run docker start "$c" 2>/dev/null || true
    done
}

# containers_down FILE — expected containers that are not running, space separated.
#   [ -z "$(containers_down "$STATE_DIR/containers.running")" ]
containers_down() {
    running=$(containers_running)
    for c in $(containers_expected "$1"); do
        echo "$running" | grep -qx -- "$c" || printf '%s ' "$c"
    done
}

# containers_verify FILE — waits APPS_SETTLE, starts the containers that are
# still down once more (a client that came up before its database) and prints
# the ones that stay down. Prints nothing when all run, and on a dry run.
#   down=$(containers_verify "$STATE_DIR/containers.running")
containers_verify() {
    [ "$DRY_RUN" = 1 ] && return 0
    sleep "$APPS_SETTLE"
    down=$(containers_down "$1")
    [ -n "$down" ] || return 0
    for c in $down; do docker start "$c" >/dev/null 2>&1 || true; done
    sleep "$APPS_SETTLE"
    containers_down "$1"
}
