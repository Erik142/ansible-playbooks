#!/usr/bin/env bash
# VM run V2 for the Garage feature (T-17): test setup, routing (web and API route through a
# route test Caddy), unsigned writes refused, invalid caddy_sites refused, user-owned state
# untouched by a later role run. VM only (tests/vm/ans.sh refuses any other target).
#   FIXTURE_VM_DIR=~/.cache/nas-fixture-vm-garage tests/vm/scenarios/garage-v2-run.sh
# Needs the VM running after `reset.sh clean`. Appends PASS/FAIL lines to $FIXTURE_VM_DIR/results.tsv.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
L="$OUT/garage-v2"; mkdir -p "$L"
changed_of() { sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$1" | tail -1; }
putg() { vm_ssh "sudo -n tee $2 >/dev/null" <"$1"; }

# ---- role run (fresh host) and the user-step test setup ----
play site.yml --tags garage >"$L/role1.log" 2>&1; rc=$?
check GS-AC-22/role-run "role run on a fresh host rc=$rc changed=$(changed_of "$L/role1.log")" test $rc -eq 0
"$SCEN_DIR/garage-test-setup.sh" >"$L/setup.log" 2>&1 || { tail -5 "$L/setup.log"; exit 1; }

# ---- GS-AC-70 host half: nothing in the inventory or the role variables defines buckets, keys, grants ----
check GS-AC-70/static "no bucket, key or grant in inventories/vm or role variables" \
  bash -c "! grep -rhvE '^[[:space:]]*#' '$NAS_DIR/inventories/vm' --include=*.yml --include=*.yaml | grep -iE 'bucket|grant|garage_keys|key create' && ! grep -vE '^[[:space:]]*#' '$NAS_DIR/roles/garage/defaults/main.yml' | grep -iE 'bucket|grant|garage_keys'"

# ---- Caddyfile of the route test Caddy: http://:8080 { <S3 host body from production vars> } ----
body=$(cd "$NAS_DIR" && ./tests/vm/ans.sh ansible nas-vm-fixture -m ansible.builtin.debug -a 'var=garage_s3_caddy_body' </dev/null 2>/dev/null |
  python3 -I -c 'import sys,json; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["garage_s3_caddy_body"],end="")')
{ printf 'http://:8080 {\n'; sed 's/^/\t/' <<<"$body"; printf '}\n'; } >"$L/Caddyfile"
putg "$L/Caddyfile" /var/tmp/garage-v2-Caddyfile
putg "$SCEN_DIR/garage-v2-guest.sh" /var/tmp/garage-v2-guest.sh
putg "$SCEN_DIR/garage-v2-state.sh" /var/tmp/garage-v2-state.sh

# ---- guest checks ----
gs 'bash /var/tmp/garage-v2-guest.sh' >"$L/guest.out" 2>&1
grep -E '^(---|R )' "$L/guest.out" | grep -vE '^R ' || true
while read -r _ id res ev; do
  if [[ $res == SKIPPED ]]; then record "$id" SKIPPED "$ev"; else record "$id" "$res" "$ev"; fi
done < <(grep '^R ' "$L/guest.out")
grep -c '^R ' "$L/guest.out" | sed 's/^/guest checks run: /'

# ---- GS-AC-58: invalid caddy_sites entries refused by the real role, deployed Caddyfile unchanged ----
gs 'mkdir -p /mnt/containers/caddy && printf "marker\n" >/mnt/containers/caddy/Caddyfile && sha256sum /mnt/containers/caddy/Caddyfile' >"$L/cf.before"
i=0
for e in '{"host":"a.example.test","body":"respond 200","upstream":"x:1"}' \
         '{"host":"a.example.test","body":"respond 200","extra":"encode gzip"}' \
         '{"host":"a.example.test"}'; do
  i=$((i + 1))
  play site.yml --tags caddy -e "{\"caddy_sites\":[$e]}" >"$L/ac58-$i.log" 2>&1; rc=$?
  gs 'sha256sum /mnt/containers/caddy/Caddyfile' >"$L/cf.after"
  check "GS-AC-58/$i" "rc=$rc, names a.example.test, Caddyfile hash unchanged" \
    bash -c "[ $rc -ne 0 ] && grep -q 'a.example.test' '$L/ac58-$i.log' && cmp -s '$L/cf.before' '$L/cf.after'"
done
gs 'rm -f /mnt/containers/caddy/Caddyfile; rmdir /mnt/containers/caddy 2>/dev/null; true'

# ---- GS-AC-73: user-owned state untouched by a later role run ----
gs 'bash /var/tmp/garage-v2-state.sh set' >"$L/state-set.log" 2>&1; echo "user state set rc=$?"
gs 'rm -rf /var/tmp/g73; bash /var/tmp/garage-v2-state.sh save /var/tmp/g73/before' >>"$L/state-set.log" 2>&1
play site.yml --tags garage >"$L/role2.log" 2>&1; rc=$?
gs 'bash /var/tmp/garage-v2-state.sh save /var/tmp/g73/after' >>"$L/state-set.log" 2>&1
check GS-AC-73/changed "second role run rc=$rc changed=$(changed_of "$L/role2.log")" bash -c "[ $rc -eq 0 ] && [ \"$(changed_of "$L/role2.log")\" = 0 ]"
for f in layout sstate private-test key lifecycle; do
  # `key info` lists the key's buckets in a varying order between two calls (Garage, no role run in
  # between), so that one is compared as a set of lines.
  if [[ $f == key ]]; then cmpcmd="cmp <(sort /var/tmp/g73/before/$f) <(sort /var/tmp/g73/after/$f)"; else cmpcmd="cmp /var/tmp/g73/before/$f /var/tmp/g73/after/$f"; fi
  check "GS-AC-73/$f" "output identical before/after the role run" gs "$cmpcmd"
done
check GS-AC-73/rule-present "lifecycle rule and quota still the user's" \
  gs "grep -q expire-tmp /var/tmp/g73/after/lifecycle && grep -qE '10(\\.0)? MiB' /var/tmp/g73/after/private-test"
