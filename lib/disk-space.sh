#!/usr/bin/env bash
# Local size/free-space helpers and the shared "does it fit" check used
# before every copy. Sourced, never executed.

# Human-readable size of a local directory.
#   local_size_human "$LOCAL_BACKUP/Gallery"   # 1.2G
local_size_human() {
    du -sh "$1" 2>/dev/null | cut -f1
}

# Size of a local directory in bytes.
#   local_size_bytes "$LOCAL_BACKUP/Gallery"
local_size_bytes() {
    du -sb "$1" 2>/dev/null | cut -f1
}

########################################
# Returns the available space on the
# destination filesystem.
########################################
#   local_available_bytes "$LOCAL_BACKUP"
local_available_bytes() {
    df -B1 --output=avail "$1" | tail -n 1
}

# Total size in bytes of the filesystem mounted at a local path.
#   local_capacity_bytes "$D_MOUNTPOINT"
local_capacity_bytes() {
    df -B1 --output=size "$1" | tail -n 1 | tr -d ' '
}

# True when a local directory exists and holds at least one entry.
#   local_dir_has_files "$LOCAL_BACKUP/Gallery" || exit 1
local_dir_has_files() {
    [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -print -quit)" ]]
}

# Prints Required/Available and exits 1 when the copy would not fit.
#   require_free_space "$required_bytes" "$available_bytes"
require_free_space() {
    local required="$1"
    local available="$2"

    print_field "Required:" "$(numfmt --to=iec "$required")"
    print_field "Available:" "$(numfmt --to=iec "$available")"

    if ((available < required)); then
        print_field "Status:" "❌ Not enough disk space"
        exit 1
    fi

    print_field "Status:" "✅ Enough disk space"
    echo
}
