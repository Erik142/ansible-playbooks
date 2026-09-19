# journal_archive

Makes the systemd journal survive reboots on this host, without wearing out
its SD card.

## Why not just create /var/log/journal, like the other two hosts

`cloud-wahlberger-dev` and `nas-de-int-wahlberger-dev`'s `common` role
enables persistent journald the standard way: create `/var/log/journal`
and journald auto-detects it, then writes every log line straight to disk
for the rest of that boot. That's the right call there — both are on real
disks (SSD/proper storage).

This Pi boots off an SD card, and SD cards wear out from exactly this kind
of constant small-write traffic. Without this role, journald defaults to
volatile storage (`/run/log/journal`, tmpfs) — zero SD writes, but the
entire journal is gone the moment the host reboots. That gap is what made
a real incident (a missed reboot-notification email) undiagnosable: after
the reboot, `journalctl --list-boots` only showed the current boot, so
whatever `reboot-notify.service`'s `ExecStop=` logged during the actual
shutdown was unrecoverable.

## What this role does instead

journald keeps using volatile (tmpfs) storage — never touches
`/var/log/journal` itself. A separate directory,
`/var/log/journal-archive`, holds the persistent copy, kept in sync by
`rsync` (touches only what changed, so most syncs write nothing) at three
points instead of continuously:

- **`journal-archive-flush.timer`** — every 30 minutes, tmpfs → disk.
- **`journal-archive-shutdown.service`** — right before every
  shutdown/reboot, tmpfs → disk. Same systemd idiom
  [`reboot_notify`](../reboot_notify/README.md) uses for its own
  before-shutdown email: a oneshot unit with `ExecStart=/bin/true`,
  `RemainAfterExit=true`, and `Before=shutdown.target reboot.target
  halt.target`, so its `ExecStop=` runs as part of every shutdown
  transaction. No `After=network-online.target` needed here — this is pure
  local disk I/O. Also `Before=reboot-notify.service`, so this unit stops
  (and flushes) *after* reboot-notify's own `ExecStop=` has already logged
  its outcome — without that explicit ordering, both units only being
  `Before=` the same targets leaves their relative order unspecified, and
  this flush could run first and miss exactly the log line this role
  exists to capture.
- **`journal-archive-restore.service`** — once at boot, disk → tmpfs, so
  `journalctl` shows history from previous boots too, exactly like real
  persistent storage would, just without journald ever writing to the SD
  card during normal operation.

## Role variables

None. Both the archive path and the flush interval are fixed values in the
templates — see `templates/`.

## Manual test

```sh
sudo /usr/local/bin/journal-archive-sync.sh to-disk
sudo journalctl --directory=/var/log/journal-archive --list-boots
```

To exercise the shutdown hook without actually rebooting:
`sudo systemctl stop journal-archive-shutdown.service` (restart it
afterwards so it's ready for a real shutdown:
`sudo systemctl start journal-archive-shutdown.service`).
