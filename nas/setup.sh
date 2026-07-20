#!/usr/bin/env bash
# =============================================================================
# setup.sh — Cài đặt MySQL Backup trên NAS (Synology / QNAP / TrueNAS / OpenWRT)
#
# Chạy 1 lần duy nhất khi cài đặt lần đầu:
#   chmod +x nas/setup.sh && ./nas/setup.sh
#
# Script sẽ:
#   1. Kiểm tra Docker có sẵn trên NAS
#   2. Tạo thư mục lưu trữ + .env từ template
#   3. Pull image
#   4. Khởi động container backup
# =============================================================================
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Detect NAS Platform ─────────────────────────────────────────────────────
detect_nas() {
    if [[ -f /etc/synoinfo.conf ]]; then
        echo "synology"
    elif [[ -f /etc/config/qpkg.conf ]] || [[ -d /share/CACHEDEV1_DATA ]]; then
        echo "qnap"
    elif command -v midclt &>/dev/null || [[ -d /mnt/pool ]]; then
        echo "truenas"
    elif [[ -f /etc/openwrt_release ]]; then
        echo "openwrt"
    elif [[ -f /etc/unraid-version ]]; then
        echo "unraid"
    else
        echo "generic"
    fi
}

# ─── Default paths per NAS platform ─────────────────────────────────────────
get_default_path() {
    local platform="$1"
    case "$platform" in
        synology)  echo "/volume1/docker/mysql-backup-s3" ;;
        qnap)     echo "/share/Container/mysql-backup-s3" ;;
        truenas)  echo "/mnt/pool/apps/mysql-backup-s3" ;;
        unraid)   echo "/mnt/user/appdata/mysql-backup-s3" ;;
        openwrt)  echo "/opt/mysql-backup-s3" ;;
        *)        echo "/opt/mysql-backup-s3" ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MySQL Backup to S3 — NAS Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Detect platform
    PLATFORM=$(detect_nas)
    info "Detected NAS platform: ${PLATFORM}"

    # Check Docker
    if ! command -v docker &>/dev/null; then
        error "Docker not found!"
        case "$PLATFORM" in
            synology) echo "  → Cài Docker từ Package Center trên DSM" ;;
            qnap)    echo "  → Cài Container Station từ App Center" ;;
            truenas) echo "  → Bật Docker qua Apps → Settings" ;;
            unraid)  echo "  → Docker đã tích hợp sẵn, kiểm tra Settings → Docker" ;;
            *)       echo "  → Cài Docker: https://docs.docker.com/engine/install/" ;;
        esac
        exit 1
    fi
    ok "Docker found: $(docker --version)"

    # Check docker compose
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        ok "Docker Compose (plugin): $(docker compose version --short)"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        ok "Docker Compose (standalone): $(docker-compose --version)"
    else
        error "Docker Compose not found!"
        echo "  → Cài docker-compose hoặc Docker Compose plugin"
        exit 1
    fi

    # Setup install path
    DEFAULT_PATH=$(get_default_path "$PLATFORM")
    echo ""
    read -rp "Install directory [$DEFAULT_PATH]: " INSTALL_PATH
    INSTALL_PATH="${INSTALL_PATH:-$DEFAULT_PATH}"

    # Create directories
    info "Creating directories..."
    mkdir -p "$INSTALL_PATH"/{logs,backups}
    ok "Created: $INSTALL_PATH"

    # Copy files
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

    cp "$PROJECT_DIR/docker-compose.yml" "$INSTALL_PATH/"
    cp "$PROJECT_DIR/nas/nas-manage.sh" "$INSTALL_PATH/manage.sh"
    chmod +x "$INSTALL_PATH/manage.sh"

    # Setup .env
    if [[ ! -f "$INSTALL_PATH/.env" ]]; then
        cp "$PROJECT_DIR/.env.example" "$INSTALL_PATH/.env"
        chmod 600 "$INSTALL_PATH/.env"
        warn ".env created from template — YOU MUST EDIT IT:"
        echo ""
        echo "    nano $INSTALL_PATH/.env"
        echo ""
        echo "  Fill in:"
        echo "    - DB_HOST (LAN IP of your MySQL server)"
        echo "    - DB_USER / DB_PASSWORD"
        echo "    - S3_ACCESS_KEY / S3_SECRET_KEY"
        echo "    - S3_BUCKET_NAME / S3_ENDPOINT_URL"
        echo ""
        read -rp "Press Enter after editing .env (or Ctrl+C to edit later)..."
    else
        ok ".env already exists, skipping"
    fi

    # Pull image
    info "Pulling Docker image..."
    docker pull ghcr.io/phu-nam-hai-jsco/mysql-backup-s3:latest
    ok "Image pulled successfully"

    # Start container
    echo ""
    read -rp "Start backup container now? [Y/n]: " START_NOW
    START_NOW="${START_NOW:-Y}"

    if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
        info "Starting container..."
        cd "$INSTALL_PATH"
        $COMPOSE_CMD up -d
        ok "Container started!"
        echo ""
        echo "  Verify: docker logs db_daily_backup"
        echo "  Manual backup: docker exec db_daily_backup backup-now"
    else
        info "Skipped. Start later with:"
        echo "  cd $INSTALL_PATH && $COMPOSE_CMD up -d"
    fi

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Setup Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Install path : $INSTALL_PATH"
    echo "  Platform     : $PLATFORM"
    echo "  Manage       : $INSTALL_PATH/manage.sh [start|stop|status|backup|logs|update]"
    echo ""
}

main "$@"
