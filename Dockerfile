# =============================================================================
# Custom MySQL Backup Image
# Extends databack/mysql-backup with:
#   - AWS CLI for manual S3 operations
#   - GPG for encryption support
#   - Custom healthcheck script
# =============================================================================
FROM databack/mysql-backup:latest

# Install additional tools
RUN apk add --no-cache \
    aws-cli \
    gnupg \
    bash \
    curl \
    jq \
    && rm -rf /var/cache/apk/*

# Copy custom scripts
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

# Healthcheck marker (updated by backup process)
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD test -f /tmp/.backup-healthy || exit 1
