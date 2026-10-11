#!/usr/bin/env bash
# SH-FR-208 (container_file_t on the database), dhcpv6-client (see s10), zypper exit
# 103 handling, rebootmgr facts.
set -uo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

rec SELINUX-MODE INFO "getenforce=$(gs 'getenforce 2>&1'); cmdline has selinux: $(gs 'grep -o "security=selinux selinux=1[^ ]*" /proc/cmdline')"
z="$(gs 'ls -Zd /opt/podman/semaphore/data /opt/podman/semaphore/data/database.sqlite /opt/podman/semaphore/config.json 2>&1' | tr '\n' ';')"
rec DB-LABEL "$([[ $z == *"database.sqlite"* && $z == *container_file_t*database.sqlite* || $z == *database.sqlite*container_file_t* ]] && echo PASS || echo FAIL)" "ls -Z: $z"
rec DB-MODE INFO "$(gs 'stat -c "%n %u:%g %a" /opt/podman/semaphore/data /opt/podman/semaphore/data/database.sqlite /opt/podman/semaphore/config.json /opt/podman/semaphore/semaphore.env' | tr '\n' ';')"
rec SEMAPHORE-UP INFO "$(gs 'systemctl is-active semaphore; podman ps --format "{{.Names}} {{.Status}}"' | tr '\n' ';')"

rec ZYPPER-UNIT INFO "$(gs 'systemctl cat zypper-dup.service | grep -E "SuccessExitStatus|ExecStart=|OnFailure"' | tr '\n' ';')"
r102="$(gs 'systemd-run --wait --collect -p SuccessExitStatus=102 -p Type=oneshot sh -c "exit 102" 2>&1 | grep -E "Result|status|Finished|Failed" | tr "\n" ";"')"
r103="$(gs 'systemd-run --wait --collect -p SuccessExitStatus=102 -p Type=oneshot sh -c "exit 103" 2>&1 | grep -E "Result|status|Finished|Failed" | tr "\n" ";"')"
rec ZYPPER-103-SYSTEMD INFO "stand-in unit with the zypper-dup.service SuccessExitStatus=102: exit 102 -> [$r102]; exit 103 -> [$r103]"
rec ZYPPER-DUP-DRYRUN INFO "real 'zypper dup --dry-run' exit code on the fixture: $(gs 'zypper --non-interactive dup --dry-run >/dev/null 2>&1; echo $?') (103 = zypper updated itself; not reproducible on a fresh image)"
rec REBOOTMGR INFO "$(gs 'rebootmgrctl is-active 2>&1; rebootmgrctl get-strategy 2>&1; rebootmgrctl get-window 2>&1; rebootmgrctl status 2>&1' | tr '\n' ';')"
