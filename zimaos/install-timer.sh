#!/usr/bin/env bash
# Installs the ZimaOS server-side backup as a root systemd timer, replacing
# cron.
#
# Why: on this ZimaOS box /var is a tmpfs (see `mount | grep ' /var '`), and
# root's crontab lives under /var/spool/cron — so it is wiped on every
# reboot, not just OTA updates, silently killing the daily backup. /etc
# persists across both, so a systemd unit there is reliable.
#
# Run with sudo from the repo checkout on the ZimaOS server:
#   cd homelab-backup && sudo ./zimaos/install-timer.sh
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "❌ Run this with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="homelab-backup.service"
TIMER="homelab-backup.timer"

if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
    echo "❌ Missing $SCRIPT_DIR/config.sh — copy config.sh.example and adjust it first." >&2
    exit 1
fi

echo "Installing $SERVICE / $TIMER for $BACKUP_DIR/zimaos/backup.sh"

sed -e "s|@BACKUP_DIR@|$BACKUP_DIR|g" "$SCRIPT_DIR/$SERVICE" > "$UNIT_DIR/$SERVICE"
cp "$SCRIPT_DIR/$TIMER" "$UNIT_DIR/$TIMER"

systemctl daemon-reload
systemctl enable --now "$TIMER"

# Drop any old cron entry for the same script so it doesn't fire twice.
# (grep -v exits 1, tripping pipefail, when the removed line was the only
# one — that's fine, it just means the crontab is now empty; `|| true`
# keeps the script going either way.)
if crontab -l 2>/dev/null | grep -qF "$BACKUP_DIR/zimaos/backup.sh"; then
    crontab -l | grep -vF "$BACKUP_DIR/zimaos/backup.sh" | crontab - || true
    echo "Removed the old crontab entry for backup.sh (replaced by the timer)."
fi

echo
echo "✅ Installed. Next scheduled run:"
systemctl list-timers "$TIMER" --no-pager
echo
echo "Check status any time with: systemctl status $SERVICE $TIMER"
echo "Trigger a run right now with: sudo systemctl start $SERVICE"
