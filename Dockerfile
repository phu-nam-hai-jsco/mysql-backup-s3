# =============================================================================
# Custom MySQL Backup Image
# Extends databack/mysql-backup with:
#   - AWS CLI for manual S3 operations & healthcheck
#   - GPG for client-side encryption support
#   - Custom healthcheck script
#
# Base image: databack/mysql-backup (golang binary on Alpine, runs as appuser)
# Docs: https://github.com/databacker/mysql-backup
# =============================================================================
FROM databack/mysql-backup:latest

# The base image runs as non-root user (appuser). Switch to root to install packages.
USER root

# Install additional tools for manual operations & healthcheck
RUN apk add --no-cache \
    aws-cli \
    gnupg \
    curl \
    jq \
    && rm -rf /var/cache/apk/*

# Copy custom scripts
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY scripts/backup.sh /usr/local/bin/manual-backup.sh
COPY scripts/restore.sh /usr/local/bin/manual-restore.sh
RUN chmod +x /usr/local/bin/healthcheck.sh \
    /usr/local/bin/manual-backup.sh \
    /usr/local/bin/manual-restore.sh

# Switch back to non-root user for runtime security
USER appuser

# Healthcheck: verify the backup process is alive via the built-in entrypoint
HEALTHCHECK --interval=5m --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f "mysql-backup" > /dev/null || exit 1
