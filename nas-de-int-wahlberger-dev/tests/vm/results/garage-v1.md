# Garage V1 results (T-16)

Run on the qemu fixture, `tests/vm/scenarios/garage-v1-run.sh`, 2026-10-18.

| Scenario | Result | Evidence |
|---|---|---|
| GS-AC-46 | FAIL | check mode on fresh host rc=2; readiness wait line:  |
| GS-AC-40 | PASS | flag false: rc=0 changed=0; paths absent (btrbk.service part: V3) |
| GS-AC-43 | PASS | rc=2, names both flags, nothing created |
| GS-AC-25/rpc-empty | PASS | rc=2, refused before any change, no secret in -vvv output |
| GS-AC-25/rpc-63hex | PASS | rc=2, refused before any change, no secret in -vvv output |
| GS-AC-25/token-31 | PASS | rc=2, refused before any change, no secret in -vvv output |
| GS-AC-25/domain-example | PASS | rc=2, refused before any change, no secret in -vvv output |
| GS-AC-25/domain-empty | PASS | rc=2, refused before any change, no secret in -vvv output |
| GS-AC-25/meta-path | PASS | rc=2, refused before any change, no secret in -vvv output |
| GS-AC-68//mnt/containers/garage/secrets | PASS | rc=2, names path |
| GS-AC-68//mnt/data/garage-secrets | PASS | rc=2, names path |
| GS-AC-14/a | PASS | rc=2 names /mnt/garage-test and tmpfs |
| GS-AC-14/b | PASS | rc=2 names /mnt/garage-test and tmpfs |
| GS-AC-14/nocreate | PASS | nothing below tmpfs, no garage.container |
| GS-AC-14/25/68 left no change | PASS | no garage subvolume, account or unit exists |
| GS-AC-16//mnt/data/garage | PASS | rc=2, names path + not a btrfs subvolume, keep.txt unchanged, no unit/secrets |
| GS-AC-16//mnt/containers/garage/meta | PASS | rc=2, names path + not a btrfs subvolume, keep.txt unchanged, no unit/secrets |
| GS-AC-19 | PASS | run rc=0; lsattr before/after identical: '----------------------' / '----------------------' |
| GS-AC-22/run | PASS | fresh role run rc=0 |
| GS-AC-01 | PASS | both mounts btrfs |
| GS-AC-02 | PASS | both are subvolumes and listed |
| GS-AC-03 | PASS | 700 root:root/700 garage:garage/700 garage:garage/750 root:garage/nometa/ |
| GS-AC-22 | PASS | 400 garage:garage/400 garage:garage/active/ |
| GS-AC-17 | PASS | huser=garage/478/garage:x:478:478::/home/garage:/usr/sbin/nologin/ (podman prints the user name, uid 478 from id -u) |
| GS-AC-18 | PASS | ---------------C------ /mnt/containers/garage/meta |
| GS-AC-35 | PASS | restart then garage status exit 0 after 2 s (config read from declared path; image has no /etc/garage.toml) |
| GS-AC-36 | FAIL | healthcheck run exit 0 + command in inspect |
| GS-AC-37 | PASS | OnFailure=notify-failure@garage.service.service/RequiresMountsFor=/run/containers /mnt/containers/garage/meta /mnt/data/garage/data /mnt/data /var/lib/garage/secrets /mnt/containers/garage /mnt/contai |
| GS-AC-75 | PASS | status rc=0 + NO ROLE ASSIGNED; signed PUT before layout:  aws: [ERROR]: An error occurred (AccessDenied) when calling the PutObject operation: Forbidden: No such key: GKfake0000000000000000000 rc=254 |
| GS-AC-11 | PASS | host side nothing open/listening (''); caddy.network open: open3900 open3902  |
| garage-test-setup | PASS | layout, buckets sstate/private-test, key test-rw, objects selftest/up and K |
| GS-AC-15 | PASS | rc=0 ids N=258/258 M=258/258; Objects:           2  |
| GS-AC-71 | PASS | NRestarts 1 -> 2, status ok=1 |
| GS-AC-67 | PASS | FSROOT=/@/var; secret files in snapshot dirs: 0 (btrbk run + snapper create: not run) |
| GS-AC-72 | PASS | rc=2 in 23s overall; failed task is the readiness wait naming garage_ready_timeout_sec |
| GS-AC-05 | SKIPPED | samba role is not part of the VM stack (no smbclient/testparm) |

Open: GS-AC-36 (scratch image has no /bin/sh, `HealthCmd=/garage status` runs as CMD-SHELL; spec GS-FR-16 needs exec form), GS-AC-46 (container role handler `Restart the container service` fails in check mode on a fresh host), GS-AC-05 (no Samba on the VM), GS-FR-65 fixture domain `s3.example.test` is refused by GS-FR-135 (runs pass `-e garage_s3_domain=s3.de.int.wahlberger.dev`).
