#!/usr/bin/env bash
# Apply the T-05/T-07/T-08/T-09 roles to the fixture: --check --diff first, then
# the real run, then a second run for idempotence. Logs go to $RES_DIR.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
TAGS=security,firewall,podman,caddy,semaphore

echo ">> placing a stand-in migrated database (empty sqlite, 1001:0 0644 like the Pi's)"
gs 'install -d /opt/podman/semaphore/data
    [ -f /opt/podman/semaphore/data/database.sqlite ] || sqlite3 /opt/podman/semaphore/data/database.sqlite "CREATE TABLE fixture_marker (id integer);"
    chown 1001:0 /opt/podman/semaphore/data/database.sqlite; chmod 0644 /opt/podman/semaphore/data/database.sqlite'

# SKIP_CHECK=1 skips the first --check (use it when re-running after a fix).
if [ -z "${SKIP_CHECK:-}" ]; then
  echo ">> --check --diff (fresh host)"
  ans ansible-playbook site.yml --tags "$TAGS" --check --diff "$@" </dev/null >"$RES_DIR/apply-check.log" 2>&1
  rec APPLY-CHECK INFO "rc=$? ($(grep -E '^(ops-vm-fixture)' "$RES_DIR/apply-check.log" | tail -1 | tr -s ' '))"
fi

echo ">> real run"
ans ansible-playbook site.yml --tags "$TAGS" "$@" </dev/null >"$RES_DIR/apply-1.log" 2>&1
rc1=$?
rec APPLY-1 INFO "rc=$rc1 $(grep -E '^ops-vm-fixture ' "$RES_DIR/apply-1.log" | tail -1 | tr -s ' ')"
[ "$rc1" -eq 0 ] || { grep -nE 'fatal|FAILED' "$RES_DIR/apply-1.log" | head; exit "$rc1"; }
echo ">> second run (idempotence)"
ans ansible-playbook site.yml --tags "$TAGS" "$@" </dev/null >"$RES_DIR/apply-2.log" 2>&1
rc2=$?
rec APPLY-2 INFO "rc=$rc2 $(grep -E '^ops-vm-fixture ' "$RES_DIR/apply-2.log" | tail -1 | tr -s ' ')"
