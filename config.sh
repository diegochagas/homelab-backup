#!/usr/bin/env bash

########################################
# ZimaOS
########################################

REMOTE_HOST="192.168.15.8"
REMOTE_USER="diegochagas"
SSH_PORT=22

########################################
# Remote paths
########################################

REMOTE_MEDIA="/media/sdb1-ata-WDC_WD10EZEX-75"
REMOTE_APPDATA="/DATA/AppData"

########################################
# Local backup
########################################

LOCAL_BACKUP="/mnt/data/ZimaOS"

########################################
# Services
########################################

JELLYFIN_MEDIA="$REMOTE_MEDIA/jellyfin"
JELLYFIN_CONFIG="$REMOTE_APPDATA/jellyfin/config"

IMMICH_MEDIA="$REMOTE_MEDIA/immich"
IMMICH_DATABASE="$REMOTE_APPDATA/immich/pgdata"

# NEXTCLOUD_DATA="$REMOTE_MEDIA/nextcloud"

########################################
# Logging
########################################

LOG_DIR="./logs"

DRY_RUN=true