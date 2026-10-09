#!/usr/bin/env bash
# BD-AC-29..31. VM only. Starts from the `stack` snapshot state.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- BD-AC-29 row 1
a=$(gs 'zypper -n se -s -i btrbk; zypper lr -d | grep -A12 "filesystems"; zypper -n se -i -r filesystems | grep -c "^i"')
# btrbk is installed, so a plain search still lists it; search the OSS repos only.
none=$(gs 'zypper -n se -r oss -r non-oss -r update btrbk 2>&1')
echo "$a" >"$OUT/ac29-1.txt"
if grep -q filesystems <<<"$a" && grep -Eq '^1 \| filesystems +\|.*\| \(r \) Yes +\|.*\| +150 +\|' <<<"$a" && grep -q 'No matching items' <<<"$none" && [[ $(tail -1 <<<"$a") == 1 ]]; then
  record "BD-AC-29 row 1" PASS "repo filesystems GPG Yes prio 150; only btrbk installed from it; OSS only: no match"
else record "BD-AC-29 row 1" FAIL "see $OUT/ac29-1.txt"; fi

# --- BD-AC-29 row 2
gs 'zypper -n rr filesystems >/dev/null'
stack --tags btrbk -e btrbk_zypper_repo_gpg_fingerprint=0000000000000000000000000000000000000000 >"$OUT/ac29-2.log" 2>&1; rc=$?
lr=$(gs 'zypper lr | grep -c filesystems')
if [[ $rc -ne 0 && $lr == 0 ]] && grep -q 'btrbk_zypper_repo_gpg_fingerprint' "$OUT/ac29-2.log"; then record "BD-AC-29 row 2" PASS "play failed naming the fingerprint var, repository not added"
else record "BD-AC-29 row 2" FAIL "rc=$rc lr=$lr"; fi
stack --tags btrbk >"$OUT/ac29-restore.log" 2>&1 || echo "restore failed"
