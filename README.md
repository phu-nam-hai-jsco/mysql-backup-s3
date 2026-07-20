# MySQL Backup to S3 (iDrive e2)

Automated daily MySQL/MariaDB backup to S3-compatible storage using Docker, built on top of [databacker/mysql-backup](https://github.com/databacker/mysql-backup).

## Features

- **Scheduled automatic backups** via cron (powered by `databack/mysql-backup`)
- **S3-compatible storage** — iDrive e2, AWS S3, MinIO, Backblaze B2, Cloudflare R2, etc.
- **Automatic retention/pruning** — auto-delete old backups
- **Compression** — gzip by default
- **Safe filenames** — ISO 8601 timestamps with safe characters
- **Multi-arch** — `linux/amd64` + `linux/arm64` (x86 servers, Raspberry Pi, Apple Silicon)
- **Custom image extras** — AWS CLI, GPG encryption, healthcheck script
- **Timezone-aware scheduling**
- **Pre/post backup scripts** support
- **Container-native restore** — single command restore from S3

## Architecture

```
┌──────────────────────┐         LAN            ┌──────────────┐
│ Backup Container     │ ───── port 3306 ────▶  │  MySQL/Maria │
│ (databack/mysql-backup│                        │   Database   │
│  + aws-cli, gpg)     │                        └──────────────┘
└──────────┬───────────┘
           │
           │  S3 API (HTTPS)
           ▼
┌──────────────────────┐
│  S3-Compatible Store │
│  (iDrive e2 / AWS /  │
│   MinIO / R2 / B2)   │
└──────────────────────┘
```

## Quick Start

### 1. Prepare MySQL backup user

```sql
CREATE USER 'backup_user'@'192.168.1.%' IDENTIFIED BY 'strong_password_here';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS
  ON *.* TO 'backup_user'@'192.168.1.%';
FLUSH PRIVILEGES;
```

### 2. Verify MySQL is accessible from LAN

```bash
mysql -h 192.168.1.50 -u backup_user -p -e "SELECT 1;"
```

### 3. Configure S3 storage

1. Create a bucket on your S3-compatible provider
2. Create access keys with read/write permissions

### 4. Deploy

```bash
git clone https://github.com/phu-nam-hai-jsco/mysql-backup-s3.git
cd mysql-backup-s3

cp .env.example .env
chmod 600 .env
nano .env  # Fill in your values

docker compose up -d
```

### 5. Verify

```bash
# Check container is running
docker compose ps

# View logs
docker compose logs -f backup

# Trigger a one-time manual backup
docker compose exec backup /mysql-backup dump --once
```

## Configuration

All configuration is done via environment variables in `.env`:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DB_HOST` | Yes | - | IP/hostname of MySQL server |
| `DB_PORT` | No | `3306` | MySQL port |
| `DB_USER` | Yes | - | MySQL user for backup |
| `DB_PASSWORD` | Yes | - | MySQL password |
| `DB_NAMES` | No | (all) | Databases to backup (comma-separated). Empty = all |
| `S3_BUCKET_NAME` | Yes | - | S3 bucket name |
| `S3_PREFIX` | No | `db-backups` | Folder prefix in bucket |
| `S3_ACCESS_KEY` | Yes | - | S3 access key |
| `S3_SECRET_KEY` | Yes | - | S3 secret key |
| `S3_ENDPOINT_URL` | Yes | - | S3 endpoint URL |
| `S3_REGION` | No | `us-east-1` | S3 region |
| `BACKUP_CRON` | No | `0 2 * * *` | Cron schedule (default: 2 AM daily) |
| `TZ` | No | `Asia/Ho_Chi_Minh` | Timezone |
| `BACKUP_RETENTION` | No | `720h` | Auto-prune backups older than this |
| `DB_DEBUG` | No | `false` | Enable verbose logging |

### Upstream environment variable mapping

| Your `.env` | Maps to (upstream) | Purpose |
|-------------|-------------------|---------|
| `DB_HOST` | `DB_SERVER` | Database hostname |
| `DB_PASSWORD` | `DB_PASS` | Database password |
| `DB_NAMES` | `DB_DUMP_INCLUDE` | Databases to include |
| `BACKUP_CRON` | `DB_DUMP_CRON` | Cron schedule |
| `S3_ACCESS_KEY` | `AWS_ACCESS_KEY_ID` | S3 credentials |
| `S3_SECRET_KEY` | `AWS_SECRET_ACCESS_KEY` | S3 credentials |
| `S3_ENDPOINT_URL` | `AWS_ENDPOINT_URL` | S3 endpoint |
| `S3_REGION` | `AWS_REGION` | S3 region |
| `BACKUP_RETENTION` | `DB_DUMP_RETENTION` | Retention policy |

Full reference: [databacker/mysql-backup configuration docs](https://github.com/databacker/mysql-backup/blob/main/docs/configuration.md)

## Restore

### Option A: Container-native restore (recommended)

```bash
docker run --rm \
  -e DB_SERVER=${DB_HOST} \
  -e DB_PORT=${DB_PORT:-3306} \
  -e DB_USER=${DB_USER} \
  -e DB_PASS=${DB_PASSWORD} \
  -e DB_RESTORE_TARGET="s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/db_backup_2026-07-20T02-00-00Z.gz" \
  -e AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY} \
  -e AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY} \
  -e AWS_ENDPOINT_URL=${S3_ENDPOINT_URL} \
  -e AWS_REGION=${S3_REGION:-us-east-1} \
  databack/mysql-backup restore
```

### Option B: Manual restore script

```bash
./scripts/restore.sh --list           # List available backups
./scripts/restore.sh --latest         # Restore most recent
./scripts/restore.sh <filename>       # Restore specific backup
./scripts/restore.sh --decrypt <file> # Restore encrypted backup
```

### Option C: Download and restore manually

```bash
aws s3 cp --endpoint-url ${S3_ENDPOINT_URL} \
  s3://${S3_BUCKET_NAME}/${S3_PREFIX:-db-backups}/db_backup_2026-07-20T02-00-00Z.gz \
  ./backup.sql.gz

gunzip backup.sql.gz
mysql -h ${DB_HOST} -u ${DB_USER} -p < backup.sql
```

## Manual Backup

```bash
# Via the container (recommended)
docker compose exec backup /mysql-backup dump --once

# Via the manual script (requires mysqldump + aws-cli on host)
./scripts/backup.sh                  # All databases
./scripts/backup.sh mydb             # Specific database
./scripts/backup.sh --encrypt mydb   # With GPG encryption
```

## Monitoring

```bash
# View logs
docker compose logs --tail 50 backup

# Check container health
docker inspect --format='{{.State.Health.Status}}' db_daily_backup

# Healthcheck script (verifies latest backup on S3 is recent)
./scripts/healthcheck.sh        # Default: 25h threshold
./scripts/healthcheck.sh 48     # Custom threshold
```

## Pre/Post Backup Scripts

```yaml
# In docker-compose.yml, uncomment:
volumes:
  - ./scripts.d/pre-backup:/scripts.d/pre-backup:ro
  - ./scripts.d/post-backup:/scripts.d/post-backup:ro
```

See [upstream docs](https://github.com/databacker/mysql-backup/blob/main/docs/backup.md).

## Supported S3 Providers

| Provider | Endpoint URL Format |
|----------|-------------------|
| iDrive e2 | `https://s3.{region}.idrivee2.com` |
| AWS S3 | (no custom endpoint needed) |
| MinIO | `https://your-minio-server:9000` |
| Backblaze B2 | `https://s3.{region}.backblazeb2.com` |
| DigitalOcean Spaces | `https://{region}.digitaloceanspaces.com` |
| Cloudflare R2 | `https://{account-id}.r2.cloudflarestorage.com` |

## NAS Deployment

```bash
chmod +x nas/setup.sh && ./nas/setup.sh
```

See [nas/README.md](nas/README.md) for platform-specific guides.

## CI/CD — GitHub Actions

| Event | Action |
|-------|--------|
| Push to `main` | Build + push `:latest` + `:sha-xxx` |
| Git tag `v*` | Build + push `:1.0.0`, `:1.0`, `:1` |
| Pull Request | Build only (validates image) |
| Manual | Build + push custom tag |

```bash
docker pull ghcr.io/phu-nam-hai-jsco/mysql-backup-s3:latest
```

## Troubleshooting

### Container exits immediately

Ensure `command: ["dump"]` is set in docker-compose.yml. The upstream image requires an explicit command.

### Docker build fails with Permission Denied

The base image runs as non-root `appuser`. The Dockerfile uses `USER root` for package install, then `USER appuser` for runtime.

### Cannot connect to MySQL

1. Check MySQL `bind-address` (should be `0.0.0.0`)
2. Verify firewall allows port 3306
3. Check user grants

### S3 upload fails with AccessDenied

1. Verify credentials in `.env`
2. Check bucket policy allows `PutObject`/`GetObject`
3. Verify endpoint URL format

## License

See [LICENSE](LICENSE) file.
