#!/usr/bin/env bash
# =============================================================================
# qnap-autostart.sh — Autostart backup container on QNAP NAS boot
#
# QNAP không tự restart container khi reboot (trừ khi dùng Container Station).
# Script này đặt vào autorun.sh hoặc crontab @reboot để đảm bảo backup
# container luôn chạy.
#
# Cài đặt:
#   Cách 1: Thêm vào /etc/config/qpkg.conf autorun
#   Cách 2: Crontab:
#     crontab -e
#     @reboot /share/Container/mysql-backup-s3/nas/qnap-autostart.sh
#
# =============================================================================
set -euo pipefail

INSTALL_DIR="/share/Container/mysql-backup-s3"
CONTAINER_NAME="db_daily_backup"
LOG_FILE="/var/log/mysql-backup-autostart.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Wait for Docker daemon to be ready (QNAP may take time after boot)
MAX_WAIT=120
WAITED=0
while ! docker info &>/dev/null 2>&1; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        log "ERROR: Docker not ready after ${MAX_WAIT}s. Giving up."
        exit 1
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

log "Docker ready (waited ${WAITED}s)"

# Start container
cd "$INSTALL_DIR"

if docker compose version &>/dev/null 2>&1; then
    docker compose up -d >> "$LOG_FILE" 2>&1
elif command -v docker-compose &>/dev/null; then
    docker-compose up -d >> "$LOG_FILE" 2>&1
fi

log "Backup container started successfully"
