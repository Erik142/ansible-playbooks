#!/bin/sh
# Runs INSIDE the disposable openSUSE container (see behaviour.sh). Executes the
# rendered backup script against a LOCAL throwaway restic repository and asserts
# on the resulting snapshot. Input at /work: restic-backup.sh (default render),
# restic-backup-wide.sh (render that also backs up /opt/podman).
set -eu

pass=0
ok() { pass=$((pass + 1)); printf 'ok: %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

zypper -n -q install --no-recommends restic sqlite3 python3 jq curl >/dev/null

export HOME=/root RESTIC_REPOSITORY=/work/repo RESTIC_PASSWORD=throwaway-test-pw
db=/opt/podman/semaphore/data/database.sqlite
mkdir -p /opt/podman/semaphore/data /opt/podman/zerotier /var/lib/restic-backup/staging
chmod 0700 /var/lib/restic-backup/staging

# Live Semaphore stand-in: WAL mode, auto-checkpoint off, connection held open,
# so 100 committed rows exist ONLY in the -wal file while the script runs.
python3 - "$db" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("pragma journal_mode=wal")
c.execute("pragma wal_autocheckpoint=0")
c.execute("create table t(x integer)")
c.executemany("insert into t values (?)", [(i,) for i in range(100)])
c.commit()
time.sleep(120)
PY
holder=$!
n=0
while [ ! -s "$db-wal" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -s "$db-wal" ] || die "test setup: no -wal content"
[ "$(wc -c <"$db")" -lt 8192 ] || die "test setup: rows already in main file"

# Why .backup: a plain copy of the main file does not contain the rows.
cp "$db" /work/plain-copy.sqlite
plain=$(sqlite3 /work/plain-copy.sqlite "select count(*) from t" 2>/dev/null || echo 0)
[ "$plain" != "100" ] || die "test setup is not discriminating: plain copy has all rows"
ok "plain cp of the WAL database misses rows (got $plain of 100): the test discriminates"

# Secrets that must never reach a snapshot.
printf '{"secret":"x"}\n' >/opt/podman/semaphore/config.json
printf 'A=1\n' >/opt/podman/semaphore/semaphore.env
printf 'B=1\n' >/var/lib/restic-backup/restic-backup.env
printf 'zt\n' >/opt/podman/zerotier/identity.secret
printf 'keep\n' >/opt/podman/zerotier/harmless.txt

# --- default render: only the staging directory is backed up
sh /work/restic-backup.sh >/work/run1.log 2>&1 || { cat /work/run1.log; die "default run failed"; }
ok "default run exits 0"
files=$(restic ls latest)
printf '%s\n' "$files" | grep -qx '/var/lib/restic-backup/staging/semaphore.sqlite' || die "no consistent copy in snapshot: $files"
ok "snapshot contains the consistent database copy"
for bad in config.json semaphore.env restic-backup.env identity.secret -wal -shm .partial harmless.txt; do
    if printf '%s\n' "$files" | grep -q -- "$bad"; then die "snapshot contains $bad: $files"; fi
done
ok "default snapshot holds no config.json, *.env, identity.secret, wal/shm or live Podman files"

rm -rf /work/restore && restic restore latest --target /work/restore >/dev/null
copy=/work/restore/var/lib/restic-backup/staging/semaphore.sqlite
rows=$(sqlite3 "$copy" "select count(*) from t")
[ "$rows" = "100" ] || die "restored copy has $rows rows, expected 100 (WAL rows lost)"
[ "$(sqlite3 "$copy" 'pragma integrity_check')" = ok ] || die "restored copy fails integrity_check"
ok "restored copy has all 100 WAL-only rows and passes integrity_check"
mode=$(stat -c %a /var/lib/restic-backup/staging/semaphore.sqlite)
[ "$mode" = 600 ] || die "staged copy mode is $mode, expected 600"
ok "staged copy is mode 0600"
[ ! -e /var/lib/restic-backup/staging/semaphore.sqlite.partial ] || die ".partial file left behind"
[ ! -e "$db-wal.bak" ] && ok "no partial file left in staging"
sd="$(dirname "$db")"
if ls "$sd" | grep -q 'restic'; then die "script wrote into the source directory"; fi

# --- excludes work as a second layer when someone adds /opt/podman to the paths
sh /work/restic-backup-wide.sh >/work/run2.log 2>&1 || { cat /work/run2.log; die "wide run failed"; }
files=$(restic ls latest)
printf '%s\n' "$files" | grep -q 'harmless.txt' || die "wide render did not back up /opt/podman (test would prove nothing)"
for bad in config.json semaphore.env restic-backup.env identity.secret -wal -shm; do
    if printf '%s\n' "$files" | grep -q -- "$bad"; then die "wide snapshot contains $bad: $files"; fi
done
ok "with /opt/podman added, the exclude patterns still keep config.json, *.env, identity.secret, wal/shm out"

# --- the script's only repository operations are backup, check, snapshots, init
if grep -E 'restic (forget|prune)' /work/restic-backup.sh; then die "forget/prune in script"; fi
ok "script has no forget/prune"

# --- missing database fails the run and creates no new snapshot
before=$(restic snapshots --json | jq length)
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
rm -f "$db" "$db-wal" "$db-shm"
if sh /work/restic-backup.sh >/work/run3.log 2>&1; then die "run with missing database exited 0"; fi
grep -q "SQLite database $db is missing" /work/run3.log || { cat /work/run3.log; die "missing-database message absent"; }
after=$(restic snapshots --json | jq length)
[ "$before" = "$after" ] || die "snapshot count changed ($before -> $after) on a failed run"
ok "missing database: non-zero exit, named in the message, no new snapshot"

printf 'container-run: %s checks passed\n' "$pass"
