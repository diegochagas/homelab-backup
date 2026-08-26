#!/usr/bin/env bash
# Installs backup.sh as a systemd --user timer on the Linux Mint workstation,
# replacing cron.
#
# Why: a crontab entry and this timer both firing at the same time of day
# runs backup.sh twice back-to-back (the second run's rsync finds almost
# nothing left to sync, so it looks like a near-instant duplicate). This
# script installs the timer and removes any old crontab entry so the job
# can't fire twice.
#
# Run from the repo checkout on the Linux Mint workstation (no sudo — this
# installs a user unit):
#   cd homelab-backup && ./install-timer.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="homelab-backup.service"
TIMER="homelab-backup.timer"

if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "❌ Missing $SCRIPT_DIR/config.sh — copy config.sh.example and adjust it first." >&2
    exit 1
fi

echo "Installing $SERVICE / $TIMER for $SCRIPT_DIR/backup.sh"

mkdir -p "$UNIT_DIR"
sed -e "s|@BACKUP_DIR@|$SCRIPT_DIR|g" "$SCRIPT_DIR/$SERVICE" > "$UNIT_DIR/$SERVICE"
cp "$SCRIPT_DIR/$TIMER" "$UNIT_DIR/$TIMER"

systemctl --user daemon-reload
systemctl --user enable --now "$TIMER"

# Drop any old cron entry for the same script so it doesn't fire twice.
# (grep -v exits 1, tripping pipefail, when the removed line was the only
# one — that's fine, it just means the crontab is now empty; `|| true`
# keeps the script going either way.)
if crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/backup.sh"; then
    crontab -l | grep -vF "$SCRIPT_DIR/backup.sh" | crontab - || true
    echo "Removed the old crontab entry for backup.sh (replaced by the timer)."
fi

echo
echo "✅ Installed. Next scheduled run:"
systemctl --user list-timers "$TIMER" --no-pager
echo
echo "Check status any time with: systemctl --user status $SERVICE $TIMER"
echo "Trigger a run right now with: systemctl --user start $SERVICE"
