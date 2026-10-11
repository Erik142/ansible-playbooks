#!/usr/bin/env bash
# ZeroTier needs the host's `tun` module loaded BEFORE the container starts:
# on the real VM (SELinux enforcing) the container's own module request is
# denied (AVC module_request, kmod char-major-10-200) and ZeroTier cannot open
# /dev/net/tun. Applies the whole role set to the 'bare' snapshot, then proves
#   1. /etc/modules-load.d/zerotier-tun.conf is exactly "tun" and `tun` is loaded
#   2. (enforcing) with tun unloaded the container cannot create its interface
#      (reproduces the incident), with tun preloaded the start is clean
# Step 2 switches the guest to `setenforce 1` after a restorecon; the guest is
# permissive again at the end (and a reset restores the snapshot anyway).
# Needs make-bare.sh to have been run.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ARGS=(site.yml --skip-tags cloudflare_dns -e zerotier_network_id=deadbeefdeadbeef)

"$SCN_DIR/../reset.sh" bare || exit 1
gs 'install -d /opt/podman/semaphore/data
    [ -f /opt/podman/semaphore/data/database.sqlite ] || sqlite3 /opt/podman/semaphore/data/database.sqlite "CREATE TABLE fixture_marker (id integer);"
    chown 1001:0 /opt/podman/semaphore/data/database.sqlite; chmod 0644 /opt/podman/semaphore/data/database.sqlite'
pre="$(gs 'lsmod | grep -qw tun && echo loaded || echo "not loaded"' | tail -1)"; rec ZT-TUN-pre INFO "before the apply: $pre"

ans ansible-playbook "${ARGS[@]}" </dev/null >"$RES_DIR/zt-tun-apply.log" 2>&1
rc=$?
rec ZT-TUN-apply INFO "rc=$rc $(grep -E '^ops-vm-fixture ' "$RES_DIR/zt-tun-apply.log" | tail -1 | tr -s ' ')"
[ "$rc" -eq 0 ] || exit "$rc"

content="$(gs 'od -An -c /etc/modules-load.d/zerotier-tun.conf | tr -s " "')"
[ "$content" = " t u n \n" ] && rec ZT-TUN-file PASS "modules-load.d file is exactly 'tun\\n'" || rec ZT-TUN-file FAIL "content: $content"
gs 'lsmod | grep -w tun' | grep -qw tun && rec ZT-TUN-lsmod PASS "lsmod shows tun after the apply" || rec ZT-TUN-lsmod FAIL "tun not loaded"
gs 'systemctl is-active zerotier.service' | grep -qx active && rec ZT-TUN-active PASS "zerotier.service active" || rec ZT-TUN-active FAIL "zerotier.service not active"

# --- enforcing ---------------------------------------------------------------
gs 'restorecon -RF /etc /usr /var /opt /root /home >/dev/null 2>&1; setenforce 1; getenforce' | tail -1 | grep -qx Enforcing \
  && rec ZT-ENF-mode PASS "guest is Enforcing" || { rec ZT-ENF-mode FAIL "could not switch to enforcing"; exit 1; }

zt_start() { # restart the unit, print the log of this start
  gs 'systemctl restart zerotier.service; sleep 12; journalctl -u zerotier.service --since "-14s" --no-pager -o cat 2>&1 | tail -30'
}

# 1. negative control: tun unloaded -> the module request comes from the container
gs 'systemctl stop zerotier.service; modprobe -r tun && echo unloaded'
zt_start >"$RES_DIR/zt-tun-enforcing-without.log"
if grep -qi 'could not open TUN/TAP' "$RES_DIR/zt-tun-enforcing-without.log"; then
  rec ZT-ENF-without PASS "reproduced: tun unloaded + enforcing -> 'could not open TUN/TAP'"
else
  rec ZT-ENF-without INFO "not reproduced (fixture policy/kernel differs); see zt-tun-enforcing-without.log"
fi
gs 'ausearch -m avc -ts recent 2>/dev/null | grep -c module_request' | tail -1 | xargs -I{} sh -c 'echo module_request AVCs: {}' | while read -r l; do rec ZT-ENF-avc INFO "$l"; done

# 2. the role's state: tun preloaded -> clean start
gs 'systemctl stop zerotier.service; systemctl restart systemd-modules-load.service; lsmod | grep -w tun' | grep -qw tun \
  && rec ZT-ENF-modload PASS "systemd-modules-load loads tun from the file" || rec ZT-ENF-modload FAIL "tun not loaded by systemd-modules-load"
zt_start >"$RES_DIR/zt-tun-enforcing-with.log"
if [ ! -s "$RES_DIR/zt-tun-enforcing-with.log" ]; then
  rec ZT-ENF-with FAIL "no zerotier log captured (guest unreachable under enforcing?)"
elif grep -qi 'could not open TUN/TAP' "$RES_DIR/zt-tun-enforcing-with.log"; then
  rec ZT-ENF-with FAIL "tun preloaded but ZeroTier still cannot open TUN/TAP"
else
  rec ZT-ENF-with PASS "tun preloaded + enforcing: no 'could not open TUN/TAP'"
fi
gs 'ip -br link | grep -E "^zt" || echo no-zt-interface' | tail -1 | while read -r l; do rec ZT-ENF-iface INFO "$l"; done
gs 'setenforce 0; getenforce' | tail -1 | while read -r l; do rec ZT-ENF-restore INFO "guest now $l"; done
