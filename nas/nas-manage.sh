#!/usr/bin/env bash
# =============================================================================
# nas-manage.sh — Quản lý MySQL Backup container trên NAS
#
# Script này được copy vào thư mục cài đặt khi chạy setup.sh
# Sử dụng:
#   ./manage.sh start       — Khởi động container
#   ./manage.sh stop        — Dừng container
#   ./manage.sh restart     — Khởi động lại
#   ./manage.sh status      — Kiểm tra trạng thái
#   ./manage.sh logs        — Xem log (real-time)
#   ./manage.sh backup      — Trigger backup ngay lập tức
#   ./manage.sh update      — Pull image mới + restart
#   ./manage.sh test        — Test kết nối DB + S3
#   ./manage.sh health      — Kiểm tra sức khỏe backup
#   ./manage.sh uninstall   — Gỡ cài đặt
# =============================================================================
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="db_daily_backup"
IMAGE="ghcr.io/phu-nam-hai-jsco/mysql-backup-s3:latest"

# Detect compose command
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    error "Docker Compose not found!"
    exit 1
fi

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_start() {
    info "Starting backup container..."
    $COMPOSE_CMD up -d
    ok "Container started"
    echo ""
    cmd_status
}

cmd_stop() {
    info "Stopping backup container..."
    $COMPOSE_CMD down
    ok "Container stopped"
}

cmd_restart() {
    info "Restarting backup container..."
    $COMPOSE_CMD restart
    ok "Container restarted"
}

cmd_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Backup Container Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "N/A")
        local uptime
        uptime=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null)
        local image_id
        image_id=$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null | cut -c 8-19)

        echo -e "  Container : ${GREEN}running${NC}"
        echo "  Health    : $health"
        echo "  Image     : $image_id"
        echo "  Started   : $uptime"
    else
        echo -e "  Container : ${RED}stopped${NC}"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

cmd_logs() {
    local lines="${1:-50}"
    info "Showing last $lines lines (Ctrl+C to exit)..."
    docker logs --tail "$lines" -f "$CONTAINER_NAME"
}

cmd_backup() {
    info "Triggering immediate backup..."
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker exec "$CONTAINER_NAME" backup-now
        ok "Backup triggered! Check logs: ./manage.sh logs"
    else
        error "Container is not running. Start it first: ./manage.sh start"
        exit 1
    fi
}

cmd_update() {
    info "Pulling latest image..."
    docker pull "$IMAGE"
    ok "Image updated"

    info "Recreating container with new image..."
    $COMPOSE_CMD up -d --force-recreate
    ok "Container updated and restarted"
    echo ""
    cmd_status
}

cmd_test() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Connection Test"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Load .env
    if [[ ! -f .env ]]; then
        error ".env file not found!"
        exit 1
    fi

    # shellcheck disable=SC1091
    source .env

    # Test MySQL connection
    echo ""
    info "Testing MySQL connection to ${DB_HOST}:${DB_PORT:-3306}..."
    if command -v mysql &>/dev/null; then
        if mysql -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;" &>/dev/null; then
            ok "MySQL connection successful"
        else
            error "MySQL connection FAILED"
            echo "  Check: DB_HOST, DB_PORT, DB_USER, DB_PASSWORD in .env"
        fi
    elif command -v mariadb &>/dev/null; then
        if mariadb -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;" &>/dev/null; then
            ok "MariaDB connection successful"
        else
            error "MariaDB connection FAILED"
        fi
    else
        warn "mysql/mariadb client not installed on NAS — testing via container..."
        if docker exec "$CONTAINER_NAME" mysqladmin ping -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASSWORD" &>/dev/null 2>&1; then
            ok "MySQL connection (via container) successful"
        else
            error "MySQL connection FAILED (via container)"
        fi
    fi

    # Test S3 connection
    echo ""
    info "Testing S3 connection to ${S3_ENDPOINT_URL}..."
    if docker exec "$CONTAINER_NAME" aws s3 ls "s3://${S3_BUCKET_NAME}/" \
        --endpoint-url "$S3_ENDPOINT_URL" \
        --region "${S3_REGION:-us-east-1}" \
        &>/dev/null 2>&1; then
        ok "S3 connection successful (bucket: ${S3_BUCKET_NAME})"
    else
        error "S3 connection FAILED"
        echo "  Check: S3_ACCESS_KEY, S3_SECRET_KEY, S3_ENDPOINT_URL, S3_BUCKET_NAME in .env"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

cmd_health() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Backup Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Load .env
    if [[ ! -f .env ]]; then
        error ".env file not found!"
        exit 1
    fi

    # shellcheck disable=SC1091
    source .env

    # List recent backups on S3
    info "Checking recent backups on S3..."
    local LISTING
    LISTING=$(docker exec "$CONTAINER_NAME" aws s3 ls \
        "s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/" \
        --endpoint-url "$S3_ENDPOINT_URL" \
        --region "${S3_REGION:-us-east-1}" \
        2>/dev/null | sort -k1,2 | tail -5)

    if [[ -z "$LISTING" ]]; then
        error "No backups found in s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/"
        exit 1
    fi

    echo ""
    echo "  Recent backups:"
    echo "$LISTING" | while read -r line; do
        echo "    $line"
    done

    # Check latest age
    local LATEST_DATE
    LATEST_DATE=$(echo "$LISTING" | tail -1 | awk '{print $1 " " $2}')
    local LATEST_FILE
    LATEST_FILE=$(echo "$LISTING" | tail -1 | awk '{print $NF}')

    if command -v date &>/dev/null; then
        local LATEST_EPOCH NOW_EPOCH AGE_HOURS
        LATEST_EPOCH=$(date -d "$LATEST_DATE" +%s 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        if [[ "$LATEST_EPOCH" -gt 0 ]]; then
            AGE_HOURS=$(( (NOW_EPOCH - LATEST_EPOCH) / 3600 ))
            echo ""
            echo "  Latest    : $LATEST_FILE"
            echo "  Age       : ${AGE_HOURS}h"
            if [[ "$AGE_HOURS" -le 25 ]]; then
                ok "Backup is fresh (< 25h)"
            else
                warn "Backup is ${AGE_HOURS}h old (may be stale)"
            fi
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

cmd_uninstall() {
    echo ""
    warn "This will remove the backup container and its data."
    read -rp "Are you sure? (yes/no): " CONFIRM

    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi

    info "Stopping and removing container..."
    $COMPOSE_CMD down -v 2>/dev/null || true
    docker rmi "$IMAGE" 2>/dev/null || true
    ok "Container and image removed"

    echo ""
    warn "Config files (.env, docker-compose.yml) are still in: $SCRIPT_DIR"
    echo "  Remove manually: rm -rf $SCRIPT_DIR"
}

# ─── Help ────────────────────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo "MySQL Backup to S3 — NAS Management"
    echo ""
    echo "Usage: ./manage.sh <command>"
    echo ""
    echo "Commands:"
    echo "  start       Start the backup container"
    echo "  stop        Stop the backup container"
    echo "  restart     Restart the backup container"
    echo "  status      Show container status"
    echo "  logs [N]    Show last N lines of logs (default: 50, follow mode)"
    echo "  backup      Trigger an immediate backup now"
    echo "  update      Pull latest image and recreate container"
    echo "  test        Test MySQL and S3 connections"
    echo "  health      Check backup freshness on S3"
    echo "  uninstall   Remove container, image, and volumes"
    echo "  help        Show this help"
    echo ""
    echo "Examples:"
    echo "  ./manage.sh start          # Start backup service"
    echo "  ./manage.sh backup         # Run backup immediately"
    echo "  ./manage.sh logs 100       # Show last 100 lines"
    echo "  ./manage.sh test           # Verify DB + S3 connections"
    echo "  ./manage.sh update         # Update to latest version"
    echo ""
}

# ─── Route command ───────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    status)    cmd_status ;;
    logs)      cmd_logs "$@" ;;
    backup)    cmd_backup ;;
    update)    cmd_update ;;
    test)      cmd_test ;;
    health)    cmd_health ;;
    uninstall) cmd_uninstall ;;
    help|--help|-h) cmd_help ;;
    *)
        error "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac
