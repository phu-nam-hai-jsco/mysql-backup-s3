# NAS Deployment Scripts

Scripts hỗ trợ triển khai MySQL Backup to S3 trên các nền tảng NAS phổ biến.

## Danh sách scripts

| Script | Mục đích | NAS Platform |
|--------|----------|--------------|
| `setup.sh` | Cài đặt lần đầu (auto-detect NAS) | All |
| `nas-manage.sh` | Quản lý container (start/stop/backup/update) | All |
| `synology-task.sh` | Monitor qua Task Scheduler | Synology DSM |
| `qnap-autostart.sh` | Autostart sau reboot | QNAP QTS |
| `truenas-cronjob.sh` | Cron job monitor | TrueNAS SCALE |
| `unraid-userscript.sh` | User Scripts plugin | Unraid |

## Quick Start

```bash
# 1. Clone repo (hoặc download)
git clone https://github.com/phu-nam-hai-jsco/mysql-backup-s3.git
cd mysql-backup-s3

# 2. Chạy setup (tự detect NAS platform)
chmod +x nas/setup.sh
./nas/setup.sh
```

## Theo từng NAS Platform

### Synology DSM

```bash
# Setup
./nas/setup.sh
# → Cài vào /volume1/docker/mysql-backup-s3/

# Monitor tự động (Task Scheduler):
# DSM → Control Panel → Task Scheduler → Create → Scheduled Task
# User: root | Schedule: Daily 3:00 AM
# Command: bash /volume1/docker/mysql-backup-s3/nas/synology-task.sh
```

### QNAP QTS

```bash
# Setup
./nas/setup.sh
# → Cài vào /share/Container/mysql-backup-s3/

# Autostart sau reboot:
crontab -e
# Thêm dòng:
@reboot /share/Container/mysql-backup-s3/nas/qnap-autostart.sh
```

### TrueNAS SCALE

```bash
# Setup
./nas/setup.sh
# → Cài vào /mnt/pool/apps/mysql-backup-s3/

# Monitor cron:
# TrueNAS UI → System Settings → Advanced → Cron Jobs → Add
# Command: /mnt/pool/apps/mysql-backup-s3/nas/truenas-cronjob.sh
# Schedule: 0 */6 * * *
```

### Unraid

```bash
# Setup
./nas/setup.sh
# → Cài vào /mnt/user/appdata/mysql-backup-s3/

# Monitor:
# Community Apps → User Scripts → Add Script
# Paste nội dung nas/unraid-userscript.sh
# Schedule: Custom → 0 */6 * * *
```

## Manage Commands

Sau khi cài đặt, dùng `manage.sh` để quản lý:

```bash
cd /path/to/install/dir

./manage.sh start       # Khởi động container
./manage.sh stop        # Dừng container
./manage.sh restart     # Khởi động lại
./manage.sh status      # Xem trạng thái
./manage.sh logs        # Xem log real-time
./manage.sh backup      # Backup ngay lập tức
./manage.sh update      # Cập nhật image mới
./manage.sh test        # Test kết nối DB + S3
./manage.sh health      # Kiểm tra backup mới nhất
./manage.sh uninstall   # Gỡ cài đặt
```
