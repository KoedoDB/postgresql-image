# PostgreSQL image

The official `postgres` image (PostgreSQL 18.6 on Debian trixie) with a few tools and extensions added. Nothing in PostgreSQL itself is patched.

The base image is pinned by tag and digest. Update both together.

## What is added

| Component | Version | Source |
|---|---|---|
| pgBackRest | 2.59.2 | PGDG apt repository |
| age | 1.2.1 | Debian apt repository |
| rclone | 1.75.1 | Official release binary, verified with SHA256 (amd64 and arm64) |

The Debian `rclone` package is too old, so the official binary is used instead.

## Extensions

`pgvector`, `pgtap`, `plpgsql_check`, `hypopg`, `rum`, `pg_partman`, `pg_repack`, `postgis` and `pg_cron`, installed from the PGDG packages. The standard contrib extensions (`pgcrypto`, `uuid-ossp`, `pg_trgm`, ...) are available as well.

All of them except `pg_cron` are marked `trusted = true` in their `.control` files, so a non-superuser who owns the database can run `CREATE EXTENSION`. Upstream does not mark them as trusted. The build only appends that one line to the packaged `.control` file and does not modify any code. Because this lets non-superusers install C extensions, extensions are added one at a time, after checking that a non-superuser can create them.

### pg_cron

`pg_cron` is preloaded (`shared_preload_libraries`) and runs jobs with background workers (`cron.use_background_workers = on`). It runs jobs only in one database, set with the `CRON_DATABASE` build argument (default `postgres`).

It is not trusted. A superuser creates the extension and grants access to the roles that need it:

```sql
CREATE EXTENSION pg_cron;
GRANT USAGE ON SCHEMA cron TO app;
```

With only this grant, `app` can schedule and see its own jobs, and jobs run with the privileges of the role that scheduled them.

### PostGIS

Only `postgis` is marked trusted. The other PostGIS extensions (`postgis_topology`, `postgis_raster`, ...) need a superuser. `spatial_ref_sys` is owned by the extension, so a non-superuser cannot restore its data: dump with `--exclude-table-data=<schema>.spatial_ref_sys`.

## Build

```sh
docker build --build-arg CRON_DATABASE=mydb -t my-postgres .
```

| Build argument | Default | Meaning |
|---|---|---|
| `CRON_DATABASE` | `postgres` | Database where `pg_cron` runs jobs |
| `IMAGE_VERSION` | `18.6.1` | Value of the `org.opencontainers.image.version` label |
| `TRUSTED_EXTENSIONS` | see `Dockerfile` | Extensions that get `trusted = true` |

## Versioning

`IMAGE_VERSION` is `<PostgreSQL version>.<revision>`. The revision goes up when only this `Dockerfile` changes.

## Runtime

Configuration is the same as the official image: `POSTGRES_USER`, `POSTGRES_PASSWORD` and `POSTGRES_DB` apply only when the data directory is empty. See the [official image documentation](https://hub.docker.com/_/postgres).
