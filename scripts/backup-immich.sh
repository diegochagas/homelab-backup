#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config.sh
source "$PROJECT_DIR/config.sh"

mkdir -p "$LOCAL_BACKUP/immich" "$LOG_DIR"

echo "Backing up Immich from $REMOTE_HOST..."
rsync -az --delete -e "ssh -p $SSH_PORT" \
	"$REMOTE_USER@$REMOTE_HOST:$IMMICH_MEDIA/" \
	"$LOCAL_BACKUP/immich/media/"

rsync -az --delete -e "ssh -p $SSH_PORT" \
	"$REMOTE_USER@$REMOTE_HOST:$IMMICH_DATABASE/" \
	"$LOCAL_BACKUP/immich/database/"

