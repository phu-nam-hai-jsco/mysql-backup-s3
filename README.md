# MySQL Backup to S3 (iDrive e2)

Automated daily MySQL/MariaDB backup to S3-compatible storage (iDrive e2, AWS S3, MinIO, etc.) using Docker.

## Features

- Scheduled automatic backups via cron
- S3-compatible storage (iDrive e2, AWS S3, MinIO, Backblaze B2...)
- Automatic retention policy (auto-delete old backups)
- Consistent dumps with `--single-transaction`
- Includes routines, triggers, and events
- Timezone-aware scheduling
- Healthcheck support
- Easy restore procedure

## Architecture

```
┌──────────────┐         LAN          ┌──────────────┐
│ Server Backup│ ───── port 3306 ────▶ │  MySQL/Maria │
│  (Docker)    │                       │   Database   │
└──────┬───────┘                       └──────────────┘
       │
       │  S3 API (HTTPS)
       ▼
┌──────────────┐
│  iDrive e2   │
│  (S3 Bucket) │
└──────────────┘
```

## Quick Start

### 1. Prepare MySQL backup user

On the **Database Server**, create a dedicated user with minimal permissions:

```sql
CREATE USER 'backup_user'@'192.168.1.%' IDENTIFIED BY 'strong_password_here';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS
  ON *.* TO 'backup_user'@'192.168.1.%';
FLUSH PRIVILEGES;
```

> Adjust `'192.168.1.%'` to match your backup server's subnet.

### 2. Verify MySQL is accessible from LAN

```bash
# On the backup server, test connectivity:
mysql -h 192.168.1.50 -u backup_user -p -e "SELECT 1;"
```

If this fails, check:
- MySQL `bind-address` is NOT `127.0.0.1` (should be `0.0.0.0` or the LAN IP)
- Firewall allows port 3306 from backup server IP

### 3. Configure iDrive e2

1. Login to [iDrive e2 Dashboard](https://www.idrive.com/e2/)
2. Create a new **Bucket** (e.g., `my-db-backups`)
3. Go to **Access Keys** → **Create Access Key**
4. Note down: `Access Key`, `Secret Key`, `Endpoint URL`, `Region`

### 4. Deploy

```bash
# Clone this repo on your Backup Server
git clone https://github.com/phu-nam-hai-jsco/mysql-backup-s3.git
cd mysql-backup-s3

# Configure
cp .env.example .env
chmod 600 .env
nano .env  # Fill in your values

# Start
docker compose up -d
```

### 5. Verify

```bash
# Trigger manual backup immediately
docker exec db_daily_backup backup-now

# Check logs
docker logs db_daily_backup

# Verify on iDrive e2 dashboard that .sql.gz file appeared
```

## Configuration

All configuration is done via environment variables in `.env`:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DB_HOST` | Yes | - | IP/hostname of MySQL server |
| `DB_PORT` | No | `3306` | MySQL port |
| `DB_USER` | Yes | - | MySQL user for backup |
| `DB_PASSWORD` | Yes | - | MySQL password |
| `DB_NAMES` | No | (all) | Space-separated DB names. Empty = all |
| `S3_BUCKET_NAME` | Yes | - | S3 bucket name |
| `S3_PREFIX` | No | `db-backups` | Folder prefix in bucket |
| `S3_ACCESS_KEY` | Yes | - | S3 access key |
| `S3_SECRET_KEY` | Yes | - | S3 secret key |
| `S3_ENDPOINT_URL` | Yes | - | S3 endpoint (e.g., iDrive e2 URL) |
| `S3_REGION` | No | `us-east-1` | S3 region |
| `BACKUP_CRON` | No | `0 2 * * *` | Cron schedule (default: 2 AM daily) |
| `TZ` | No | `Asia/Ho_Chi_Minh` | Timezone |
| `MYSQLDUMP_OPTS` | No | see .env.example | Extra mysqldump options |
| `BACKUP_RETENTION` | No | `30d` | Auto-delete backups older than this |

## Restore

### Restore latest backup

```bash
# List available backups
docker exec db_daily_backup ls /backup/

# Restore from S3 directly
docker run --rm \
  --env-file .env \
  -e DB_SERVER=${DB_HOST} \
  -e DB_PORT=${DB_PORT:-3306} \
  -e DB_USER=${DB_USER} \
  -e DB_PASS=${DB_PASSWORD} \
  -e DB_RESTORE_TARGET="s3://${S3_BUCKET_NAME}/${S3_PREFIX}/FILENAME.sql.gz" \
  -e AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY} \
  -e AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY} \
  -e AWS_ENDPOINT_URL=${S3_ENDPOINT_URL} \
  -e AWS_DEFAULT_REGION=${S3_REGION} \
  databack/mysql-backup restore
```

### Restore to a different server (test)

```bash
docker run --rm \
  -e DB_SERVER=192.168.1.99 \
  -e DB_PORT=3306 \
  -e DB_USER=root \
  -e DB_PASS=test_password \
  -e DB_RESTORE_TARGET="s3://my-bucket/db-backups/2026-07-20_020000.sql.gz" \
  -e AWS_ACCESS_KEY_ID=your_key \
  -e AWS_SECRET_ACCESS_KEY=your_secret \
  -e AWS_ENDPOINT_URL=https://s3.us-east-1.idrivee2.com \
  -e AWS_DEFAULT_REGION=us-east-1 \
  databack/mysql-backup restore
```

### Download backup manually

```bash
# Using AWS CLI (works with any S3-compatible storage)
aws s3 cp \
  --endpoint-url https://s3.us-east-1.idrivee2.com \
  s3://my-bucket/db-backups/2026-07-20_020000.sql.gz \
  ./backup.sql.gz

# Decompress and import
gunzip backup.sql.gz
mysql -h localhost -u root -p < backup.sql
```

## Monitoring

### Check backup status

```bash
# View recent logs
docker logs --tail 50 db_daily_backup

# Check container health
docker inspect --format='{{.State.Health.Status}}' db_daily_backup
```

### Verify backups are running

```bash
# List recent backups on S3 (using AWS CLI)
aws s3 ls \
  --endpoint-url ${S3_ENDPOINT_URL} \
  s3://${S3_BUCKET_NAME}/${S3_PREFIX}/ \
  --human-readable
```

### Simple monitoring script

Use `scripts/healthcheck.sh` to verify the latest backup is less than 25 hours old:

```bash
# Add to host crontab (runs every 6 hours)
0 */6 * * * /path/to/mysql-backup-s3/scripts/healthcheck.sh
```

## Troubleshooting

### Cannot connect to MySQL

```
Error: Can't connect to MySQL server on '192.168.1.50' (113)
```

**Fix:**
1. Check MySQL `bind-address` in `/etc/mysql/mysql.conf.d/mysqld.cnf`
2. Verify firewall: `sudo ufw allow from 192.168.1.0/24 to any port 3306`
3. Verify user grant: `SHOW GRANTS FOR 'backup_user'@'192.168.1.%';`

### S3 upload fails

```
Error: AccessDenied
```

**Fix:**
1. Verify `S3_ACCESS_KEY` and `S3_SECRET_KEY` are correct
2. Check bucket policy allows `PutObject`
3. Verify `S3_ENDPOINT_URL` format (should include `https://`)

### Backup file is empty / 0 bytes

**Fix:**
1. Check `DB_NAMES` is correct (typo in database name)
2. Verify user has `SELECT` permission on target database
3. Check disk space on container: `docker exec db_daily_backup df -h`

## Security Best Practices

1. **File permissions**: `chmod 600 .env` — prevent other users from reading credentials
2. **Dedicated user**: Use a MySQL user with minimal backup-only permissions
3. **Network**: Restrict MySQL access to backup server IP only
4. **Bucket policy**: Restrict S3 bucket access to backup credentials only
5. **Encryption**: Consider enabling server-side encryption on the S3 bucket

## Supported S3 Providers

| Provider | Endpoint URL Format |
|----------|-------------------|
| iDrive e2 | `https://s3.{region}.idrivee2.com` |
| AWS S3 | (no custom endpoint needed) |
| MinIO | `https://your-minio-server:9000` |
| Backblaze B2 | `https://s3.{region}.backblazeb2.com` |
| DigitalOcean Spaces | `https://{region}.digitaloceanspaces.com` |
| Cloudflare R2 | `https://{account-id}.r2.cloudflarestorage.com` |

## License

See [LICENSE](LICENSE) file.
