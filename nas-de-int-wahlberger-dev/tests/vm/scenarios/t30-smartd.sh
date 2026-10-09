#!/usr/bin/env bash
# smartd role on the VM: SM-FR-1/5/6 (idempotent line above DEVICESCAN, existing lines kept),
# SM-FR-3/4 hook payload (curl replaced by a recorder: nothing leaves the VM). `stack` state.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
gs 'cp /etc/smartd.conf /root/smartd.conf.orig'
# fresh smartd.conf: a pre-existing device line (to be preserved) above DEVICESCAN, no managed lines
gs 'printf "/dev/disk/by-id/custom-existing -a\nDEVICESCAN -a -m root\n" > /etc/smartd.conf'
R1=$(role_only smartd 2>&1 </dev/null | grep -E "ok=" ); R2=$(role_only smartd 2>&1 </dev/null | grep -E "ok=")
L=$(gs 'grep -vn "^#" /etc/smartd.conf | grep -v "^[0-9]*:$"')
lineno() { grep -n "$1" <<<"$(gs 'cat /etc/smartd.conf')" | head -1 | cut -d: -f1; }
ds=$(lineno '^DEVICESCAN'); tos=$(lineno 'ata-TOSHIBA'); cus=$(lineno 'custom-existing')
act=$(gs 'systemctl is-active smartd')
c1=$(grep -o 'changed=[0-9]*' <<<"$R1"); c2=$(grep -o 'changed=[0-9]*' <<<"$R2")
if [[ -n $ds && -n $tos && -n $cus && $tos -lt $ds && $cus -lt $ds && $c2 == changed=0 && $c1 != changed=0 && $act == active ]]; then record "SM-AC-04 (VM part)" PASS "first run $c1 (line added above DEVICESCAN, custom line kept), second run $c2, smartd active; (SMART itself cannot be exercised on virtio disks)"
else record "SM-AC-04 (VM part)" FAIL "ds=$ds tos=$tos cus=$cus $c1 $c2 act=$act"; fi
# hook
gs 'mkdir -p /tmp/fakebin; printf "#!/bin/sh\necho \"ARGS: \$*\" >> /tmp/curl.log\n" > /tmp/fakebin/curl; chmod +x /tmp/fakebin/curl; rm -f /tmp/curl.log
PATH=/tmp/fakebin:$PATH SMARTD_DEVICE=/dev/disk/by-id/virtio-FIXTUREBACKUP SMARTD_FULLMESSAGE="Device: /dev/disk/by-id/virtio-FIXTUREBACKUP, SMART test message" /usr/local/bin/smartd-notify.sh; echo rc=$?' >"$OUT/smartd-hook.txt" 2>&1
lg=$(gs 'cat /tmp/curl.log')
if grep -q 'rc=0' "$OUT/smartd-hook.txt" && grep -q 'api.resend.com/emails' <<<"$lg" && grep -q 'virtio-FIXTUREBACKUP' <<<"$lg" && grep -q 'SMART test message' <<<"$lg"; then record "SM-FR-3/4 hook payload" PASS "hook (curl stubbed) posts to api.resend.com/emails with the device path and smartd message in the body"
else record "SM-FR-3/4 hook payload" FAIL "$(head -c 300 <<<"$lg") $(cat $OUT/smartd-hook.txt | head -3)"; fi
gs 'cp /root/smartd.conf.orig /etc/smartd.conf; systemctl restart smartd; rm -rf /tmp/fakebin /tmp/curl.log'
