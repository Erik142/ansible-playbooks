# storage

Mounts an existing external USB drive — referenced by its stable
`/dev/disk/by-id/...` path, not `/dev/sdX` (which can renumber across
reboots/USB re-enumeration) — and creates a `containers` subdirectory within
it for `podman_data_dir`. The drive already holds unrelated data; this role
does **not** format it, and only ever touches the `containers` subdirectory.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `storage_device` | `/dev/disk/by-id/ata-WDC_WD50NDZW-...-part1` | Stable path to the partition. |
| `storage_mount_path` | `/mnt/data` | Where to mount it. |
| `storage_fstype` | `""` (**required**) | The filesystem already on the drive — check with `sudo blkid {{ storage_device }}` or `lsblk -f`. Not guessed; getting this wrong fails the mount loudly rather than risking the existing data. |
| `storage_mount_options` | `defaults,nofail,x-systemd.device-timeout=10` | `/etc/fstab` options. |

## Why `nofail`

This matters specifically because it's a **USB** drive: without `nofail`, a
missing or unplugged drive at boot blocks the *entire* boot — systemd's
`local-fs.target` waits on every fstab entry that isn't marked `nofail`,
turning "USB cable came loose" into "server won't boot" instead of just
"container data isn't there yet." `x-systemd.device-timeout=10` keeps that
wait short if the drive really is missing, rather than hanging for the
default ~90 seconds.

## Ordering

Runs before `podman` in `site.yml` — `podman_data_dir` points inside this
mount (`{{ storage_mount_path }}/containers`), so the mount must exist first.
