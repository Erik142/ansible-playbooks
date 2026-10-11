#!/usr/bin/env bash
# SH-AC-03/04 analogue, SH-FR-185/189: ZeroTier zone binding by interface name,
# permanent-only creation, reload, reboot; public zone service list.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

base="$(g 'cat /var/lib/fixture-baseline-public-services.txt')"
rec FW-BASELINE INFO "public zone services before any role: [$base]"

perm="$(gs 'firewall-cmd --permanent --zone=zerotier --list-all' | tr '\n' ' ' | tr -s ' ')"
rec FW-PERM-ZONE INFO "permanent zerotier zone: $perm"
rec FW-PERM-BIND "$([[ $perm == *"interfaces: zt0"* ]] && echo PASS || echo FAIL)" "zt0 in permanent zerotier zone"

# After the creating run, before any reload: runtime knowledge of the zone (AC-56).
known="$(gs 'firewall-cmd --get-zones')"
rec FW-RUNTIME-PRE-RELOAD INFO "runtime zones before reload: [$known]; zone of zt0: [$(gs 'firewall-cmd --get-zone-of-interface=zt0 2>&1')]"
rec FW-HTTPS-PRE-RELOAD INFO "client https before reload: $(peer_https)"

gs 'firewall-cmd --reload' >/dev/null
az="$(gs 'firewall-cmd --get-active-zones' | tr '\n' ' ' | tr -s ' ')"
rec FW-RELOAD "$([[ $az == *"zerotier interfaces: zt0"* ]] && echo PASS || echo FAIL)" "after firewall-cmd --reload, active zones: $az"
rec FW-HTTPS-POST-RELOAD INFO "client https after reload: $(peer_https)"

echo ">> rebooting the guest"
reboot_guest
az="$(gs 'firewall-cmd --get-active-zones' | tr '\n' ' ' | tr -s ' ')"
rec FW-REBOOT "$([[ $az == *"zerotier interfaces: zt0"* ]] && echo PASS || echo FAIL)" "after guest reboot, active zones: $az; zt0 service after firewalld"
rec FW-REBOOT-ZT0 INFO "zt0 state: $(gs 'ip -br addr show zt0' | tr -s ' ')"

pub_rt="$(gs 'firewall-cmd --zone=public --list-services')"
pub_pm="$(gs 'firewall-cmd --permanent --zone=public --list-services')"
rec FW-PUBLIC-SERVICES "$([[ $pub_rt == ssh && $pub_pm == ssh ]] && echo PASS || echo FAIL)" "public zone services runtime=[$pub_rt] permanent=[$pub_pm] (baseline [$base]); dhcpv6-client removed: $([[ $base == *dhcpv6-client* && $pub_pm != *dhcpv6-client* ]] && echo yes || echo n/a)"
rec FW-ZT-SERVICES INFO "zerotier zone: $(gs 'firewall-cmd --zone=zerotier --list-all' | tr '\n' ' ' | tr -s ' ')"
rec FW-PUBLIC-RICH INFO "public zone permanent rich rules: [$(gs 'firewall-cmd --permanent --zone=public --list-rich-rules')]"
