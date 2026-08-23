#!/bin/sh
# Sends a Telegram message using the token/chat in telegram.env.
#
#   ./notify.sh "✅ Backup finished"
#   printf 'line1\nline2' | ./notify.sh
#
# Silently does nothing when telegram.env or the token is missing, so the
# backup scripts keep working on machines without Telegram configured.
set -u

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="${TELEGRAM_ENV:-$SCRIPT_DIR/telegram.env}"

[ -f "$ENV_FILE" ] || exit 0

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
# shellcheck source=/dev/null
. "$ENV_FILE"

[ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

if [ $# -gt 0 ]; then
    TEXT="$*"
else
    TEXT=$(cat)
fi

curl -sS -m 20 -o /dev/null \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$TEXT" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    || echo "notify.sh: could not reach Telegram" >&2
