#!/usr/bin/env bash
# Shared helpers for the T-16 scenarios. Sourced, not run.
# shellcheck shell=bash
SCN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCN_DIR/../lib.sh"
OPS_ROOT="$(cd "$SCN_DIR/../../.." && pwd)"
RES_DIR="$FIXTURE_VM_DIR/results"
mkdir -p "$RES_DIR"
RESULTS_TSV="$RES_DIR/results.tsv"

ZT_IP=198.51.100.10
PEER_IP=198.51.100.20
ALT_IP=203.0.113.5
SITE=semaphore.fixture.invalid

# g <cmd...>: run as the fixture user; gs '<script>': run a script as root.
g() { vm_ssh "$@"; }
gs() { vm_ssh "sudo -n bash -c $(printf '%q' "$1")"; }
ans() { "$OPS_ROOT/tests/vm/ans.sh" "$@"; }

# rec <id> <PASS|FAIL|INFO> <text>: print and append one measured result.
rec() {
  printf 'RESULT|%s|%s|%s\n' "$1" "$2" "$3"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS_TSV"
}

# peer_https [src]: HTTPS request to the stand-in ZT IP from the client
# namespace (so it arrives on zt0). Prints "<http-code> rc=<curl-rc>".
peer_https() {
  local src="${1:-}"
  gs "code=\$(ip netns exec ztpeer curl -sk -o /dev/null -w '%{http_code}' --max-time 6 ${src:+--interface $src} --resolve $SITE:443:$ZT_IP https://$SITE/); echo \"\$code rc=\$?\"" 2>&1 | tail -1
}

# reboot_guest: reboot and wait until ssh answers on a NEW boot id.
reboot_guest() {
  local before
  before="$(g 'cat /proc/sys/kernel/random/boot_id')"
  g 'sudo -n systemctl reboot' || true
  sleep 15
  local i
  for ((i = 0; i < 100; i++)); do
    sleep 4
    [[ "$(g 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" != "$before" && -n "$(g 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" ]] && break
  done
  wait_ssh 120
  # give fixture-zt0, firewalld and the Quadlet services a moment
  sleep 25
}
