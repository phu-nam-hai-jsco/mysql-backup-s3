#!/usr/bin/env bash
# =============================================================================
# restore.sh — Restore MySQL backup from S3
# Usage:
#   ./scripts/restore.sh                     # List available backups
#   ./scripts/restore.sh <filename>          # Restore specific backup
#   ./scripts/restore.sh --latest            # Restore most recent backup
#   ./scripts/restore.sh --decrypt <file>    # Restore encrypted backup
# =============================================================================
set -euo pipefail

# ─── Load environment ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# ─── Parse arguments ─────────────────────────────────────────────────────────
DECRYPT=false
TARGET_FILE=""
LIST_ONLY=false
RESTORE_LATEST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list|-l)
            LIST_ONLY=true
            shift
            ;;
        --latest)
            RESTORE_LATEST=true
            shift
            ;;
        --decrypt|-d)
            DECRYPT=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options] [filename]"
            echo ""
            echo "Options:"
            echo "  --list, -l       List available backups on S3"
            echo "  --latest         Restore the most recent backup"
            echo "  --decrypt, -d    Decrypt GPG-encrypted backup before restore"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 --list"
            echo "  $0 mydb_2026-07-20_020000.sql.gz"
            echo "  $0 --decrypt mydb_2026-07-20_020000.sql.gz.gpg"
            echo "  $0 --latest"
            exit 0
            ;;
        *)
            TARGET_FILE="$1"
            shift
            ;;
    esac
done

# ─── S3 helper ───────────────────────────────────────────────────────────────
S3_BASE="s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}"

s3_cmd() {
    aws s3 "$@" \
        --endpoint-url "$S3_ENDPOINT_URL" \
        --region "${S3_REGION:-us-east-1}"
}

# ─── List backups ────────────────────────────────────────────────────────────
if [[ "$LIST_ONLY" == "true" ]]; then
    echo "Available backups in $S3_BASE:"
    echo ""
    s3_cmd ls "${S3_BASE}/" --human-readable | sort -k1,2 | tail -20
    echo ""
    echo "Use: $0 <filename> to restore"
    exit 0
fi

# ─── Resolve target file ─────────────────────────────────────────────────────
if [[ "$RESTORE_LATEST" == "true" ]]; then
    echo "Finding latest backup..."
    TARGET_FILE=$(s3_cmd ls "${S3_BASE}/" | sort -k1,2 | tail -1 | awk '{print $NF}')
    if [[ -z "$TARGET_FILE" ]]; then
        echo "ERROR: No backups found in $S3_BASE"
        exit 1
    fi
    echo "Latest: $TARGET_FILE"
fi

if [[ -z "$TARGET_FILE" ]]; then
    echo "ERROR: No filename specified. Use --list to see available backups."
    echo "  $0 --list"
    exit 1
fi

# ─── Confirmation ────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MySQL Restore from S3"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Source  : ${S3_BASE}/${TARGET_FILE}"
echo "  Target  : ${DB_HOST}:${DB_PORT:-3306}"
echo "  Decrypt : $DECRYPT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  WARNING: This will OVERWRITE data in the target database!"
read -rp "Are you sure? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# ─── Download ────────────────────────────────────────────────────────────────
RESTORE_DIR="/tmp/mysql-restore-$$"
mkdir -p "$RESTORE_DIR"
LOCAL_FILE="$RESTORE_DIR/$TARGET_FILE"

echo ""
echo "[1/3] Downloading from S3..."
s3_cmd cp "${S3_BASE}/${TARGET_FILE}" "$LOCAL_FILE" --quiet
echo "     Downloaded: $(du -h "$LOCAL_FILE" | cut -f1)"

# ─── Decrypt (optional) ─────────────────────────────────────────────────────
if [[ "$DECRYPT" == "true" ]] || [[ "$LOCAL_FILE" == *.gpg ]]; then
    echo "[2/3] Decrypting..."
    if [[ -z "${BACKUP_GPG_PASSPHRASE:-}" ]]; then
        echo "ERROR: Decryption requires BACKUP_GPG_PASSPHRASE in .env"
        rm -rf "$RESTORE_DIR"
        exit 1
    fi
    gpg --batch --yes --decrypt \
        --passphrase "$BACKUP_GPG_PASSPHRASE" \
        --output "${LOCAL_FILE%.gpg}" \
        "$LOCAL_FILE"
    rm -f "$LOCAL_FILE"
    LOCAL_FILE="${LOCAL_FILE%.gpg}"
    echo "     Decrypted: $(du -h "$LOCAL_FILE" | cut -f1)"
else
    echo "[2/3] No decryption needed"
fi

# ─── Decompress & Restore ───────────────────────────────────────────────────
echo "[3/3] Restoring to MySQL..."

if [[ "$LOCAL_FILE" == *.gz ]]; then
    gunzip -c "$LOCAL_FILE" | mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" \
        -u "$DB_USER" -p"$DB_PASSWORD"
elif [[ "$LOCAL_FILE" == *.sql ]]; then
    mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" \
        -u "$DB_USER" -p"$DB_PASSWORD" < "$LOCAL_FILE"
else
    echo "ERROR: Unsupported file format: $LOCAL_FILE"
    rm -rf "$RESTORE_DIR"
    exit 1
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf "$RESTORE_DIR"

echo ""
echo "✅ Restore completed successfully!"
echo "   Source: ${S3_BASE}/${TARGET_FILE}"
echo "   Target: ${DB_HOST}:${DB_PORT:-3306}"
