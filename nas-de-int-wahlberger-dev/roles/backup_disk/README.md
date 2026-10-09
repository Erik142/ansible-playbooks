# backup_disk

Local backup disk: a dedicated 6 TB disk holding one btrfs filesystem with the
single subvolume `@btrbk`. This role mounts it, scrubs it, watches it with
smartd and checks its health daily. The disk is partitioned and formatted
exactly once, by a **separate playbook**, `backup_disk_init.yml`, that
`site.yml` never imports (BD-FR-02). This file documents the initialisation;
the `main` entry point (below) mounts the disk, scrubs it, watches it with
smartd and checks it daily.

## Does not do

- It never partitions, formats or creates a subvolume from `site.yml` or from
  the `main` entry point. Only `backup_disk_init.yml` writes to the disk.
- It never sets the `C` (no copy-on-write) attribute on the backup filesystem.
- It does not create snapshots or copy data (see the `btrbk` role).
- It does not wipe a disk that holds anything: any signature or non-zero byte
  at the ends makes the init refuse. There is no force option.

## Role variables

See `defaults/main.yml`; every variable is declared in `meta/argument_specs.yml`
(entry points `main` and `init`). `backup_disk_init_confirm` exists only as an
extra-var of the init playbook and is deliberately defined nowhere in the
repository.

## Initialise the disk (once)

Run against one host only. Always `--check` first (it evaluates every refusal
condition and writes nothing), then without it:

```sh
ansible-playbook backup_disk_init.yml \
  -e backup_disk_init_confirm=/dev/disk/by-id/wwn-0x500003982b7021c1 --check
ansible-playbook backup_disk_init.yml \
  -e backup_disk_init_confirm=/dev/disk/by-id/wwn-0x500003982b7021c1
```

The confirm value must equal `backup_disk_device` exactly. The run ends by
printing the filesystem UUID; put it into `backup_disk_uuid` (runbook step 3).
A second run on the initialised, unmounted disk changes nothing and prints the
same UUID. Test against the VM fixture first: `-i inventories/vm`.

What a real run writes: a GPT with one partition from 1 MiB to the end, then
`mkfs.btrfs -L backups`, then the subvolume `@btrbk` directly below the top
level (id 5). Nothing else, and nothing outside `backup_disk_device`.

### Initialised state

The disk counts as initialised when all three hold: GPT with exactly one
partition; that partition holds btrfs labelled `backup_disk_label`; the
filesystem has the subvolume `@btrbk` directly below its top level (only
`@btrbk` is checked). An initialised disk skips R-09 and R-10 and is not
written. To read the subvolume list the play mounts the partition
**read-only without log replay** on a temporary directory and unmounts it
again; this also happens under `--check`.

### Refusal conditions

All ten are evaluated before the first write. If any holds, the play fails
once and names every ID that holds; for R-09 it lists each signature with its
type and offset (from `wipefs --no-act`).

| ID | Condition |
|---|---|
| R-01 | `backup_disk_init_confirm` is undefined, or is not exactly equal to `backup_disk_device` |
| R-02 | The play's host list has more than one host |
| R-03 | `backup_disk_device` is not below `/dev/disk/by-id/` |
| R-04 | `backup_disk_device` does not resolve to a whole disk (`lsblk` TYPE is not `disk`, e.g. a partition) |
| R-05 | The device size differs from `backup_disk_expected_size_bytes` by more than `backup_disk_size_tolerance_percent` (default 1) |
| R-06 | The device or one of its partitions is mounted |
| R-07 | The device or one of its partitions is active swap |
| R-08 | The device or one of its partitions has a holder (LVM, MD RAID, dm-crypt) |
| R-09 | The disk is not initialised, and `wipefs --no-act` reports a signature on the device or a partition |
| R-10 | The disk is not initialised, and its first or last 1 MiB contains a non-zero byte |

If `backup_disk_device` does not exist the play also fails before any write.

### Set `backup_disk_expected_size_bytes`

Read the exact size from the host, with the disk attached and addressed by its
by-id path, and put it into the inventory:

```sh
lsblk -bdno SIZE /dev/disk/by-id/wwn-0x500003982b7021c1
```

The default is `6001175126016`. A disk of another size (R-05) is refused.

### Recover from a partial init

If the init fails after its first write, the next run refuses under R-09 or
R-10. Recovery is manual, on purpose:

1. Verify the identity: `ls -l /dev/disk/by-id/` shows the intended disk, and
   `lsblk -bdno SIZE <by-id path>` equals `backup_disk_expected_size_bytes`.
2. Make sure nothing is mounted from it, then erase the signatures by hand:
   `wipefs -a <by-id path>`.
3. Re-run the init (with `--check` first).

## Mount (`main` entry point)

Every run of the role, in this order and all before the first change:

1. `backup_disk_uuid` must be non-empty (BD-FR-20). Empty means the init has not
   been run or its UUID not recorded: the role fails naming the variable.
2. A filesystem with that UUID must be present (BD-FR-21), be btrfs, carry the
   label `backup_disk_label` and sit on a partition of `backup_disk_device`
   (BD-FR-22). The failure names the mismatching property (`fstype`, `label`
   or `device`).
3. Each `backup_disk_mounts` subvolume is probed with a temporary read-only
   mount. A filesystem without `@btrbk` fails here, naming path and subvolume
   (BD-FR-26), and `/etc/fstab` stays untouched.

Then, per `backup_disk_mounts` entry: one `/etc/fstab` line with source
`UUID=<backup_disk_uuid>`, type `btrfs` and exactly the options
`subvol=<subvol>,compress=zstd:1,noatime,nofail,x-systemd.device-timeout=<backup_disk_device_timeout>`
(BD-FR-23; template `templates/fstab-options.j2`), the mount, a check against
the **live** mount table (UUID and subvolume, else the role fails naming path
and subvolume), and mode `0700 root:root` on the mounted root directory
(BD-FR-29). The role never sets the `C` attribute and never creates or deletes
a subvolume. Under `--check` the live assertion is skipped on a first run
(nothing is mounted yet).

### Behaviour while the disk is absent (BD-BR-12)

The disk is not needed to boot: `nofail` and the 30 s device timeout let the NAS
come up and run everything else, including rest-server (its repositories are on
`/mnt/data`). Nothing is written below `/mnt/backup/btrbk` while it is not
mounted. A normal run of this role fails by design (above) until the disk is
back.

## Scrub (BD-FR-30 to BD-FR-32)

Installs `btrfsmaintenance` and edits two lines of
`/etc/sysconfig/btrfsmaintenance` in place (all other lines stay as they are):

- `BTRFS_SCRUB_MOUNTPOINTS`: every `backup_disk_mounts` path missing from the
  colon-separated list is appended; every value already there is kept. A run
  that finds all paths present changes nothing.
- `BTRFS_SCRUB_PERIOD`: set to `backup_disk_scrub_period` (default `monthly`;
  only `daily`, `weekly` and `monthly` are accepted, so the period is never
  longer than one month).

If either line changed, `btrfsmaintenance-refresh.service` regenerates the
timer, and `btrfs-scrub.timer` is enabled and started.

## smartd (BD-FR-37 to BD-FR-42)

Relies on the `smartd` role (applied earlier) for `smartmontools`, the mail hook
and `smartd.service`, and writes **one** line to `/etc/smartd.conf`, the one
starting with `backup_disk_device` (by-id path):

```
<by-id path> -a -s (S/../../7/01|L/../01/./10) -m root -M exec /usr/local/bin/smartd-notify.sh
```

- `-s` is `backup_disk_smartd_schedule`: short test Sundays 01:00, long test on
  the 1st at 10:00.
- The line goes **before** a `DEVICESCAN` line, because smartd ignores
  everything after `DEVICESCAN`. All other lines (device lines, `DEVICESCAN`)
  are never touched or removed. A hand-edited line for the same device (for
  example with `-M test`) is replaced by the managed one on the next run.
- smartd runs the hook (`-M exec`, installed by the `smartd` role) on a warning. The hook sends an email through
  Resend with the credentials from `/etc/notify-failure/notify-failure.env`
  (role `notify_failure`); subject and body
  contain the device path and smartd's message. `smartd.service` is enabled by the
  `smartd` role and restarted here when the line changed. Virtual disks (the VM fixture) have no SMART,
  so this part is only smoke-checked on the real host.

## Optional spindown (BD-FR-43, BD-FR-44)

With `backup_disk_hdparm_spindown` greater than 0 (value 0-251, the `hdparm -S`
encoding; 120 = 10 min) the role installs `backup-disk-hdparm.service`, a boot
oneshot running `hdparm -S <n> <device>`, and the smartd line gains
`-n standby` (no checks while the disk sleeps). With 0 (default) the unit file,
its enablement and `-n standby` do not exist; setting it back to 0 removes them.
`hdparm -S` changes a drive setting, not data on the disk. If the disk is absent
at boot the unit is skipped, not failed. Already-stored drive settings are not
reverted by removing the unit; power-cycle the disk or run `hdparm -S 0`.

## Daily health check (BD-D-09, BD-FR-34 to BD-FR-36, BD-FR-159)

`backup-disk-health.timer` runs `backup-disk-health.service` daily at
`backup_disk_health_on_calendar` (default `*-*-* 09:00:00`, `Persistent=true`).
The service runs `/usr/local/bin/backup-disk-health.py` (a Python script, unit
tested in `tests/unit/test_backup_disk_health.py`) and has
`OnFailure=notify-failure-immediate@%n.service`, so a failure sends an email
(the `notify_failure` role must be applied). The script is read-only: it lists
directories and runs `findmnt`, `btrfs device stats --check` and `stat`, and
writes nothing below a backup mount. It reports every finding in one run; the
journal lines start with `FAIL:` and name the path. It fails when

- a `backup_disk_mounts` path is not mounted, or is mounted from another
  filesystem UUID or subvolume than `backup_disk_uuid` and the entry's `subvol`;
- `btrfs device stats --check` exits non-zero (any error counter above 0);
- no direct child of a `backup_disk_freshness_checks` path was born (`stat -c
  %W`) within that entry's `max_age_hours`. A path that does not exist logs
  `<path>: absent, skipped` and does not fail (for example the cloud repository
  before runbook step 6).

The unit has no `RequiresMountsFor=` for the backup mount on purpose: a unit
blocked by a missing mount would not trigger `OnFailure=`, and the check exists
to fail when the disk is gone.

### Freshness model (26 h)

Backups run once a day, so each entry allows 26 h: 24 h plus 2 h slack for a
late start. `backup_disk_freshness_checks` defaults to an empty list; the
production list (btrbk `data` and `containers` snapshot directories and the
cloud restic repository's `snapshots` directory, each 26 h) is set in
`vars.yml`. `max_age_hours: 0` always fails, which is how the check is
tested on purpose. Birth time on btrfs depends on kernel and coreutils; a
child whose birth time reads 0 is not counted as fresh.

Run it by hand: `systemctl start backup-disk-health.service`, then
`journalctl -u backup-disk-health.service -n 20`.

## Skip the role while the disk is dead

The `main` entry point fails by design when the filesystem is missing. To run
the rest of the stack meanwhile:

```sh
ansible-playbook site.yml --skip-tags backup_disk,btrbk
```

Restricting the run with `--skip-tags` is the only supported way: the role has
no switch that turns the precondition checks off.
