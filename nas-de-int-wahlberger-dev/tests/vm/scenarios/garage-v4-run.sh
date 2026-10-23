#!/usr/bin/env bash
# VM run V4 for the Garage feature (T-19): secrets out of logs (GS-AC-23) and idempotency (GS-AC-12).
# VM only (tests/vm/ans.sh refuses any other target). Needs the V3 VM state (user-made buckets and keys).
#   FIXTURE_VM_DIR=~/.cache/nas-fixture-vm-garage tests/vm/scenarios/garage-v4-run.sh
# "Fresh store" = the role pointed at new, empty store/meta paths (the V3 store stays untouched on disk);
# "user-made state" = the default paths holding the V3 buckets and keys. Appends to $FIXTURE_VM_DIR/results.tsv.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
L="$OUT/garage-v4"; mkdir -p "$L"
changed_of() { sed -n 's/.*changed=\([0-9]*\).*/\1/p' "$1" | tail -1; }
RPC=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
TOK=fixture-garage-not-a-secret-0123456789
FRESH=(-e garage_store_path=/mnt/data/garage-v4 -e garage_config_dir=/mnt/containers/garage-v4)

# leak <logfile...>: number of fixture secret values found
leak() { cat "$@" | grep -c -F -e "$RPC" -e "$TOK"; }
jleak() { gs "journalctl -u garage.service --no-pager -o cat 2>/dev/null | grep -c -F -e $RPC -e $TOK; true" | tail -1; }
since=$(now)

# ---- GS-AC-23 run 1: fresh store, -vvv ----
play site.yml --tags garage -vvv "${FRESH[@]}" >"$L/ac23-fresh.log" 2>&1; rc=$?
n=$(leak "$L/ac23-fresh.log"); j=$(jleak)
check GS-AC-23/fresh-output "fresh store, -vvv, rc=$rc, $(wc -l <"$L/ac23-fresh.log" | tr -d ' ') output lines, fixture secret matches: $n" bash -c "[ $rc -eq 0 ] && [ $n -eq 0 ]"
check GS-AC-23/fresh-journal "journalctl -u garage.service after the fresh-store run: fixture secret matches: $j" test "$j" = 0

# ---- GS-AC-23 run 2: store with user-made buckets and keys (V3 state), -vvv ----
play site.yml --tags garage -vvv >"$L/ac23-user.log" 2>&1; rc=$?
buckets=$(gs 'source /var/tmp/garage-v3-guest.sh; G bucket list' | grep -c -E 'sstate|private-test')
n=$(leak "$L/ac23-user.log"); j=$(jleak)
check GS-AC-23/user-output "store with user-made state (buckets listed: $buckets), -vvv, rc=$rc, fixture secret matches: $n" bash -c "[ $rc -eq 0 ] && [ $buckets -ge 2 ] && [ $n -eq 0 ]"
check GS-AC-23/user-journal "journalctl -u garage.service after the user-state run: fixture secret matches: $j" test "$j" = 0
# sanity: the greps can match (the secret is really in the guest files, so a leak would be seen)
gs "grep -c -F $TOK /var/lib/garage/secrets/admin_token" >/dev/null 2>&1 && record GS-AC-23/grep-sanity PASS "the fixture token is in the secret file, so the grep would find it elsewhere"

# ---- GS-AC-12: second run changed=0, then --check --diff shows no diff ----
U="backup_uuid=$(cat "$FIXTURE_VM_DIR/backup_uuid")"
CF=(-e cloudflare_dns_api_token=fixture-cloudflare-not-a-secret)  # the caddy role refuses an empty token; fake value
play site.yml --tags garage,caddy,btrbk -e "$U" "${CF[@]}" >"$L/ac12-run1.log" 2>&1; rc1=$?
play site.yml --tags garage,caddy,btrbk -e "$U" "${CF[@]}" >"$L/ac12-run2.log" 2>&1; rc2=$?
c2=$(changed_of "$L/ac12-run2.log")
check GS-AC-12/second-run "--tags garage,caddy,btrbk: first rc=$rc1 changed=$(changed_of "$L/ac12-run1.log"); second rc=$rc2 changed=$c2" bash -c "[ $rc2 -eq 0 ] && [ '$c2' = 0 ]"
play site.yml --tags garage,caddy,btrbk -e "$U" "${CF[@]}" --check --diff >"$L/ac12-check.log" 2>&1; rc3=$?
cc=$(changed_of "$L/ac12-check.log"); nd=$(grep -c -E '^(---|\+\+\+) ' "$L/ac12-check.log")
check GS-AC-12/check-diff "--check --diff rc=$rc3 changed=$cc diff hunks: $nd" bash -c "[ $rc3 -eq 0 ] && [ '$cc' = 0 ] && [ $nd -eq 0 ]"
