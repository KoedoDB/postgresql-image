# Pinned by digest for reproducible builds. Update the tag and digest together.
FROM postgres:18.6-trixie@sha256:5a5a84b19854a9ffaa54082c166ff4ec27473a361e496e5ea167f298f2da9722

ARG RC_VERSION=1.75.1
ARG RC_SHA256_AMD64=982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab
ARG RC_SHA256_ARM64=03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9
# Version of this image: <PostgreSQL version>.<revision>. Bump the revision when only this Dockerfile changes.
ARG IMAGE_VERSION=18.6.1
ARG TARGETARCH
# pg_cron runs jobs only in this database. Override with --build-arg CRON_DATABASE=<name>.
ARG CRON_DATABASE=postgres
ARG TRUSTED_EXTENSIONS="vector pgtap plpgsql_check hypopg rum pg_partman pg_repack postgis"

# pgbackrest: from PGDG (already configured in the official image). age: from Debian.
# Extensions: install only verified ones and add trusted = true to their .control files.
# Upstream does not mark these as trusted. We only append one metadata line to the packaged .control; no code is modified.
# This lets non-superusers install C extensions, which widens the attack surface, so add them one at a time after verifying.
# pg_cron: not trusted; a superuser must run CREATE EXTENSION and grant USAGE on schema cron to the roles that need it.
# rclone: the Debian package is old (1.60), so install the official binary with checksum verification.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip \
      pgbackrest age \
      postgresql-18-pgvector postgresql-18-pgtap postgresql-18-plpgsql-check \
      postgresql-18-hypopg postgresql-18-rum postgresql-18-partman postgresql-18-repack \
      postgresql-18-cron postgresql-18-postgis-3; \
    case "${TARGETARCH:-amd64}" in \
      amd64) sha="${RC_SHA256_AMD64}" ;; \
      arm64) sha="${RC_SHA256_ARM64}" ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o /tmp/rclone.zip "https://github.com/rclone/rclone/releases/download/v${RC_VERSION}/rclone-v${RC_VERSION}-linux-${TARGETARCH:-amd64}.zip"; \
    echo "${sha}  /tmp/rclone.zip" | sha256sum -c -; \
    unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/rclone; \
    rm -f /tmp/rclone.zip; \
    apt-get purge -y --auto-remove curl unzip; \
    rm -rf /var/lib/apt/lists/*; \
    for ext in $TRUSTED_EXTENSIONS; do \
      f="/usr/share/postgresql/18/extension/${ext}.control"; \
      test -f "$f"; \
      grep -q '^trusted' "$f" || echo 'trusted = true' >> "$f"; \
    done; \
    printf '%s\n' \
      "shared_preload_libraries = 'pg_cron'" \
      "cron.database_name = '${CRON_DATABASE}'" \
      "cron.use_background_workers = on" \
      >> /usr/share/postgresql/postgresql.conf.sample; \
    pgbackrest version; age --version; rclone version

LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
