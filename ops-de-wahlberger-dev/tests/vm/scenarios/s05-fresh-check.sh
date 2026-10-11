#!/usr/bin/env bash
# Fresh-host rehearsal of the WHOLE role set on the 'bare' snapshot (see
# make-bare.sh): --check --diff, real apply, second and third apply.
# Expected: check rc=0 failed=0; apply failed=0; second changed<=1; third 0.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ARGS=(site.yml --skip-tags cloudflare_dns -e zerotier_network_id=deadbeefdeadbeef)

"$SCN_DIR/../reset.sh" bare || exit 1
gs 'install -d /opt/podman/semaphore/data
    [ -f /opt/podman/semaphore/data/database.sqlite ] || sqlite3 /opt/podman/semaphore/data/database.sqlite "CREATE TABLE fixture_marker (id integer);"
    chown 1001:0 /opt/podman/semaphore/data/database.sqlite; chmod 0644 /opt/podman/semaphore/data/database.sqlite'

run() { # run <id> <extra args...>
  local id="$1"; shift
  ans ansible-playbook "${ARGS[@]}" "$@" </dev/null >"$RES_DIR/fresh-$id.log" 2>&1
  local rc=$?
  rec "FRESH-$id" INFO "rc=$rc $(grep -E '^ops-vm-fixture ' "$RES_DIR/fresh-$id.log" | tail -1 | tr -s ' ')"
  [ "$rc" -eq 0 ] || { grep -nE 'fatal|FAILED' "$RES_DIR/fresh-$id.log" | head; exit "$rc"; }
}
run check --check --diff
run apply1
run apply2
run apply3
