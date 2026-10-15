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

`pgvector`, `pgtap`, `plpgsql_check`, `hypopg`, `rum`, `pg_partman`, `pg_repack`, `postgis` and `pg_cron`, installed from the PGDG packages, and `pg_net`, built from source (below). The standard contrib extensions (`pgcrypto`, `uuid-ossp`, `pg_trgm`, ...) are available as well.

All of them, `pg_cron` and `pg_net` included (since 2026-10-15), are marked `trusted = true` in their `.control` files, so a non-superuser who owns the database can run `CREATE EXTENSION`. Upstream does not mark them as trusted. The build only appends that one line to the packaged `.control` file and does not modify any code. Because this lets non-superusers install C extensions, extensions are added one at a time, after checking that a non-superuser can create them.

### pg_cron

`pg_cron` is preloaded (`shared_preload_libraries`) and runs jobs with background workers (`cron.use_background_workers = on`). It runs jobs only in one database, set with the `CRON_DATABASE` build argument (default `postgres`).

It is trusted (since 2026-10-15): the owner of the database can `CREATE EXTENSION pg_cron` from its own migration. A trusted extension's script runs as the bootstrap superuser, so the `cron` schema and its tables belong to the superuser, and the owner can use them only if the superuser has set **default privileges** for what it makes in this database (without them: `permission denied for schema cron`). KoedoDB's init script sets them:

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE <the superuser> GRANT USAGE ON SCHEMAS TO <the owner>;
ALTER DEFAULT PRIVILEGES FOR ROLE <the superuser> GRANT ALL ON TABLES TO <the owner>;
ALTER DEFAULT PRIVILEGES FOR ROLE <the superuser> GRANT ALL ON SEQUENCES TO <the owner>;
```

With these, the owner schedules and sees its own jobs, and jobs run with the privileges of the role that scheduled them. Checked (tests/run.sh): the owner cannot change `cron.job.username` or insert a job of the superuser (row level security), cannot use `schedule_in_database`, and a job that creates a superuser fails. Another role has no `USAGE` on the `cron` schema and cannot use cron; the owner cannot grant it (it does not own the schema).

### PostGIS

Only `postgis` is marked trusted. The other PostGIS extensions (`postgis_topology`, `postgis_raster`, ...) need a superuser. `spatial_ref_sys` is owned by the extension, so a non-superuser cannot restore its data: dump with `--exclude-table-data=<schema>.spatial_ref_sys`.

### pg_net

[`pg_net`](https://github.com/supabase/pg_net) (Apache-2.0) sends HTTP and HTTPS requests from SQL (`net.http_get`, `net.http_post`, `net.http_delete`), from a background worker, with libcurl; the answers are rows in `net._http_response`. PGDG has no package for it, so the image builds it from a release tarball whose SHA-256 is checked (`PG_NET_VERSION`, `PG_NET_SHA256` in the `Dockerfile`; the Makefile of v0.20.5 still reports extension version 0.20.4). It is preloaded, and its worker works in one database, set with the `NET_DATABASE` build argument (`pg_net.database_name`; the same idea as `CRON_DATABASE`).

It is trusted: the owner of the database runs `CREATE EXTENSION pg_net`. **Its script grants the schema, all its tables and all its sequences to `PUBLIC`**, so every role of the database could queue requests and read and change the others' queue and responses. These are the customer's own roles in the customer's own database. A superuser (or a customer with several login roles who wants it closed) takes that away right after `CREATE EXTENSION`, and grants only the roles that should send requests:

```sql
revoke all on schema net from public;
revoke all on all tables in schema net from public;
revoke all on all sequences in schema net from public;
revoke execute on all functions in schema net from public;
-- for a role that may send requests:
grant usage on schema net to app;
grant all on all tables in schema net to app;
grant all on all sequences in schema net to app;
grant execute on all functions in schema net to app;
```

The requests leave the Pod of the database: a role that can send them can reach whatever the Pod's network can. Keep the egress of the database's Pod to the addresses that should be reachable.

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

## Backups

The tools are there for two kinds of backup:

- **Logical dump**: `pg_dump` piped through `age` (public-key encryption) to `rclone`, so a dump is encrypted before it leaves the container and nothing is written to the container's disk.

  ```sh
  pg_dump -Fc --no-owner "$PGDATABASE" | age -r "$AGE_RECIPIENT" | rclone rcat "$DEST/dump-$(date -u +%Y%m%dT%H%M%SZ).age"
  ```

  Only the public key goes into the container. Restore with `rclone cat ... | age -d -i <key file> | pg_restore`.
- **Physical backup and point-in-time recovery**: pgBackRest. It needs WAL archiving, so `archive_mode`, `wal_level` and `archive_command` are not set in the image. Set them at start-up for a database that uses pgBackRest; an `archive_command` that keeps failing makes WAL pile up on the disk.

## Tests

```sh
tests/run.sh      # build the image and check it: tools, each extension as a non-superuser, pg_cron, dump | age | rclone and the restore
tests/backup.sh   # pgBackRest full backup, then point-in-time recovery to just before a mistake (needs the image from run.sh)
```

Both need Docker only. No secrets are used: passwords are throwaway, age keys are made inside the container, and the backups go to a local directory. GitHub Actions runs them on every push and every Monday, to catch breakage from base image or package repository updates.

## Updating

- **PostgreSQL / base image**: change the tag and the digest of `FROM` together, then `IMAGE_VERSION` (`<PostgreSQL version>.<revision>`).
- **rclone**: change `RC_VERSION` and both `RC_SHA256_*` values (from the release's `SHA256SUMS`), and the version in the table above.
- Run `tests/run.sh` and `tests/backup.sh` before publishing a new image.

## License

The files in this repository (the `Dockerfile`, the tests and the documentation) are under the [PostgreSQL License](LICENSE).

The image built from them contains other software, each under its own license: PostgreSQL, pgBackRest, age, rclone and the extensions. PostGIS, for example, is GPL-2.0-or-later. The license above does not change theirs.
