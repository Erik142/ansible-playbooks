# VM fixture results (T-27 to T-30)

90 PASS, 1 FAIL, 6 SKIPPED (97 scenario rows). The one FAIL is BD-AC-28 (a disproved spec assumption, BD-A-19, corrected in the spec). BD-AC-45 was accepted by the owner on 2026-10-09 (BD-A-23). Guest: openSUSE Tumbleweed aarch64 (qemu/HVF), see README.md for what that does not prove.

| Scenario | Result | Evidence |
|---|---|---|
| BD-AC-20 row 1 | PASS | rc=2, message names R-01, fingerprint unchanged |
| BD-AC-20 row 2 | PASS | rc=2, message names R-01, fingerprint unchanged |
| BD-AC-20 row 3 | PASS | rc=2, message names R-02, fingerprint unchanged |
| BD-AC-20 row 4 | PASS | rc=2, message names R-03, fingerprint unchanged |
| BD-AC-20 row 5 | PASS | rc=2, message names R-04, fingerprint unchanged |
| BD-AC-20 row 6 | PASS | rc=2, message names R-05, fingerprint unchanged |
| BD-AC-20 row 7 | PASS | rc=2, message names R-06, fingerprint unchanged |
| BD-AC-20 row 8 | PASS | rc=2, message names R-06, fingerprint unchanged |
| BD-AC-20 row 9 | PASS | rc=2, message names R-06, fingerprint unchanged |
| BD-AC-20 row 10 | PASS | rc=2, message names R-07, fingerprint unchanged |
| BD-AC-20 row 11 | PASS | rc=2, message names R-08, fingerprint unchanged |
| BD-AC-20 row 12 | PASS | rc=2, message names R-08, fingerprint unchanged |
| BD-AC-20 row 13 | PASS | rc=2, message names R-08, fingerprint unchanged |
| BD-AC-20 row 14 | PASS | rc=2, message names R-09, fingerprint unchanged |
| BD-AC-20 row 15 | PASS | rc=2, message names R-09, fingerprint unchanged |
| BD-AC-20 row 16 | PASS | rc=2, message names R-09, fingerprint unchanged |
| BD-AC-20 row 17 | PASS | rc=2, message names R-10, fingerprint unchanged |
| BD-AC-21 | PASS | --check rc=0 failed=0, 13 R-check tasks ran, fingerprint unchanged |
| BD-AC-22 | PASS | rc=0; GPT 1 partition @2048, btrfs LABEL=backups, only @btrbk, UUID 4018a4ce-fcbb-445c-a461-d39ae9249bf9 == part1, other disks' sha unchanged (end gap 33 sectors) |
| BD-AC-23 | PASS | second run changed=0, same UUID |
| BD-AC-24 row 1 | PASS | fails in backup_disk, message has backup_disk_uuid roles/backup_disk/README.md, fstab sha unchanged |
| BD-AC-24 row 2 | PASS | fails in backup_disk, message has 00000000-0000-0000-0000-000000000000, fstab sha unchanged |
| BD-AC-24 row 3 | PASS | fails in backup_disk, message has label, fstab sha unchanged |
| BD-AC-24 row 4 | PASS | fails in backup_disk, message has device, fstab sha unchanged |
| BD-AC-24 row 5 | PASS | fails naming @btrbk, no fstab line for the filesystem, fstab unchanged |
| BD-AC-26 | PASS | mount UUID+subvol=/@btrbk, fstab line exact, no C attr, 700 root:root |
| BD-AC-56 | PASS | BTRFS_SCRUB_MOUNTPOINTS="/:/mnt/backup/btrbk"; timer enabled OnCalendar=monthly  |
| BD-AC-29 row 1 | PASS | repo filesystems GPG Yes prio 150; only btrbk installed from it; OSS only: no match |
| BD-AC-29 row 2 | PASS | play failed naming the fingerprint var, repository not added |
| BD-AC-30 | PASS | Result=success; ro snapshots in <src>/.btrbk; Received UUID set on data.20261009T2147, containers.20261009T2147; no .snapshots content; restic-repos/cloud/config present; dumps fresh (between run start and source snapshot) |
| BD-AC-31 | PASS | second run success; 2 incremental '>>>' receives in the journal; each .btrbk holds parent+new (counts: 2 2 ) |
| BD-AC-32 | PASS | ro target: unit failed (Result=exit-code), notify-failure-immediate@btrbk ran (3 journal lines), next start success |
| BD-AC-35 row 1 | PASS | 700 root:root |
| BD-AC-35 row 2 | PASS | all files 600 root:root |
| BD-AC-35 row 3 | PASS | credentials files in /var/lib/db-dump on /var (btrfs subvolume of the root fs, not a snapshot source), 600 root:root; spec said target `/` (see defect log) |
| BD-AC-35 row 4 | PASS | play failed naming db_dump_dir, no db_dump file changed |
| BD-AC-36 | PASS | db-dump failed + alert (3 lines), fixture.sql sha unchanged, forgejo.db mtime newer, btrbk success, new containers snapshot (4 -> 5) |
| BD-AC-37 | PASS | lock held by psql; db-dump.service Result=exit-code in 56 s, journal 'db-dump: fixture: stopped after 60s (db_dump_timeout)', btrbk Result=success (first attempt failed because of a test artefact: pg_sleep ends early after a clock jump) |
| BD-AC-33 | PASS | max concurrent btrbk processes=1; manual 'btrbk run' second_rc=3, 'ERROR: Failed to take lock (another btrbk instance is running): /run/btrbk.lock'; unit Result=success |
| BD-AC-34 | PASS | killed during btrfs receive (first unit Result=success); next start Result=success; every subvolume has a Received UUID |
| BD-AC-39 | PASS | active; flags private-repos/append-only/max-size 107374182400; host user 'restic-server' (uid 478, <1000, nologin); Volume ends :Z |
| BD-AC-40 | PASS | dir 700 restic-server:restic-server on /mnt/data; htpasswd 1 bcrypt hash, 600 restic-server; python313-passlib-1.7.4-9.4.noarch; no password in unit/Quadlet files |
| BD-AC-40 (SELinux labels, BD-FR-160/BD-A-11) | SKIPPED | VM guest has no SELinux (tree built by zypper --root, selinux=0); verify on the NAS |
| BD-AC-41 (clients) | PASS | play failed naming restic_server_clients, no restic_server task changed |
| BD-AC-41 (emptypw) | PASS | play failed naming cloud, no restic_server task changed |
| BD-AC-41 (repopw) | PASS | play failed naming restic_server_maintenance_repo_password, no restic_server task changed |
| BD-AC-42 | PASS | wrong pw 401, right pw 200, other repo 401 |
| BD-AC-43 | PASS | after the play (+5 s): new password 200, old 401 |
| BD-AC-46 | PASS | client 'restic forget <id>' exit 3: 'Remove(<snapshot/..>) failed: unexpected HTTP response (403): 403 Forbidden'; snapshot still listed; restic check exit 0 (also covers the cloud-side client behaviour: backup works, forget is refused) |
| BD-AC-45 (rich rules, external source) | PASS | one rich rule per CIDR (runtime 2, permanent 2), no 8000/tcp in ports/services; external-path client via enp0s1: allowed CIDR 401, rule removed 000 (timeout/drop) |
| BD-AC-45 (ac45-allowed container) | PASS | 401 from the ac45-allowed network (10.89.45.0/24) - NOTE netavark puts that subnet in firewalld zone trusted, so this does not exercise the rich rule |
| BD-AC-45 (default podman network, trusted zone) | PASS | accepted by owner 2026-10-09 as BD-A-23 (spec reworded; was FAIL expecting 000). got 401: netavark adds 10.88.0.0/16 to firewalld zone trusted (runtime), so local container networks reach rest-server (still need htpasswd); A-05 residual risk materialised |
| BD-AC-44 | PASS | restic backup of 200 MiB exit 1; du -sb repos = 87828929 <= 105906176 (Save(<data/d3e992ac34>) failed: unexpected HTTP response (507): 507 Insufficient Storage F) |
| BD-AC-47 (plus2d) | PASS | forged time '2026-10-11 22:04:42': unit failed, alert (3), snapshots 4->4, journal lists 52693ff2 |
| BD-AC-47 (minus3d) | PASS | forged time '2026-10-06 22:04:54': unit failed, alert (3), snapshots 4->4, journal lists 239c2387 |
| BD-AC-48 | PASS | Result=success; policy line keep 7 daily/4 weekly/6 monthly, prune output, 'no errors were found'; no file outside restic-server ownership; next backup exit 0 |
| BD-AC-52 | PASS | 0 matches of the repo password in systemctl cat; env file 600 root:root |
| BD-AC-50 | PASS | wrong password: unit failed, alert (3); role run restored the file (changed tasks: 2) |
| BD-AC-51 | PASS | repository renamed away: unit failed, /mnt/data/restic-repos/cloud/config not created |
| BD-AC-54 | PASS | after wrong prune (5 -> 1 snapshot) rsync -a from snapper snapshot 1 (no --delete): check --read-data 0, 5 snapshots, next backup 0, maintenance Result=success |
| BD-AC-49 | PASS | unit 'activating' after ~2 min while restic mount held the repository, Result=success once the mount stopped |
| BD-AC-27 row 1 | PASS | fails before any change (changed=0), names /mnt/backup/btrbk |
| BD-AC-27 row 2 | PASS | fails before any change (changed=0), names /mnt/data |
| BD-AC-27 row 3 | PASS | fails before any change (changed=0), names /mnt/containers |
| BD-AC-27 row 4 | PASS | fails before any change (changed=0), names /mnt/data |
| BD-AC-27 row 5 | PASS | fails before any change (changed=0), names /mnt/data |
| BD-AC-27 row 6 | PASS | backup_disk,btrbk in one play: failed=0, path mounted by backup_disk first |
| BD-AC-57 | PASS | every BD-BR-05 NAS row and every BD-BR-04 RequiresMountsFor verified with systemctl show/cat |
| BD-AC-55 row 1 | PASS | Result=success, no alert (after a btrbk run and a client backup) |
| BD-AC-55 row 2 | PASS | stale path /mnt/backup/btrbk/data: unit failed, alert (3), journal names the path |
| BD-AC-55 row 3 | PASS | stale path /mnt/data/restic-repos/cloud/snapshots: unit failed, alert (3), journal names the path |
| BD-AC-55 row 4 | PASS | health Result=success with 'absent, skipped' in the journal; maintenance run failed and alerted |
| BD-AC-89 | PASS | Result=success ExecMainStatus=0 ; no alert; journal: btrbk-key-refresh: key B1FB53748720472205FA601998C97FE7324E6311 verified, imported, filesystems refreshed; expires in 209 days |
| BD-AC-90 | PASS | Result=exit-code ExecMainStatus=2 ; alert (5); journal names both fingerprints; gpg-pubkey set unchanged |
| BD-AC-91 | PASS | Result=exit-code ExecMainStatus=1 ; alert (5); journal: btrbk-key-refresh: signing key B1FB53748720472205FA601998C97FE7324E6311 expires in 209 days (< 3650); OBS has not extended it. Renew by hand |
| BD-AC-92 | PASS | Result=exit-code ExecMainStatus=3 ; journal names the URL |
| BD-AC-25 | PASS | flags false, five roles tagged: failed=0, 0 changed tasks, dummy units and paths still present (tags limited to the five roles: the other roles of site.yml need real third-party inputs) |
| BD-AC-38 | PASS | flag false: dummies kept; flag true: units and 3 paths gone (systemctl cat: no such unit); second run: no decommission task changed |
| SM-AC-04 (VM part) | PASS | first run changed=2 (line added above DEVICESCAN, custom line kept), second run changed=0, smartd active; (SMART itself cannot be exercised on virtio disks) |
| SM-FR-3/4 hook payload | PASS | hook (curl stubbed) posts to api.resend.com/emails with the device path and smartd message in the body |
| BD-AC-60 | PASS | after reboot: running at 17s; rest-server answered 200 at 17s (within 300 s of running); /mnt/backup/btrbk mounted |
| BD-AC-59 | PASS | listeners added vs the clean VM: only *:8000  |
| BD-AC-28 | PASS | disk detached: boot running, restic-server active + client backup exit 0, btrbk start job failed with result 'dependency', nothing below /mnt/backup, health failed + alert (5), disk-space: 'not a mount point', no usage line |
| BD-AC-28 (re-attach, BD-AC-26) | PASS | after re-attach and reboot BD-AC-26 holds |
| BD-AC-28 (BD-A-19: no OnFailure on dependency failure) | FAIL | assumption disproved: systemd triggers OnFailure= when the start job fails with 'dependency' (5 notify-failure-immediate@btrbk lines); spec corrected, the extra alert is harmless |
| README TODO rsync two remote operands | PASS | rsync refuses: The source and destination cannot both be remote. |
| DOC-O1 / BD-AC-83 (VM analogue) | PASS | cp -a from the received snapshot gives an identical file |
| README TODO psql authentication (DOC-O3) | PASS | psql -U <user> <db> inside the container needs no password (local socket trust) and the dump restores into an empty database (postgres:16 image; paperless/immich/tandoor images use the same entrypoint) |
| README TODO forgejo.db ownership (DOC-O3) | PASS | DEFECT CONFIRMED and fixed in README: 'cp -a' of the root:root 600 dump leaves 0:0 600 and the container uid cannot read it (Error: unable to open database "/mnt/containers/forgejo/volume/data/forgejo.db": unable to open database file); cp + chown --reference=<data dir> gives 1000:1000 600 and uid 1000 reads it |
| README TODO DOC-O2 swap into place | PASS | send/receive into the data filesystem top level, rename @data away, writable snapshot of the received copy as @data, remount: file checksum intact, writable, restic-server serves 200; the received copy lacks snapper's .snapshots (README step added) |
| BD-AC-58 | PASS | stack.sh (12 roles incl. backup_disk, btrbk, db_dump, restic_server, smartd, firewall) run 3 times in a row: changed=0 on runs 2 and 3 (ok=159); needs the fixture smartd drop-in (smartd.service is ConditionVirtualization=no on a VM). Only roles of the backup stack were tagged: caddy/tandoor/... need real third-party inputs |
| BD-AC-88 / BD-AC-07 (static re-run) | PASS | pytest tests/unit: 109 passed (incl. the new retention-policy test); tests/render-check.sh: OK (restic-server Quadlet asserts notify-failure@%n) |
| BD-AC-55 (non-zero device counters, BD-FR-35) | SKIPPED | by analysis in the spec: a failing 'btrfs device stats --check' cannot be produced on a healthy virtual disk |
| BD-FR-37..42 smartd on the backup disk (SMART data) | SKIPPED | virtio disks have no SMART; smartd runs with a fixture drop-in and monitors 0 devices; the line, hook payload and idempotency were checked (SM-AC-04 VM part, SM-FR-3/4) |
| BD-AC-82 [H] smartd test mail | SKIPPED | hardware scenario (real disk + real mail); the hook was exercised with a stubbed curl |
| BD-AC-80 / 81 / 83 / 84 / 85 / 86 / 87 [H] | SKIPPED | production smoke checks; never run by an agent (T-31, owner-run) |
| BD-AC-40 / BD-FR-160 / BD-A-11 SELinux enforcing | SKIPPED | the VM guest runs without SELinux; label behaviour of ':Z' and of the maintenance run must be checked on the NAS |

## How the rows were produced

Scripts in `tests/vm/scenarios/` (`t27-*`, `t28-*`, `t29-*`, `t30-*`); they append to
`$FIXTURE_VM_DIR/results.tsv` and `make-results.py` builds this file (last record per scenario wins).
A few rows were produced by running the corrected section of a script by hand after a test
artefact was fixed (BD-AC-35 row 3, BD-AC-37, BD-AC-45 split rows, BD-AC-58, BD-AC-28 A-19
row, DOC-O2); the scripts contain the corrected code. Commands that need the whole of
`site.yml` (BD-AC-25, BD-AC-58) were run with the tags of the backup stack, because the other
roles (Caddy, Cloudflare, Pocket ID, Tandoor, ...) need real third-party inputs.
Tested tree: branch `feature/nas-backup-disk` on top of `25bb3be` plus the uncommitted working
tree (nothing committed). The BD-BR-01 gate is therefore **not** recorded as satisfied:
BD-AC-45 (default Podman network) was resolved by owner decision (BD-A-23, accepted risk); the tree is uncommitted.

## Defect log

| # | What was wrong | Found by | Fixed in |
|---|---|---|---|
| 1 | `backup_disk` read the filesystem label/type from `lsblk` (udev cache); after `btrfs filesystem label` the stale label passed the BD-FR-22 check | BD-AC-24 row 3 | `roles/backup_disk/tasks/mount.yml` (`blkid -p`) |
| 2 | `restic_server` had no live mount guard (BD-FR-25): with `/mnt/data` unmounted it created the account, repo dir, `.htpasswd` and restarted the container on the bare mount point (6 changes) | BD-AC-27 rows 4, 5 | `roles/restic_server/tasks/main.yml` (+ README) |
| 3 | `restic-server.service` mailed through `notify-failure-immediate@` although BD-BR-05 and the crash-loop error case require `notify-failure@` (5 failures in 10 min) | BD-AC-57 | `roles/restic_server/templates/restic-server.container.j2`, `tests/render.d/30-restic-server.yml` (assertion set to the spec value), `roles/restic_server/README.md` |
| 4 | The maintenance run did not log its retention policy or the verified removal set (BD-AC-48) | BD-AC-48 | `roles/restic_server/files/restic-maintenance.py`, new test in `tests/unit/test_restic_maintenance.py` |
| 5 | `btrbk-key-refresh.py` did not log that `rpm --import` and `zypper refresh` ran before failing on a near-expiry key (BD-AC-91) | BD-AC-91 | `roles/btrbk/files/btrbk-key-refresh.py` |
| 6 | VM fixture: restic client was `fixture`, so the repository was `restic-repos/fixture`; the maintenance repo, freshness check and BD-AC-30/42 use `cloud` | BD-AC-30 prep | `inventories/vm/group_vars/all/vars.yml` |
| 7 | README: `sudo -u restic-server restic ...` (step 6, DOC-O6, DOC-O7) fails, the account has no home for restic's cache; DOC-O3 `cp -a` of `forgejo.db` leaves `root:root 600`, unreadable by the container uid; DOC-O2 had no swap-into-place steps; 4 `TODO: verify` markers | README TODOs, BD-AC-54 | `README.md` (`--no-cache`, chown, swap steps; rsync, psql, `--delete` resolved) |
| 8 | Spec statements that the VM disproved or refined: BD-A-19 (a `dependency` start failure DOES trigger `OnFailure=`), BD-AC-31 (a same-day second run sends nothing because `target_preserve` keeps the first snapshot per day; no `transaction_log` is configured), BD-AC-29 row 1, BD-AC-35 row 3 (`/var` is its own mount), BD-AC-48 (policy line) | BD-AC-28/31/29/35/48 | `reqs/backup-overview.md`, `reqs/backup-disk-init.md`, `reqs/backup-btrbk-and-db-dump.md`, `reqs/backup-restic-server.md` |
| 9 | `tests/static-checks.sh` AC-14 matched the VM scenario scripts that create the dummy old job | static run | `tests/static-checks.sh` (`--exclude-dir=scenarios`, documented) |
| 10 | `roles/firewall/README.md` did not say that rich rules are only added, never removed, and that container networks bypass them | BD-AC-45 | `roles/firewall/README.md` |

## Open

- **BD-AC-45, default Podman network (RESOLVED 2026-10-09: accepted as BD-A-23, spec reworded, scenario now expects 401).** Original finding: netavark adds every Podman network's subnet
  (`10.88.0.0/16`, and the `ac45-allowed` subnet) to the firewalld zone `trusted`, so a container
  on any Podman network reaches rest-server on the host network and gets `401` instead of `000`.
  External sources are gated correctly (removing the VM-network rule gives `000`, restoring it
  gives `401`). Impact is low (htpasswd still required, repository append-only) but BD-FR-111 as
  worded is not met for local container networks. Options for the owner: accept and reword
  BD-FR-111/BD-AC-45; or give rest-server `Network=` a dedicated bridge with a published port
  restricted by a rich rule (loses the A-05 host-network decision); or add rich rules in the
  `trusted` zone (rejects beat accepts there, so allowed container networks would need moving).
- The `firewall` role never removes rich rules (documented, see #10).
- `restic_server` `:Z` labels, SELinux denials (BD-A-11), SMART, x86_64, the real 6 TB disk and
  ZeroTier/LAN CIDRs cannot be proven on this guest (see README.md).

## Fixture deviations

- aarch64 Tumbleweed built with `zypper --root` from a Leap 16.0 bootstrap image (no Tumbleweed
  aarch64 cloud image exists); no SELinux; simplified root btrfs layout; minimal package set (extra
  packages added to `provision-guest.sh` as scenarios needed them: lvm2, mdadm, cryptsetup,
  e2fsprogs, procps, openssl, fuse3, hostname, rsync).
- `smartd.service` is `ConditionVirtualization=no`; a drop-in clears it (fixture only) so the
  `smartd` role is idempotent.
- BD-AC-20 row 11: the PV needs an active LV, otherwise the VG has no holder device.
- BD-AC-31/32/36/37: the guest clock is moved one day on before runs that must replicate.
- BD-AC-49: the lock is held with `restic mount` as `restic-server` (needs fuse3 and a
  `fusermount` symlink); a client backup would add a snapshot and trip the TOCTOU guard instead.
- BD-AC-90..92: the unit's `ExecStart` is overridden by a runtime drop-in; a throwaway key and a
  self-signed certificate on 127.0.0.1:8443 are installed in the guest and removed again.
- Nothing real was contacted except the openSUSE mirrors/OBS and Docker Hub, and
  `api.resend.com`: the `notify-failure*` instances that fire on every failure scenario run
  their `curl` with the fake key `re_fixture_not_a_real_key` (rejected with 401, no mail). The
  SMART hook was exercised with a stubbed `curl`.
