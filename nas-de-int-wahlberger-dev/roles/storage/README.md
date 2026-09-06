# storage

Mounts this host's two separately mounted disks — `/mnt/containers` and
`/mnt/data` — by filesystem UUID, persisted in `/etc/fstab` via
[`ansible.posix.mount`](https://docs.ansible.com/ansible/latest/collections/ansible/posix/mount_module.html)
(`state: mounted`, which both writes the fstab entry and (re)mounts if
needed). Codifies what was already hand-set-up on the host — see
`roles/podman/tasks/main.yml` and `roles/samba/tasks/main.yml`, which
already `assert` these mountpoints exist before using them.

## What this role does NOT do

Both filesystems are **already formatted btrfs, with the subvolume already
created** (`@containers` and `@data`) and already holding real data. This
role does not format a device or run `btrfs subvolume create` — only
`/etc/fstab` + mount state. Different UUIDs, not the same filesystem twice:
these are two independent btrfs filesystems (different physical disks),
each with a single named subvolume, not two subvolumes of one filesystem —
that's why each entry in `storage_mounts` carries its own `uuid`.

## Role variables

See `defaults/main.yml`. `storage_mounts` is a list of `{path, uuid,
subvol}`; `storage_mount_options` (default `compress=zstd,noatime`) is
appended to every entry's `subvol=` option.

## Snapshots

See the separate [`snapper`](../snapper/README.md) role — btrfs snapshots
of these same two subvolumes.
