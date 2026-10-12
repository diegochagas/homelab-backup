#!/usr/bin/env bash
# Telegram notifications: the one wrapper around notify.sh, so tests can
# silence it (TELEGRAM_ENV pointing at a missing file) or replace it.
# Sourced, never executed.
#
# Expects from the entry script: SCRIPT_DIR.

########################################
# Sends a Telegram message through
# notify.sh (no-op when telegram.env
# isn't configured).
########################################
#   notify "✅ BACKUP FINISHED — $(hostname -s)"
notify() {
    local script="$SCRIPT_DIR/notify.sh"

    [[ -x "$script" ]] || return 0

    "$script" "$@" >/dev/null 2>&1 || true
}
