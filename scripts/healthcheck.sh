#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — Verify latest backup is recent and valid on S3
#
# Can be run from the host machine or inside the container.
# Checks: backup exists, is not empty, and is within max age threshold.
#
# Usage:
#   ./scripts/healthcheck.sh           # Check backup freshness (default: 25h)
#   ./scripts/healthcheck.sh 48        # Custom max age in hours
#
# Exit codes:
#   0 = healthy (recent backup exists)
#   1 = unhealthy (backup too old or missing)
#   2 = configuration error
#
# Crontab example (check every 6 hours):
#   0 */6 * * * /path/to/mysql-backup-s3/scripts/healthcheck.sh
# =============================================================================
set -euo pipefail

# ─── Load environment ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Support running inside container (env vars already set) or from host (.env file)
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# Validate required variables
if [[ -z "${S3_BUCKET_NAME:-}" ]] || [[ -z "${S3_ENDPOINT_URL:-}" ]]; then
    echo "CRITICAL: Missing required env vars (S3_BUCKET_NAME, S3_ENDPOINT_URL)"
    exit 2
fi

# ─── Configuration ───────────────────────────────────────────────────────────
MAX_AGE_HOURS="${1:-25}"  # Default: 25 hours (allows 1h buffer for daily backups)
S3_BASE="s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}"

# ─── Check latest backup ────────────────────────────────────────────────────
LATEST_LINE=$(aws s3 ls "${S3_BASE}/" \
    --endpoint-url "$S3_ENDPOINT_URL" \
    --region "${S3_REGION:-us-east-1}" \
    2>/dev/null | sort -k1,2 | tail -1)

if [[ -z "$LATEST_LINE" ]]; then
    MSG="No backups found in $S3_BASE"
    echo "CRITICAL: $MSG"
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -sf -X POST "$WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"🚨 DB Backup CRITICAL: ${MSG}\"}" \
            >/dev/null 2>&1 || true
    fi
    exit 1
fi

# Parse date from S3 listing (format: 2026-07-20 02:00:05)
LATEST_DATE=$(echo "$LATEST_LINE" | awk '{print $1 " " $2}')
LATEST_FILE=$(echo "$LATEST_LINE" | awk '{print $NF}')
LATEST_SIZE=$(echo "$LATEST_LINE" | awk '{print $3}')

# Calculate age (compatible with GNU date and BusyBox date)
if date -d "$LATEST_DATE" +%s >/dev/null 2>&1; then
    LATEST_EPOCH=$(date -d "$LATEST_DATE" +%s)
elif date -j -f "%Y-%m-%d %H:%M:%S" "$LATEST_DATE" +%s >/dev/null 2>&1; then
    LATEST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$LATEST_DATE" +%s)
else
    echo "WARNING: Cannot parse date '$LATEST_DATE', skipping age check"
    exit 0
fi

NOW_EPOCH=$(date +%s)
AGE_HOURS=$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))

# ─── Evaluate health ────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Backup Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Latest file : $LATEST_FILE"
echo "  Date        : $LATEST_DATE"
echo "  Size        : $LATEST_SIZE bytes"
echo "  Age         : ${AGE_HOURS}h (max: ${MAX_AGE_HOURS}h)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check size (backup should not be 0 bytes)
if [[ "$LATEST_SIZE" -eq 0 ]]; then
    MSG="Latest backup is empty (0 bytes): ${LATEST_FILE}"
    echo "CRITICAL: $MSG"
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -sf -X POST "$WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"🚨 DB Backup CRITICAL: ${MSG}\"}" \
            >/dev/null 2>&1 || true
    fi
    exit 1
fi

# Check age
if [[ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]]; then
    MSG="Last backup is ${AGE_HOURS}h old (threshold: ${MAX_AGE_HOURS}h). File: ${LATEST_FILE}"
    echo "CRITICAL: $MSG"
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        curl -sf -X POST "$WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"🚨 DB Backup CRITICAL: ${MSG}\"}" \
            >/dev/null 2>&1 || true
    fi
    exit 1
fi

echo ""
echo "✅ HEALTHY — Backup is ${AGE_HOURS}h old (within ${MAX_AGE_HOURS}h threshold)"
exit 0
