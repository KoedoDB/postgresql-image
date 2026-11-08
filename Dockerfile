# The PostgreSQL major version, and the base image of that major (the official image, pinned by digest: update the tag and the digest together, and both stages use it). A build of another
# major is `--build-arg PG_MAJOR=19 --build-arg BASE_IMAGE=postgres:19.1-trixie@sha256:...`; the extension packages of that major have to exist (PGDG), and the others in the list are checked
# by tests/run.sh. IMAGE_VERSION is `<PostgreSQL version>.<revision>` and is given with the build.
ARG PG_MAJOR=18
ARG BASE_IMAGE=postgres:18.6-trixie@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6
# pg_net (Supabase, Apache-2.0) is built from source here, from a release tarball checked against its SHA-256: the PGDG packages do not have it. Only its .so and extension files go on to the image below.
# Update the base image of both stages together; update PG_NET_VERSION and PG_NET_SHA256 together (curl -sSL https://github.com/supabase/pg_net/archive/refs/tags/v<version>.tar.gz | sha256sum).
FROM ${BASE_IMAGE} AS pg_net_build
ARG PG_MAJOR
ARG PG_NET_VERSION=0.20.5
ARG PG_NET_SHA256=a0a2611ea6fbbc93ef553ff057d97d3a857136742cb50605058744bf57fe6c27
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl build-essential postgresql-server-dev-${PG_MAJOR} libcurl4-openssl-dev libicu-dev; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o /tmp/pg_net.tar.gz "https://github.com/supabase/pg_net/archive/refs/tags/v${PG_NET_VERSION}.tar.gz"; \
    echo "${PG_NET_SHA256}  /tmp/pg_net.tar.gz" | sha256sum -c -; \
    mkdir /tmp/pg_net; tar -xzf /tmp/pg_net.tar.gz -C /tmp/pg_net --strip-components=1; \
    make -C /tmp/pg_net with_llvm=no -j"$(nproc)"; \
    make -C /tmp/pg_net with_llvm=no install DESTDIR=/out

# Pinned by digest for reproducible builds (BASE_IMAGE above).
FROM ${BASE_IMAGE}
ARG PG_MAJOR

ARG RC_VERSION=1.75.2
ARG RC_SHA256_AMD64=349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702
ARG RC_SHA256_ARM64=7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10
# Version of this image: <PostgreSQL version>.<revision>. Bump the revision when only this Dockerfile changes.
ARG IMAGE_VERSION=18.6.7
ARG TARGETARCH
# pg_cron runs jobs only in this database. Override with --build-arg CRON_DATABASE=<name>.
ARG CRON_DATABASE=postgres
# pg_net sends its requests from a background worker that works in one database too. Override with --build-arg NET_DATABASE=<name>.
ARG NET_DATABASE=postgres
ARG TRUSTED_EXTENSIONS="vector pgtap plpgsql_check hypopg rum pg_partman pg_repack postgis pg_cron pg_net pg_stat_statements"

# pg_net: the files built above.
COPY --from=pg_net_build /out/ /

# pgbackrest: from PGDG (already configured in the official image). age and zstd: from Debian (zstd compresses the operator's pg_dumpall before it is encrypted).
# wal2json (Realtime's postgres_changes reads the WAL through it; the server also has to allow it in output_plugin_libraries, which the Regional Agent sets).
# Extensions: install only verified ones and add trusted = true to their .control files.
# Upstream does not mark these as trusted. We only append one metadata line to the packaged .control; no code is modified.
# This lets non-superusers install C extensions, which widens the attack surface, so add them one at a time after verifying.
# pg_cron and pg_net are trusted too (2026-10-15), so that the database's owner can CREATE EXTENSION from its own migration. Created that way, their schemas and tables belong to the bootstrap superuser, so the owner can use
# them only with default privileges from the superuser (KoedoDB's init script sets them: dbinit.go of KoedoDB); without them the owner gets "permission denied for schema cron".
# rclone: the Debian package is old (1.60), so install the official binary with checksum verification.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip \
      pgbackrest age zstd \
      postgresql-${PG_MAJOR}-pgvector postgresql-${PG_MAJOR}-pgtap postgresql-${PG_MAJOR}-plpgsql-check \
      postgresql-${PG_MAJOR}-hypopg postgresql-${PG_MAJOR}-rum postgresql-${PG_MAJOR}-partman postgresql-${PG_MAJOR}-repack \
      postgresql-${PG_MAJOR}-cron postgresql-${PG_MAJOR}-postgis-3 postgresql-${PG_MAJOR}-wal2json libcurl4t64; \
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
      f="/usr/share/postgresql/${PG_MAJOR}/extension/${ext}.control"; \
      test -f "$f"; \
      grep -q '^trusted' "$f" || echo 'trusted = true' >> "$f"; \
    done; \
    printf '%s\n' \
      "shared_preload_libraries = 'pg_cron,pg_net,pg_stat_statements,auto_explain'" \
      "cron.database_name = '${CRON_DATABASE}'" \
      "cron.use_background_workers = on" \
      "pg_net.database_name = '${NET_DATABASE}'" \
      >> /usr/share/postgresql/postgresql.conf.sample; \
    pgbackrest version; age --version; zstd --version; rclone version

# The program of KoedoDB's Job that sets the passwords of a database's roles after its first start (doc/POSTGRESQL.md of KoedoDB). It is part of the image so that what the Job does is what this file says.
COPY --chmod=0755 koedodb-reconcile-roles /usr/local/bin/koedodb-reconcile-roles
# The entrypoint: the official one, and a restore from the pgBackRest repository first when KOEDODB_RESTORE is set and the data directory is new (recovery of a Host's Projects).
COPY --chmod=0755 koedodb-entrypoint /usr/local/bin/koedodb-entrypoint
ENTRYPOINT ["koedodb-entrypoint"]
# Setting ENTRYPOINT clears the CMD of the base image: put it back.
CMD ["postgres"]

LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
