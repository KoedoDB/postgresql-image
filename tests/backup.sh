#!/usr/bin/env bash
# Backup and point-in-time recovery with pgBackRest, using a local (posix) repository.
# No secrets: the password is throwaway and nothing leaves the machine.
#
# Usage: IMAGE=<image> tests/backup.sh   (the image must already be built; see tests/run.sh)
set -u

IMAGE="${IMAGE:-postgres-test:local}"
ID="$$"
NAME="pgbackup-$ID"
DATA_VOL="pgbackup-data-$ID"
REPO_VOL="pgbackup-repo-$ID"
PGDATA_DIR=/var/lib/postgresql/18/docker

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got: $2"; fi; }
expect_ok() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "exit status $2"; fi; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker volume rm "$DATA_VOL" "$REPO_VOL" >/dev/null 2>&1
}
trap cleanup EXIT

# pgBackRest reads its settings from the environment, so no config file is needed.
ENVS=(-e PGBACKREST_STANZA=main -e "PGBACKREST_PG1_PATH=$PGDATA_DIR" -e PGBACKREST_REPO1_PATH=/var/lib/pgbackrest)
VOLS=(-v "$DATA_VOL:/var/lib/postgresql" -v "$REPO_VOL:/var/lib/pgbackrest")
PGARGS=(-c wal_level=replica -c archive_mode=on -c "archive_command=pgbackrest archive-push %p")

start() {
  docker run -d --name "$NAME" -e POSTGRES_PASSWORD=throwaway "${ENVS[@]}" "${VOLS[@]}" "$IMAGE" "${PGARGS[@]}" >/dev/null || return 1
  for _ in $(seq 1 60); do
    docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1 \
      && ! docker logs "$NAME" 2>&1 | grep -q 'init process in progress' && break
    sleep 1
  done
  sleep 2
}
sql() { docker exec "$NAME" psql -U postgres -qAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
pgb() { docker exec -u postgres "$NAME" pgbackrest "$@" 2>&1; }

echo "== start with WAL archiving"
start || { echo "start failed"; exit 1; }
expect_eq "archive_mode is on" "$(sql 'show archive_mode')" "on"

echo "== stanza and full backup"
out=$(pgb stanza-create); rc=$?; expect_ok "stanza-create" $rc; [ $rc -ne 0 ] && echo "$out"
out=$(pgb check); rc=$?; expect_ok "pgbackrest check (archiving works)" $rc; [ $rc -ne 0 ] && echo "$out"

sql "create table t (id int primary key, note text)" >/dev/null
sql "insert into t select g, 'before-backup' from generate_series(1, 100) g" >/dev/null
out=$(pgb --type=full backup); rc=$?; expect_ok "full backup" $rc; [ $rc -ne 0 ] && echo "$out"
expect_eq "info lists one full backup" "$(pgb info --output=json | python3 -c 'import sys,json; b=json.load(sys.stdin)[0]["backup"]; print(len(b), b[0]["type"])')" "1 full"
out=$(pgb verify); rc=$?; expect_ok "verify the repository" $rc; [ $rc -ne 0 ] && echo "$out"

echo "== changes after the backup, then an accident"
sql "insert into t select g, 'after-backup' from generate_series(101, 200) g" >/dev/null
sleep 1
TARGET=$(sql "select to_char(clock_timestamp(), 'YYYY-MM-DD HH24:MI:SS.US') || '+00'")
echo "   recovery target: $TARGET"
sleep 1
sql "delete from t" >/dev/null
sql "create table made_after_target (x int)" >/dev/null
expect_eq "the accident happened (0 rows)" "$(sql 'select count(*) from t')" "0"
out=$(pgb check); rc=$?; expect_ok "WAL after the accident is archived" $rc; [ $rc -ne 0 ] && echo "$out"

echo "== restore to the point in time"
docker stop "$NAME" >/dev/null
docker rm "$NAME" >/dev/null
out=$(docker run --rm -u postgres --entrypoint pgbackrest "${ENVS[@]}" "${VOLS[@]}" "$IMAGE" \
  restore --delta --type=time "--target=$TARGET" --target-action=promote 2>&1)
rc=$?; expect_ok "pgbackrest restore (type=time)" $rc; [ $rc -ne 0 ] && echo "$out"

start || { echo "start after restore failed"; exit 1; }
for _ in $(seq 1 30); do
  [ "$(sql 'select pg_is_in_recovery()')" = "f" ] && break
  sleep 1
done
expect_eq "server is promoted" "$(sql 'select pg_is_in_recovery()')" "f"
expect_eq "rows from before the target are back" "$(sql 'select count(*) from t')" "200"
expect_eq "rows after the backup but before the target are present" "$(sql "select count(*) from t where note = 'after-backup'")" "100"
expect_eq "changes after the target are gone" "$(sql "select count(*) from pg_tables where tablename = 'made_after_target'")" "0"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
