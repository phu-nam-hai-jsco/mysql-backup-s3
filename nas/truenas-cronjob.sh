#!/usr/bin/env bash
# =============================================================================
# truenas-cronjob.sh — TrueNAS SCALE cron job for backup monitoring
#
# TrueNAS SCALE uses Docker/Kubernetes natively. This script can be added
# as a cron job via TrueNAS UI:
#   System Settings → Advanced → Cron Jobs → Add
#
# Cấu hình:
#   Command: /mnt/pool/apps/mysql-backup-s3/nas/truenas-cronjob.sh
#   Schedule: 0 */6 * * * (every 6 hours)
#   User: root
#
# =============================================================================
set -euo pipefail

INSTALL_DIR="/mnt/pool/apps/mysql-backup-s3"
CONTAINER_NAME="db_daily_backup"
MAX_AGE_HOURS=25
LOG_FILE="/var/log/mysql-backup-monitor.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

main() {
    log "=== TrueNAS Backup Monitor ==="

    # Check container
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "WARNING: Container not running, attempting restart..."
        cd "$INSTALL_DIR"
        docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null
        log "Container restart attempted"
    else
        log "Container is running"
    fi

    # Load env
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        # shellcheck disable=SC1091
        source "$INSTALL_DIR/.env"

        # Check latest backup
        local LATEST_LINE
        LATEST_LINE=$(docker exec "$CONTAINER_NAME" aws s3 ls \
            "s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/" \
            --endpoint-url "$S3_ENDPOINT_URL" \
            --region "${S3_REGION:-us-east-1}" \
            2>/dev/null | sort -k1,2 | tail -1 || echo "")

        if [[ -n "$LATEST_LINE" ]]; then
            local LATEST_DATE
            LATEST_DATE=$(echo "$LATEST_LINE" | awk '{print $1 " " $2}')
            local LATEST_EPOCH NOW_EPOCH AGE_HOURS
            LATEST_EPOCH=$(date -d "$LATEST_DATE" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)

            if [[ "$LATEST_EPOCH" -gt 0 ]]; then
                AGE_HOURS=$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))
                if [[ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]]; then
                    log "ALERT: Backup is ${AGE_HOURS}h old (> ${MAX_AGE_HOURS}h)"
                    # TrueNAS alert system via midclt
                    if command -v midclt &>/dev/null; then
                        midclt call alert.oneshot_create \
                            '["MySQLBackupStale", "DB backup is '"${AGE_HOURS}"'h old (threshold: '"${MAX_AGE_HOURS}"'h)"]' \
                            2>/dev/null || true
                    fi
                else
                    log "OK: Backup is ${AGE_HOURS}h old"
                fi
            fi
        else
            log "ALERT: No backups found!"
        fi
    fi

    log "=== Monitor End ==="
}

main "$@"
