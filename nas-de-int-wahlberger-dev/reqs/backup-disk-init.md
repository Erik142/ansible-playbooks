## Feature: Local backup disk, btrbk, and NAS-hosted restic REST server (backup disk: init, mount, health)
status:            ready
priority:          must
version:           3.0
quality:           feature-level scores in [backup-overview.md](backup-overview.md)

### Problem Statement

This file covers three things:
- the init playbook that formats the backup disk exactly once;
- the VM gate that proves the init playbook before production;
- the `backup_disk` role, which mounts the only subvolume `@btrbk` and watches the disk with scrub, smartd and a daily health check.

Terms, constraints, decisions (BD-D-04, BD-D-05, BD-D-09), assumptions and NFRs are in [backup-overview.md](backup-overview.md). IDs from other files resolve through the [index.md ID map](index.md#id-map).

### Actors

See [backup-overview.md](backup-overview.md#actors). Main actors here: the owner, the VM fixture, the NAS host, the backup disk, smartd, btrfsmaintenance and notify_failure.

### Functional Requirements

#### A. Initialisation (init playbook)
- BD-FR-01 [Must]: The repository shall contain the init playbook `nas-de-int-wahlberger-dev/backup_disk_init.yml`, with `hosts: nas`.
- BD-FR-02 [Must]: Neither `site.yml` nor any file it includes shall reference `backup_disk_init.yml` or any `roles/backup_disk/tasks/init*.yml` file.
- BD-FR-03 [Must]: No Ansible task reachable from `site.yml`, under any tag selection, shall write to a block device other than through a mounted filesystem.
- BD-FR-04 [Must]: No Ansible task reachable from `site.yml`, under any tag selection, shall create or delete a btrfs subvolume.
- BD-FR-05 [Must]: No file under `inventories/`, no role `defaults/` or `vars/` file and no playbook file shall define `backup_disk_init_confirm`.
- BD-FR-06 [Must]: If any refusal condition of BD-BR-03 holds, then the init playbook shall fail before writing to any block device.
- BD-FR-07 [Must]: When the init playbook fails under BD-BR-03, the failure message shall name every refusal condition ID that holds.
- BD-FR-08 [Must]: When refusal condition R-09 holds, the failure message shall list each signature with the type and offset reported by `wipefs --no-act`.
- BD-FR-09 [Must]: When the backup disk is in the initialised state and none of R-01 to R-08 holds, the init playbook shall write nothing and report `changed=0`.
- BD-FR-10 [Must]: When run with `--check`, the init playbook shall evaluate every BD-BR-03 condition and write nothing.
- BD-FR-11 [Must]: The init playbook shall pass no force option (`-f`, `--force`) to any partitioning, filesystem-creation or signature-erasing command.
- BD-FR-12 [Must]: When no BD-BR-03 condition holds, the init playbook shall create a GPT partition table with exactly one partition that starts at 1 MiB and ends within the last 1 MiB of the disk.
- BD-FR-13 [Must]: After BD-FR-12, the init playbook shall create a btrfs filesystem labelled `backup_disk_label` on that partition.
- BD-FR-14 [Must]: After BD-FR-13, the init playbook shall create the subvolume `@btrbk` directly below the top level (subvolume id 5), and no other subvolume.
- BD-FR-15 [Must]: When the init playbook completes without failure, it shall print the backup filesystem's UUID.
- BD-FR-16 [Must]: The init playbook shall write to no block device other than `backup_disk_device` and the partition it creates there.

#### C. Backup filesystem and health (role `backup_disk`)
BD-FR-25, BD-FR-27, BD-FR-28 and BD-FR-33 (mount guards and unit properties) are cross-cutting and are in [backup-overview.md](backup-overview.md#functional-requirements).

- BD-FR-20 [Must]: If `backup_disk_uuid` is empty, then the `backup_disk` role shall fail before any change, with a message naming `backup_disk_uuid` and `roles/backup_disk/README.md`.
- BD-FR-21 [Must]: If no filesystem with UUID `backup_disk_uuid` is present, then the `backup_disk` role shall fail before any change, with a message naming the UUID and `roles/backup_disk/README.md`.
- BD-FR-22 [Must]: If the filesystem with UUID `backup_disk_uuid` is not btrfs, does not carry the label `backup_disk_label`, or is not on a partition of `backup_disk_device`, then the `backup_disk` role shall fail before any change, with a message naming the mismatching property.
- BD-FR-23 [Must]: The `backup_disk` role shall persist one `/etc/fstab` entry per `backup_disk_mounts` entry (default: the single entry `/mnt/backup/btrbk`, `/@btrbk`). Each entry shall have source `UUID=<backup_disk_uuid>`, type `btrfs`, and exactly these options: `subvol=<entry subvol>,compress=zstd:1,noatime,nofail,x-systemd.device-timeout=<backup_disk_device_timeout>`.
- BD-FR-24 [Must]: No task shall set the `C` (no copy-on-write) file attribute on any path of the backup filesystem.
- BD-FR-26 [Must]: If a `backup_disk_mounts` path is not mounted after the `backup_disk` role's mount task, then the role shall fail, with a message naming the path and its subvolume.
- BD-FR-29 [Must]: The root directory of the mounted `@btrbk` subvolume shall have mode `0700` and owner `root:root`.
- BD-FR-30 [Must]: `BTRFS_SCRUB_MOUNTPOINTS` in `/etc/sysconfig/btrfsmaintenance` shall contain one `backup_disk_mounts` path.
- BD-FR-31 [Must]: `BTRFS_SCRUB_MOUNTPOINTS` shall keep every value it had before the run.
- BD-FR-32 [Must]: `btrfs-scrub.timer` shall be enabled, with a period no longer than one calendar month.
- BD-FR-34 [Must]: If a `backup_disk_mounts` path is not mounted when the health check runs, then the health check shall fail.
- BD-FR-35 [Must]: If `btrfs device stats --check` reports a non-zero error counter for the backup filesystem, then the health check shall fail.
- BD-FR-36 [Must]: If no direct child of a `backup_disk_freshness_checks` path has a birth time (`stat -c %W`) within that entry's `max_age_hours`, then the health check shall fail, with a journal line naming that path.
- BD-FR-37 [Must]: (The hook, packages and `smartd.service` of BD-FR-37 to BD-FR-42 come from the shared `smartd` role, see [smartd-main-disk.md](smartd-main-disk.md); `backup_disk` adds only its own device line.) smartd shall monitor the backup disk, addressed by its `/dev/disk/by-id/` path, with the `-a` directive.
- BD-FR-38 [Must]: smartd shall schedule self-tests of the backup disk with `-s <backup_disk_smartd_schedule>`.
- BD-FR-39 [Must]: When smartd logs a warning for the backup disk, an email shall reach `notify_failure_to_address` within 5 min, sent with the `notify_failure` Resend credentials.
- BD-FR-40 [Must]: The BD-FR-39 email shall contain the device path and smartd's message text.
- BD-FR-41 [Must]: `smartd.service` shall be enabled and active.
- BD-FR-42 [Should]: Every device line and `DEVICESCAN` line in the host's smartd configuration before the first run shall still be present after it.
- BD-FR-43 [Could]: Where `backup_disk_hdparm_spindown` is greater than 0, the backup disk's standby timeout shall be set to that `hdparm -S` value at every boot.
- BD-FR-44 [Could]: Where `backup_disk_hdparm_spindown` is greater than 0, smartd shall skip checks of the backup disk while the disk is in standby (`-n standby`).
- BD-FR-45 [Must]: `disk_space_paths` in `vars.yml` shall contain `/mnt/backup/btrbk` in addition to `/`, `/mnt/data` and `/mnt/containers`.
- BD-FR-46 [Must]: If a `disk_space_paths` entry is not a mount point, then the disk space check shall log `<path>: not a mount point` for it, and shall report no usage figure and no threshold crossing for it.
- BD-FR-159 [Must]: If a `backup_disk_freshness_checks` path does not exist, then the health check shall log `<path>: absent, skipped` and shall not fail for that entry. After the cut-over, a missing path is alerted by btrbk (BD-FR-60) or by the maintenance run (BD-FR-119).

### Business Rules

- BD-BR-01: Gate. Production runbook step 2 (init on the backup disk) runs only after every [V] scenario of this feature has passed on the VM fixture at the commit being deployed.
- BD-BR-02: The backup disk is in the **initialised state** when all of these hold:
  - it has a GPT partition table with exactly one partition;
  - that partition holds a btrfs filesystem labelled `backup_disk_label`;
  - that filesystem has the subvolume `@btrbk` directly below its top level.
- BD-BR-03: Refusal conditions of the init playbook. "Before any write" means before the first command that writes to any block device.

| ID | Condition |
|---|---|
| R-01 | `backup_disk_init_confirm` is undefined, or is not exactly equal to `backup_disk_device` |
| R-02 | The play's host list (`ansible_play_hosts_all`) has more than one host |
| R-03 | `backup_disk_device` is not below `/dev/disk/by-id/` |
| R-04 | `backup_disk_device` does not resolve to a whole disk (`lsblk` TYPE is not `disk`, e.g. a partition) |
| R-05 | The device size differs from `backup_disk_expected_size_bytes` by more than `backup_disk_size_tolerance_percent` (default 1) |
| R-06 | The device or one of its partitions is mounted |
| R-07 | The device or one of its partitions is active swap |
| R-08 | The device or one of its partitions has a holder (non-empty `/sys/class/block/<name>/holders/`: LVM, MD RAID, dm-crypt) |
| R-09 | The device is not in the initialised state, and `wipefs --no-act` reports a signature on the device or on a partition |
| R-10 | The device is not in the initialised state, and its first or last 1 MiB contains a non-zero byte |

- BD-BR-12: The backup filesystem is not needed to boot. While it is absent:
  - the NAS boots and runs every other service, including rest-server, whose repositories are on `/mnt/data`;
  - nothing is written below `/mnt/backup/btrbk` (BD-FR-28).

### Inputs

| Name | Type | Required | Constraints |
|---|---|---|---|
| `backup_disk_device` | path | no | Default `/dev/disk/by-id/wwn-0x500003982b7021c1`; below `/dev/disk/by-id/` |
| `backup_disk_expected_size_bytes` | int | no | Default `6001175126016` (verified, BD-A-16) |
| `backup_disk_size_tolerance_percent` | int | no | Default `1` |
| `backup_disk_init_confirm` | str | init only | Extra-var only (BD-FR-05); must equal `backup_disk_device` |
| `backup_disk_uuid` | str (UUID) | yes when enabled | Role default `""`; set at runbook step 3 |
| `backup_disk_label` | str | no | Default `backups` |
| `backup_disk_mounts` | list of `{path, subvol}` | no | Default: one entry, `/mnt/backup/btrbk` with `/@btrbk` |
| `backup_disk_device_timeout` | str | no | Default `30s` |
| `backup_disk_smartd_schedule` | str | no | Default `(S/../../7/01\|L/../01/./10)`: short test Sundays 01:00, long test on the 1st at 10:00 |
| `backup_disk_hdparm_spindown` | int | no | `hdparm -S` value 0-251. Default `0` (off) |
| `backup_disk_health_on_calendar` | str | no | Default `*-*-* 09:00:00` |
| `backup_disk_freshness_checks` | list of `{path, max_age_hours}` | no | Default `[]`. Production: `/mnt/backup/btrbk/data`, `/mnt/backup/btrbk/containers` and `/mnt/data/restic-repos/cloud/snapshots`, each 26 |

### Outputs

| Name | Type | Constraints |
|---|---|---|
| GPT, one partition, btrfs `backups`, subvolume `@btrbk` | On-disk layout | Written only by the init playbook |
| `/etc/fstab` entry for `/mnt/backup/btrbk` | Config | BD-FR-23 |
| `BTRFS_SCRUB_MOUNTPOINTS`; smartd line; optional spindown setting | Config | BD-FR-30 to BD-FR-32, BD-FR-37, BD-FR-38, BD-FR-43, BD-FR-44 |
| `backup-disk-health.service` / `.timer` | systemd units | BD-FR-34 to BD-FR-36, BD-FR-159, BD-BR-05 |
| Alerts | Email via Resend | Health check failures; smartd hook |

### Error Cases

| Condition | Expected behaviour |
|---|---|
| Any BD-BR-03 condition holds at init | Fails before any write; the message names the R-IDs (BD-FR-06, BD-FR-07) and lists signatures for R-09 (BD-FR-08) |
| Init fails after its first write (partial init) | The next init refuses under R-09 or R-10. Recovery is DOC-B4: verify identity, run `wipefs -a <by-id path>` by hand, re-run the init |
| Init re-run on the initialised, unmounted disk | No write, `changed=0` (BD-FR-09). If the disk is mounted, R-06 refuses |
| `backup_disk_uuid` empty, the filesystem absent, or the identity mismatching | `backup_disk` fails before any change (BD-FR-20 to BD-FR-22). DOC-B5 gives `--skip-tags backup_disk,btrbk` for running `site.yml` while the disk is dead |
| Backup filesystem absent at boot or later | The NAS boots, and rest-server keeps serving (BD-BR-12). `btrbk.service` does not start (dependency) and nothing is written below `/mnt/backup/btrbk`. The health check fails and raises an alert at its next run (BD-FR-34) |
| No new btrbk or cloud snapshot within 26 h | The health check fails and raises an alert (BD-FR-36) |
| A freshness path does not exist (for example, the cloud repository between runbook steps 5 and 6) | Logged as skipped; the health check does not fail for it (BD-FR-159) |
| btrfs device error counter non-zero (from scrub or normal I/O) | The health check fails and raises an alert (BD-FR-35) |
| smartd warning | Email within 5 min (BD-FR-39) |
| Backup filesystem fills up | `disk_space` alerts at 85 % (BD-FR-45); btrbk fails and raises an alert (BD-FR-60) |

### Acceptance Criteria

Scenario BD-AC-04 [S]: Destructive operations are unreachable from site.yml (BD-FR-01 to BD-FR-05, BD-FR-11, BD-FR-24, BD-BR-03)
- Given `nas-de-int-wahlberger-dev/` at the feature commit, with `R` = every file under `roles/*/tasks`, `roles/*/handlers`, `roles/*/templates`, `roles/*/files`, `inventories/*/group_vars` and `inventories/*/host_vars`, plus `site.yml`
- When the operator runs these four checks:
  - (a) `grep -rnE 'community\.general\.(parted|filesystem|btrfs_subvolume)|mkfs|wipefs|sgdisk|sfdisk|\bparted\b|\bdd\b|blkdiscard|shred|cryptsetup|btrfs (device (add|delete|remove)|replace)|subvolume (create|delete)|chattr' R`;
  - (b) `grep -rnE '(include|import)_(tasks|role|playbook)' R`;
  - (c) `grep -rn 'backup_disk_init_confirm' inventories/ roles/*/defaults roles/*/vars *.yml`;
  - (d) `grep -nE '(-f|--force)\b' roles/backup_disk/tasks/init*.yml`.
- Then every (a) match is in `roles/backup_disk/tasks/init*.yml`, except `chattr` lines that do not set `+C` (BD-FR-03, BD-FR-04, BD-FR-24)
- And no (b) match takes a templated file name (`{{`) or names an `init*` file outside `backup_disk_init.yml` (BD-FR-02)
- And (c) matches only tasks that read the variable, never a definition (`backup_disk_init_confirm:` as a YAML key) (BD-FR-05)
- And (d) prints nothing (BD-FR-11)
- And `backup_disk_init.yml` exists, and its only play has `hosts: nas` (BD-FR-01)

Scenario Outline BD-AC-20 [V]: The init playbook refuses an unsafe target without writing (BD-FR-06 to BD-FR-08, BD-BR-03)
- Given the spare disk (or, where `<setup>` says so, another disk) prepared as `<setup>`
- And the operator saves its fingerprint: `wipefs --no-act --json`, `sfdisk --dump` where a table exists, and the `sha256sum` of its first and last 1 MiB
- When the operator runs `ansible-playbook -i inventories/vm backup_disk_init.yml -e backup_disk_init_confirm=<by-id path>` with `<variation>`
- Then the play fails, and its message contains `<R-ID>`
- And the saved fingerprint is unchanged
- Examples (one test per row):

| Row | `<setup>` | `<variation>` | `<R-ID>` |
|---|---|---|---|
| 1 | blank | `backup_disk_init_confirm` omitted | R-01 |
| 2 | blank | confirm = `<by-id path>x` | R-01 |
| 3 | blank | group `nas` temporarily holds a second host | R-02 |
| 4 | blank | `-e backup_disk_device=/dev/vdb` (kernel name) | R-03 |
| 5 | GPT, one partition | device = `<by-id path>-part1` | R-04 |
| 6 | blank | `-e backup_disk_expected_size_bytes=<size × 1.05>` | R-05 |
| 7 | ext4 on the whole disk, mounted | none | R-06 |
| 8 | GPT, ext4 on partition 1, partition mounted | none | R-06 |
| 9 | the VM's root disk (device = its by-id path, expected size = its size) | none | R-06 |
| 10 | swap on the whole disk, active | none | R-07 |
| 11 | LVM PV with an active VG | none | R-08 |
| 12 | member of an active MD RAID1 with the scratch disk | none | R-08 |
| 13 | LUKS2, opened | none | R-08 |
| 14 | ext4 on the whole disk, unmounted | none | R-09, with type and offset listed (BD-FR-08) |
| 15 | partial init: GPT with one partition, no filesystem | none | R-09, with type and offset listed |
| 16 | GPT, btrfs `backups` without `@btrbk` | none | R-09, with type and offset listed (BD-BR-02) |
| 17 | no signature; random bytes in the last 1 MiB | none | R-10 |

Scenario BD-AC-21 [V]: Check mode writes nothing (BD-FR-10)
- Given a blank spare disk and its saved fingerprint (BD-AC-20)
- When the operator runs the init command with `--check`
- Then the recap shows `failed=0`, every R-01 to R-10 check task ran, and the fingerprint is unchanged

Scenario BD-AC-22 [V]: Initialising a blank disk (BD-FR-12 to BD-FR-16)
- Given a blank spare disk, the `sha256sum` of the whole device of every other non-root VM disk, and the `sha256sum` of the root disk's first and last 1 MiB
- When the operator runs the init command
- Then `failed=0`
- And `sfdisk --dump` shows `label: gpt` and one partition, starting at sector 2048 and ending within the last 2048 sectors (BD-FR-12)
- And `blkid` of partition 1 shows `TYPE=btrfs` and `LABEL=backups` (BD-FR-13)
- And with the top level mounted, `btrfs subvolume list` shows exactly `@btrbk`, at top level 5 (BD-FR-14)
- And the printed UUID equals partition 1's UUID (BD-FR-15)
- And every saved checksum is unchanged (BD-FR-16)

Scenario BD-AC-23 [V]: A re-run on the initialised, unmounted disk changes nothing (BD-FR-09, BD-BR-02)
- Given BD-AC-22 has passed
- When the operator runs the init command again
- Then the recap shows `changed=0`, and the printed UUID is the same

Scenario Outline BD-AC-24 [V]: A normal run without a matching backup filesystem fails clearly (BD-FR-20 to BD-FR-22, BD-FR-26)
- Given `backup_disk_enabled: true`, `<state>`, and the saved `sha256sum /etc/fstab`
- When the operator runs `ansible-playbook -i inventories/vm site.yml --tags backup_disk`
- Then the play fails in `backup_disk`, with a message containing `<message>`
- And `<fstab>`
- Examples:

| Row | `<state>` | `<message>` | `<fstab>` |
|---|---|---|---|
| 1 | `backup_disk_uuid: ""` | `backup_disk_uuid`, `roles/backup_disk/README.md` (BD-FR-20) | checksum unchanged |
| 2 | UUID `00000000-0000-0000-0000-000000000000` | that UUID (BD-FR-21) | checksum unchanged |
| 3 | the label changed with `btrfs filesystem label <mnt> other` | `label` (BD-FR-22) | checksum unchanged |
| 4 | `backup_disk_device` = the scratch disk's by-id path | `device` (BD-FR-22) | checksum unchanged |
| 5 | a filesystem labelled `backups` without `@btrbk` | `@btrbk` (BD-FR-26) | no line mounts that filesystem |

Scenario BD-AC-26 [V]: The backup filesystem is mounted as specified (BD-FR-23, BD-FR-24, BD-FR-29)
- Given runbook steps 2-3 have run on the VM
- Then `findmnt -no UUID,OPTIONS /mnt/backup/btrbk` shows `backup_disk_uuid` and `subvol=/@btrbk`, and its fstab line equals BD-FR-23's string
- And `lsattr -d /mnt/backup/btrbk` shows no `C`
- And `stat -c '%a %U:%G' /mnt/backup/btrbk` prints `700 root:root`

Scenario BD-AC-28 [V]: The NAS keeps working while the backup filesystem is absent (BD-BR-12, BD-FR-28, BD-FR-34, BD-FR-46, BD-NFR-08, BD-A-19)
- Given the VM after runbook step 5, with the backup virtual disk detached
- When the operator reboots the VM
- Then `systemctl is-system-running --wait` prints `running` or `degraded`, with no manual action (BD-NFR-08)
- And `restic-server.service` is active, and a client `restic backup` exits 0 (BD-BR-12)
- And after `systemctl start btrbk.service`, `find /mnt/backup -xdev -mindepth 2` prints nothing (BD-FR-28), and the `btrbk.service` start job ends with result `dependency` (its `OnFailure=` instance does start, BD-A-19)
- And `systemctl start backup-disk-health.service` ends `failed`, and an alert is raised within 5 min (BD-FR-34, BD-NFR-10)
- And the `disk-space-check.service` journal contains `/mnt/backup/btrbk: not a mount point` and no usage line for that path (BD-FR-46)
- And after the disk is re-attached and the VM rebooted, BD-AC-26 passes

Scenario Outline BD-AC-55 [V]: The health check (BD-FR-35, BD-FR-36, BD-FR-159, BD-NFR-05, BD-NFR-06, BD-A-20)
- Given `<state>`
- When the operator starts `backup-disk-health.service`
- Then `<expectation>`
- Examples:

| Row | `<state>` | `<expectation>` |
|---|---|---|
| 1 | a btrbk run and a client backup within the last 26 h | `Result=success`, no alert raised |
| 2 | the freshness entry for `/mnt/backup/btrbk/data` overridden to `max_age_hours: 0` | `failed`, an alert raised, and the journal names that path (BD-FR-36) |
| 3 | the freshness entry for `/mnt/data/restic-repos/cloud/snapshots` overridden to `max_age_hours: 0` | `failed`, an alert raised, and the journal names that path (BD-FR-36) |
| 4 | `/mnt/data/restic-repos/cloud` renamed to `cloud.x` (as between runbook steps 5 and 6) | `Result=success`, and the journal contains `<path>: absent, skipped` (BD-FR-159); the next maintenance run fails and raises an alert (BD-FR-119) |

The non-zero device counter path of BD-FR-35 is verified by analysis (see Verification).

Scenario BD-AC-56 [V]: Scrub covers the backup filesystem (BD-FR-30 to BD-FR-32)
- Given the saved `BTRFS_SCRUB_MOUNTPOINTS` line from before step 3
- Then the line contains `/mnt/backup/btrbk` and every saved value
- And `btrfs-scrub.timer` is enabled, with a calendar of monthly or shorter

Scenario BD-AC-82 [H]: A smartd warning reaches the owner by email (BD-FR-39, BD-FR-40, BD-NFR-10)
- Given the owner temporarily adds `-M test` to the backup disk's smartd line by hand
- When the operator runs `systemctl restart smartd`
- Then within 5 min, an email containing `/dev/disk/by-id/wwn-0x500003982b7021c1` and smartd's test message arrives
- And `site.yml --tags backup_disk` removes `-M test` again

The [H] smoke rows for this area are in [backup-overview.md](backup-overview.md#acceptance-criteria) (BD-AC-80).

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| BD-FR-01 to BD-FR-05, BD-FR-11, BD-FR-24 | inspection [S] | BD-AC-04 |
| BD-FR-06 to BD-FR-08, BD-BR-03 | test [V] | BD-AC-20 (17 rows) |
| BD-FR-09 | test [V] | BD-AC-23 |
| BD-FR-10 | test [V] | BD-AC-21 |
| BD-FR-12 to BD-FR-16, BD-BR-02 | test [V] | BD-AC-22, BD-AC-23, BD-AC-20 row 16 |
| BD-FR-20 to BD-FR-22, BD-FR-26 | test [V] | BD-AC-24 |
| BD-FR-23 | inspection [S], test [V], smoke [H] | BD-AC-07, BD-AC-26, BD-AC-80 row 1 |
| BD-FR-29 | test [V] | BD-AC-26 |
| BD-FR-30 to BD-FR-32 | test [V], smoke [H] | BD-AC-56, BD-AC-80 row 10 |
| BD-FR-34, BD-FR-46, BD-BR-12 | test [V] | BD-AC-28 |
| BD-FR-35 | test [V] (healthy path); analysis (the unit fails exactly when `btrfs device stats --check` exits non-zero, which triggers `OnFailure=`) | BD-AC-55 row 1 |
| BD-FR-36, BD-FR-159 | test [V] | BD-AC-55 rows 2-4 |
| BD-FR-37, BD-FR-38, BD-FR-41, BD-FR-42 | smoke [H] (smartd needs real SMART; a VM's virtual disks lack it) | BD-AC-80 row 11 |
| BD-FR-39, BD-FR-40 | demonstration [H] | BD-AC-82 |
| BD-FR-43, BD-FR-44 | inspection [S] | BD-AC-07 |
| BD-FR-45 | inspection [S] | BD-AC-09 |
| BD-BR-01 | inspection [S] (runbook gate), demonstration [H] | BD-AC-13 row DOC-N4 |

### Non-Functional Requirements

See [backup-overview.md](backup-overview.md#non-functional-requirements) (BD-NFR-05, BD-NFR-08 and BD-NFR-10 apply here).

### Out of Scope

See [backup-overview.md](backup-overview.md#out-of-scope).

### Open Questions

None.
