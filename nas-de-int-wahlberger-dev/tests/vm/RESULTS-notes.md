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
BD-AC-45 (default Podman network) is open and the tree is uncommitted.

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

- **BD-AC-45, default Podman network (FAIL).** netavark adds every Podman network's subnet
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
