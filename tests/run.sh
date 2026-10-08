#!/usr/bin/env bash
# Builds the image and checks it end to end. No secrets are used: the password is
# throwaway, age keys are generated inside the container, and rclone writes to a local directory.
#
# Usage: tests/run.sh            # build, then test
#        SKIP_BUILD=1 tests/run.sh   # test an existing image (IMAGE)
set -u

cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-postgres-test:local}"
NAME="pgtest-$$"
ADMIN=admin
DB=testdb
APPDB=appdb
CRON_WAIT="${CRON_WAIT:-100}"

pass=0
fail=0

ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

# psql as the superuser / as the unprivileged database owner. $1 = database, $2 = SQL.
admin_sql() { docker exec "$NAME" psql -U "$ADMIN" -d "$1" -qAt -v ON_ERROR_STOP=1 -c "$2" 2>&1; }
app_sql()   { docker exec "$NAME" psql -U app -d "$1" -qAt -v ON_ERROR_STOP=1 -c "$2" 2>&1; }
in_box()    { docker exec "$NAME" sh -c "$1" 2>&1; }

# expect_ok <description> <output> / expect_err <description> <output> <substring>
expect_ok() {
  if echo "$2" | grep -q -E '^(ERROR|psql:|FATAL|pg_restore: error|pg_dump: error)'; then bad "$1" "$2"; else ok "$1"; fi
}
expect_err() {
  if echo "$2" | grep -q -F -- "$3"; then ok "$1"; else bad "$1" "expected '$3', got: $2"; fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got: $2"; fi
}

# --- build and start -------------------------------------------------------------------
if [ -z "${SKIP_BUILD:-}" ]; then
  echo "== build"
  docker build -q --build-arg CRON_DATABASE="$DB" -t "$IMAGE" . >/dev/null || { echo "build failed"; exit 1; }
fi

echo "== start"
docker run -d --name "$NAME" -e POSTGRES_USER="$ADMIN" -e POSTGRES_PASSWORD=throwaway \
  -e POSTGRES_DB="$DB" "$IMAGE" >/dev/null || { echo "start failed"; exit 1; }

for _ in $(seq 1 60); do
  # The entrypoint starts a temporary server first; wait for the real one.
  if docker exec "$NAME" pg_isready -U "$ADMIN" -d "$DB" >/dev/null 2>&1 \
     && docker logs "$NAME" 2>&1 | grep -q 'ready to accept connections' \
     && docker logs "$NAME" 2>&1 | grep -q 'PostgreSQL init process complete'; then
    break
  fi
  sleep 1
done
sleep 2

# --- 1. versions and tools -------------------------------------------------------------
echo "== tools"
expect_eq "PostgreSQL is 18.6" "$(in_box 'postgres --version' | grep -o '18\.6' | head -1)" "18.6"
expect_ok "pgbackrest runs" "$(in_box 'pgbackrest version')"
expect_ok "age runs" "$(in_box 'age --version')"
expect_ok "age-keygen runs" "$(in_box 'age-keygen --version')"
expect_ok "rclone runs" "$(in_box 'rclone version')"
expect_eq "image version label is set" \
  "$(docker inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' | grep -c .)" "1"

# --- 2. extensions as a non-superuser --------------------------------------------------
echo "== extensions"
out=$(admin_sql "$DB" "create role app login; create role other login; alter database $DB owner to app; create schema extensions authorization app;")
expect_ok "set up an unprivileged database owner" "$out"
expect_eq "app is not a superuser" "$(app_sql "$DB" "select rolsuper from pg_roles where rolname = current_user")" "f"

for ext in vector pgtap plpgsql_check hypopg rum pg_partman pg_repack; do
  out=$(app_sql "$DB" "create extension if not exists $ext with schema extensions")
  expect_ok "non-superuser can create $ext" "$out"
done

# An untrusted extension must still be refused (pg_stat_statements is not trusted).
out=$(app_sql "$DB" "create extension pg_stat_statements")
expect_err "non-superuser cannot create an untrusted extension" "$out" "permission denied"

# --- 3. pg_cron ------------------------------------------------------------------------
echo "== pg_cron"
expect_eq "pg_cron is preloaded" "$(admin_sql "$DB" 'show shared_preload_libraries')" "pg_cron"
expect_eq "pg_cron database is $DB" "$(admin_sql "$DB" 'show cron.database_name')" "$DB"

out=$(app_sql "$DB" "create extension pg_cron")
expect_err "non-superuser cannot create pg_cron (not trusted)" "$out" "permission denied"
# A superuser creates it: objects of an extension created by a non-superuser end up owned by
# the bootstrap superuser anyway, and the job table is then not usable by that role.
out=$(admin_sql "$DB" "create extension if not exists pg_cron")
expect_ok "superuser can create pg_cron" "$out"
out=$(app_sql "$DB" "select cron.schedule('nogrant', '* * * * *', 'select 1')")
expect_err "no access to the cron schema without a grant" "$out" "permission denied for schema cron"

admin_sql "$DB" "grant usage on schema cron to app" >/dev/null
out=$(app_sql "$DB" "select cron.schedule('ok-job', '* * * * *', 'select 1')")
expect_ok "app can schedule a job after the grant" "$out"
out=$(app_sql "$DB" "select cron.schedule('evil-job', '* * * * *', 'create role evil superuser')")
expect_ok "app can schedule a job that tries to create a superuser" "$out"
expect_eq "jobs are owned by app" "$(app_sql "$DB" "select string_agg(distinct username, ',') from cron.job")" "app"

out=$(app_sql "$DB" "select cron.schedule_in_database('x', '* * * * *', 'select 1', 'postgres')")
expect_err "schedule_in_database is not allowed" "$out" "permission denied for function"
out=$(app_sql "$DB" "update cron.job set username = '$ADMIN'")
expect_err "cannot rewrite the job owner" "$out" "permission denied for table job"
out=$(docker exec "$NAME" psql -U other -d "$DB" -qAt -c "select * from cron.job" 2>&1)
expect_err "a role without the grant cannot use cron" "$out" "permission denied for schema cron"

echo "   (waiting up to ${CRON_WAIT}s for the jobs to run)"
for _ in $(seq 1 "$CRON_WAIT"); do
  n=$(app_sql "$DB" "select count(*) from cron.job_run_details where status in ('succeeded','failed')")
  [ "$n" -ge 2 ] 2>/dev/null && break
  sleep 1
done
expect_eq "a plain job succeeds" \
  "$(app_sql "$DB" "select d.status from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'ok-job' limit 1")" "succeeded"
expect_eq "a job cannot exceed the privileges of its owner" \
  "$(app_sql "$DB" "select d.status from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'evil-job' limit 1")" "failed"
expect_eq "no superuser was created by a job" "$(admin_sql "$DB" "select count(*) from pg_roles where rolname = 'evil'")" "0"

# --- 4. pgvector -----------------------------------------------------------------------
echo "== pgvector"
# A separate database without pg_cron: pg_cron can only exist in cron.database_name, so a dump
# of that database cannot be restored into another one.
admin_sql postgres "create database $APPDB owner app" >/dev/null
out=$(app_sql "$APPDB" "create schema extensions; create extension vector with schema extensions")
expect_ok "create vector in a separate database" "$out"
out=$(app_sql "$APPDB" "
  set search_path = public, extensions;
  create table items (id int primary key, embedding vector(3));
  insert into items select g, array[g, g % 7, g % 3]::real[]::vector from generate_series(1, 200) g;")
expect_ok "create a vector table and load rows" "$out"
expect_eq "L2 nearest neighbour" "$(app_sql "$APPDB" "set search_path = public, extensions; select id from items order by embedding <-> '[1,1,1]' limit 1" | tail -1)" "1"
expect_ok "cosine distance works" "$(app_sql "$APPDB" "set search_path = public, extensions; select embedding <=> '[1,2,3]' from items limit 1")"
expect_ok "inner product works" "$(app_sql "$APPDB" "set search_path = public, extensions; select embedding <#> '[1,2,3]' from items limit 1")"
expect_ok "HNSW index" "$(app_sql "$APPDB" "set search_path = public, extensions; create index on items using hnsw (embedding vector_l2_ops)")"
expect_ok "IVFFlat index" "$(app_sql "$APPDB" "set search_path = public, extensions; create index on items using ivfflat (embedding vector_cosine_ops) with (lists = 4)")"

echo "== postgis"
out=$(app_sql "$APPDB" "create extension if not exists postgis with schema extensions")
expect_ok "non-superuser can create postgis" "$out"
out=$(app_sql "$APPDB" "set search_path = public, extensions;
  create table places (id int primary key, geom geometry(Point, 4326));
  insert into places values (1, ST_SetSRID(ST_MakePoint(139.69, 35.69), 4326)), (2, ST_SetSRID(ST_MakePoint(135.50, 34.69), 4326));
  create index on places using gist (geom)")
expect_ok "create a geometry table with a GiST index" "$out"
expect_eq "nearest place (KNN)" "$(app_sql "$APPDB" "set search_path = public, extensions; select id from places order by geom <-> ST_SetSRID(ST_MakePoint(139, 35), 4326) limit 1" | tail -1)" "1"
expect_eq "geography distance, Tokyo to Osaka (km)" "$(app_sql "$APPDB" "set search_path = public, extensions; select round(ST_Distance(a.geom::geography, b.geom::geography) / 1000) from places a, places b where a.id = 1 and b.id = 2" | tail -1)" "397"

# --- 5. dump and restore ---------------------------------------------------------------
echo "== pg_dump and restore"
count_src=$(app_sql "$APPDB" "select count(*) from items")
nn_src=$(app_sql "$APPDB" "set search_path = public, extensions; select id from items order by embedding <-> '[5,5,2]' limit 1" | tail -1)

in_box "pg_dump -U app -d $APPDB -Fc --no-owner --exclude-table-data=extensions.spatial_ref_sys -f /tmp/db.dump" >/dev/null
admin_sql postgres "create database restored owner app" >/dev/null
out=$(in_box "pg_restore -U app -d restored --no-owner /tmp/db.dump")
expect_ok "pg_restore as a non-superuser" "$out"
expect_eq "row count is preserved" "$(app_sql restored "select count(*) from items")" "$count_src"
expect_eq "postgis rows are preserved" "$(app_sql restored "select count(*) from places")" "2"
expect_eq "vector search gives the same answer after restore" \
  "$(app_sql restored "set search_path = public, extensions; select id from items order by embedding <-> '[5,5,2]' limit 1" | tail -1)" "$nn_src"

admin_sql postgres "create database fromsql owner app" >/dev/null
out=$(docker exec "$NAME" psql -U app -d fromsql -qAt -v ON_ERROR_STOP=1 \
  -c "create schema if not exists extensions" \
  -c "create extension if not exists vector with schema extensions" 2>&1)
expect_ok "a dump-style 'create extension if not exists vector with schema extensions' works" "$out"

# --- 6. dump | age | rclone ------------------------------------------------------------
echo "== backup pipeline"
in_box "age-keygen -o /tmp/key.txt 2>/tmp/pub.txt; mkdir -p /tmp/remote" >/dev/null
pub=$(in_box "sed -n 's/^Public key: //p' /tmp/pub.txt")
[ -n "$pub" ] && ok "age key pair generated" || bad "age key pair generated"

out=$(in_box "pg_dump -U app -d $APPDB -Fc --no-owner --exclude-table-data=extensions.spatial_ref_sys | age -r '$pub' | rclone rcat :local:/tmp/remote/dump.age")
expect_ok "pg_dump | age | rclone rcat" "$out"
expect_eq "the remote file exists and is not plain text" \
  "$(in_box "rclone cat :local:/tmp/remote/dump.age 2>/dev/null | head -c 21")" "age-encryption.org/v1"

admin_sql postgres "create database fromage owner app" >/dev/null
out=$(in_box "rclone cat :local:/tmp/remote/dump.age | age -d -i /tmp/key.txt | pg_restore -U app -d fromage --no-owner")
expect_ok "rclone cat | age -d | pg_restore" "$out"
expect_eq "decrypted restore has the same rows" "$(app_sql fromage "select count(*) from items")" "$count_src"

# --- 7. koedodb-reconcile-roles ----------------------------------------------------------
# The program of KoedoDB's Job that sets the passwords of a database's roles after its first start. The loopback and the socket are trusted by this image, so a password is only checked from
# another address: the container's own.
echo "== koedodb-reconcile-roles"
in_box "test -x /usr/local/bin/koedodb-reconcile-roles" >/dev/null && ok "the program is in the image and executable" || bad "the program is in the image and executable"
in_box "koedodb-reconcile-roles nothing" >/dev/null 2>&1; expect_eq "a mode it does not know is refused (status 2)" "$?" "2"
admin_sql postgres "create role supabase_auth_admin login password 'old-auth'; create role authenticator login password 'old-rest'; create role postgres login password 'old-customer'" >/dev/null
roles_job() {  # $1 = the three passwords, as environment settings
  docker exec -e PGUSER="$ADMIN" -e PGPASSWORD=throwaway -e PGDATABASE=postgres $1 "$NAME" sh -c 'PGHOST="$(hostname -i)" koedodb-reconcile-roles passwords' 2>&1
}
network_login() {  # $1 = role, $2 = password
  docker exec -e PGPASSWORD="$2" "$NAME" sh -c "psql -h \"\$(hostname -i)\" -U $1 -d postgres -tAc 'select 1'" 2>&1 | tail -1
}
out=$(roles_job "-e AUTH_DB_PASSWORD=new-auth-0123456789 -e REST_DB_PASSWORD=new-rest-0123456789 -e CUSTOMER_DB_PASSWORD=new-customer-0123456789")
expect_ok "the Job's program sets the passwords" "$out"
expect_eq "the customer's role has the new password" "$(network_login postgres new-customer-0123456789)" "1"
expect_eq "Auth's and PostgREST's roles have theirs" "$(network_login supabase_auth_admin new-auth-0123456789)$(network_login authenticator new-rest-0123456789)" "11"
network_login postgres old-customer | grep -q "authentication failed" && ok "the old password no longer works" || bad "the old password no longer works"
out=$(roles_job "-e AUTH_DB_PASSWORD= -e REST_DB_PASSWORD= -e CUSTOMER_DB_PASSWORD=")
expect_ok "empty passwords are skipped, not an error" "$out"
expect_eq "and change nothing" "$(network_login postgres new-customer-0123456789)" "1"

# --- result ----------------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
