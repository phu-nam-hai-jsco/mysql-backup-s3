#!/usr/bin/env bash
# =============================================================================
# unraid-userscript.sh — Unraid User Scripts plugin integration
#
# Unraid dùng plugin "User Scripts" để chạy cron jobs.
# Cài đặt:
#   1. Cài plugin: Community Apps → User Scripts
#   2. Settings → User Scripts → Add Script
#   3. Copy nội dung file này vào script editor
#   4. Schedule: Custom → 0 */6 * * * (every 6 hours)
#
# =============================================================================
set -euo pipefail

INSTALL_DIR="/mnt/user/appdata/mysql-backup-s3"
CONTAINER_NAME="db_daily_backup"
MAX_AGE_HOURS=25

# ─── Unraid notification helper ──────────────────────────────────────────────
# Uses Unraid's built-in notification system
notify_unraid() {
    local severity="$1"  # normal, warning, alert
    local subject="$2"
    local message="$3"

    /usr/local/emhttp/webGui/scripts/notify \
        -s "$subject" \
        -d "$message" \
        -i "$severity" \
        2>/dev/null || echo "Notification: [$severity] $subject - $message"
}

main() {
    echo "[$(date)] MySQL Backup Monitor — Unraid"

    # Check container running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "WARNING: Container not running!"
        notify_unraid "warning" "DB Backup Down" "Container $CONTAINER_NAME is not running. Attempting restart..."

        cd "$INSTALL_DIR"
        docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null

        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            notify_unraid "normal" "DB Backup Restarted" "Container was down and has been successfully restarted."
        else
            notify_unraid "alert" "DB Backup FAILED" "Container could not be restarted! Manual intervention required."
            exit 1
        fi
    fi

    # Load .env
    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        echo "ERROR: .env not found"
        exit 1
    fi

    # shellcheck disable=SC1091
    source "$INSTALL_DIR/.env"

    # Check latest backup
    local LATEST_LINE
    LATEST_LINE=$(docker exec "$CONTAINER_NAME" aws s3 ls \
        "s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/" \
        --endpoint-url "$S3_ENDPOINT_URL" \
        --region "${S3_REGION:-us-east-1}" \
        2>/dev/null | sort -k1,2 | tail -1 || echo "")

    if [[ -z "$LATEST_LINE" ]]; then
        notify_unraid "alert" "DB Backup EMPTY" "No backup files found on S3!"
        exit 1
    fi

    local LATEST_DATE
    LATEST_DATE=$(echo "$LATEST_LINE" | awk '{print $1 " " $2}')
    local LATEST_EPOCH NOW_EPOCH AGE_HOURS
    LATEST_EPOCH=$(date -d "$LATEST_DATE" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)

    if [[ "$LATEST_EPOCH" -gt 0 ]]; then
        AGE_HOURS=$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))
        echo "Latest backup age: ${AGE_HOURS}h (threshold: ${MAX_AGE_HOURS}h)"

        if [[ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]]; then
            notify_unraid "warning" "DB Backup Stale" \
                "Last backup is ${AGE_HOURS}h old (expected < ${MAX_AGE_HOURS}h). Check container logs."
        else
            echo "Backup is healthy (${AGE_HOURS}h old)"
        fi
    fi
}

main "$@"
