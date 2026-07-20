#!/usr/bin/env bash
# =============================================================================
# backup.sh — Manual backup trigger with optional encryption
# Usage:
#   ./scripts/backup.sh                  # Backup all databases
#   ./scripts/backup.sh mydb             # Backup specific database
#   ./scripts/backup.sh --encrypt mydb   # Backup with GPG encryption
# =============================================================================
set -euo pipefail

# ─── Load environment ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "  Run: cp .env.example .env && nano .env"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ─── Parse arguments ─────────────────────────────────────────────────────────
ENCRYPT=false
DB_TARGET="${DB_NAMES:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --encrypt|-e)
            ENCRYPT=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--encrypt] [database_name]"
            echo ""
            echo "Options:"
            echo "  --encrypt, -e    Encrypt backup with GPG (requires BACKUP_GPG_PASSPHRASE in .env)"
            echo "  --help, -h       Show this help"
            echo ""
            echo "If no database_name is specified, uses DB_NAMES from .env (or all databases)."
            exit 0
            ;;
        *)
            DB_TARGET="$1"
            shift
            ;;
    esac
done

# ─── Configuration ───────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_DIR="/tmp/mysql-backup-$$"
mkdir -p "$BACKUP_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MySQL Backup → S3"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Timestamp : $TIMESTAMP"
echo "  DB Host   : ${DB_HOST}:${DB_PORT:-3306}"
echo "  Database  : ${DB_TARGET:-ALL}"
echo "  S3 Target : s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/"
echo "  Encrypt   : $ENCRYPT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Dump database ───────────────────────────────────────────────────────────
DUMP_OPTS="${MYSQLDUMP_OPTS:---single-transaction --routines --triggers --events}"

if [[ -z "$DB_TARGET" ]]; then
    DUMP_FILE="$BACKUP_DIR/all-databases_${TIMESTAMP}.sql"
    echo "[1/4] Dumping ALL databases..."
    # shellcheck disable=SC2086
    mysqldump -h "$DB_HOST" -P "${DB_PORT:-3306}" \
        -u "$DB_USER" -p"$DB_PASSWORD" \
        $DUMP_OPTS --all-databases > "$DUMP_FILE"
else
    DUMP_FILE="$BACKUP_DIR/${DB_TARGET}_${TIMESTAMP}.sql"
    echo "[1/4] Dumping database: $DB_TARGET..."
    # shellcheck disable=SC2086
    mysqldump -h "$DB_HOST" -P "${DB_PORT:-3306}" \
        -u "$DB_USER" -p"$DB_PASSWORD" \
        $DUMP_OPTS "$DB_TARGET" > "$DUMP_FILE"
fi

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "     Dump size: $DUMP_SIZE"

# ─── Compress ────────────────────────────────────────────────────────────────
echo "[2/4] Compressing..."
gzip "$DUMP_FILE"
DUMP_FILE="${DUMP_FILE}.gz"
COMPRESSED_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "     Compressed: $COMPRESSED_SIZE"

# ─── Encrypt (optional) ─────────────────────────────────────────────────────
if [[ "$ENCRYPT" == "true" ]]; then
    if [[ -z "${BACKUP_GPG_PASSPHRASE:-}" ]]; then
        echo "ERROR: --encrypt requires BACKUP_GPG_PASSPHRASE in .env"
        rm -rf "$BACKUP_DIR"
        exit 1
    fi
    echo "[3/4] Encrypting with GPG..."
    gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase "$BACKUP_GPG_PASSPHRASE" \
        "$DUMP_FILE"
    rm -f "$DUMP_FILE"
    DUMP_FILE="${DUMP_FILE}.gpg"
    echo "     Encrypted: $(du -h "$DUMP_FILE" | cut -f1)"
else
    echo "[3/4] Skipping encryption (use --encrypt to enable)"
fi

# ─── Upload to S3 ───────────────────────────────────────────────────────────
FILENAME=$(basename "$DUMP_FILE")
S3_PATH="s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/${FILENAME}"

echo "[4/4] Uploading to S3..."
echo "     Target: $S3_PATH"

aws s3 cp "$DUMP_FILE" "$S3_PATH" \
    --endpoint-url "$S3_ENDPOINT_URL" \
    --region "${S3_REGION:-us-east-1}" \
    --quiet

echo ""
echo "✅ Backup completed successfully!"
echo "   File: $S3_PATH"
echo "   Size: $(du -h "$DUMP_FILE" | cut -f1)"

# ─── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf "$BACKUP_DIR"
echo "   Local temp files cleaned up."
