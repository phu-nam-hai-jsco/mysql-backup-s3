#!/usr/bin/env bash
# =============================================================================
# synology-task.sh — Script dùng cho Synology Task Scheduler
#
# Trên Synology DSM:
#   Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script
#
# Cấu hình:
#   - User: root
#   - Schedule: Daily, 3:00 AM (sau giờ backup 2:00 AM)
#   - Command: bash /volume1/docker/mysql-backup-s3/nas/synology-task.sh
#
# Script thực hiện:
#   1. Kiểm tra container backup đang chạy
#   2. Nếu container die → restart
#   3. Kiểm tra backup mới nhất < 25h
#   4. Gửi notification qua Synology DSM nếu có vấn đề
# =============================================================================
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
INSTALL_DIR="/volume1/docker/mysql-backup-s3"
CONTAINER_NAME="db_daily_backup"
MAX_AGE_HOURS=25
LOG_FILE="/var/log/mysql-backup-monitor.log"

# ─── Logging ─────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ─── Synology Notification ───────────────────────────────────────────────────
# Uses synodsmnotify to push notification to DSM desktop
notify_dsm() {
    local title="$1"
    local message="$2"
    if command -v synodsmnotify &>/dev/null; then
        synodsmnotify @administrators "$title" "$message"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    log "=== MySQL Backup Monitor Start ==="

    # 1. Check container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "WARNING: Container $CONTAINER_NAME is not running!"

        # Try to restart
        log "Attempting restart..."
        cd "$INSTALL_DIR"
        if docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null; then
            log "Container restarted successfully"
            notify_dsm "DB Backup" "Container was down and has been restarted"
        else
            log "ERROR: Failed to restart container!"
            notify_dsm "DB Backup ALERT" "Container is DOWN and could not be restarted!"
            exit 1
        fi
    else
        log "Container is running"
    fi

    # 2. Load .env for S3 config
    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        log "ERROR: .env not found at $INSTALL_DIR/.env"
        exit 1
    fi

    # shellcheck disable=SC1091
    source "$INSTALL_DIR/.env"

    # 3. Check latest backup age
    local LATEST_LINE
    LATEST_LINE=$(docker exec "$CONTAINER_NAME" aws s3 ls \
        "s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/" \
        --endpoint-url "$S3_ENDPOINT_URL" \
        --region "${S3_REGION:-us-east-1}" \
        2>/dev/null | sort -k1,2 | tail -1 || echo "")

    if [[ -z "$LATEST_LINE" ]]; then
        log "WARNING: No backups found on S3!"
        notify_dsm "DB Backup ALERT" "No backup files found on S3 storage!"
        exit 1
    fi

    local LATEST_DATE
    LATEST_DATE=$(echo "$LATEST_LINE" | awk '{print $1 " " $2}')
    local LATEST_FILE
    LATEST_FILE=$(echo "$LATEST_LINE" | awk '{print $NF}')
    local LATEST_SIZE
    LATEST_SIZE=$(echo "$LATEST_LINE" | awk '{print $3}')

    # Calculate age
    local LATEST_EPOCH NOW_EPOCH AGE_HOURS
    LATEST_EPOCH=$(date -d "$LATEST_DATE" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)

    if [[ "$LATEST_EPOCH" -gt 0 ]]; then
        AGE_HOURS=$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))
        log "Latest backup: $LATEST_FILE (${AGE_HOURS}h old, ${LATEST_SIZE} bytes)"

        if [[ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]]; then
            log "WARNING: Backup is stale (${AGE_HOURS}h > ${MAX_AGE_HOURS}h threshold)"
            notify_dsm "DB Backup ALERT" "Last backup is ${AGE_HOURS}h old! Expected < ${MAX_AGE_HOURS}h. File: $LATEST_FILE"
        else
            log "Backup is fresh (${AGE_HOURS}h <= ${MAX_AGE_HOURS}h)"
        fi

        # Check for empty backup
        if [[ "$LATEST_SIZE" -eq 0 ]]; then
            log "WARNING: Latest backup is 0 bytes!"
            notify_dsm "DB Backup ALERT" "Latest backup file is EMPTY (0 bytes): $LATEST_FILE"
        fi
    else
        log "Could not parse backup date"
    fi

    # 4. Rotate monitor log (keep last 1000 lines)
    if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1000 ]]; then
        tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi

    log "=== MySQL Backup Monitor End ==="
}

main "$@"
