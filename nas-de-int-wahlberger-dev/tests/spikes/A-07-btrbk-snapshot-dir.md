# Spike T-03: btrbk snapshot directory layout (BD-A-07)

Date 2026-10-09. Confidence: **verified** in a privileged `opensuse/tumbleweed` container
(Docker Desktop, kernel 6.12.76-linuxkit, arm64), btrbk 0.32.6 from the OBS `filesystems`
repo, btrfs-progs from Tumbleweed. Not yet verified on the real NAS kernel/disk: confirm in BD-AC-30.

## Decision

**A-07 holds.** btrbk keeps `<source>/.btrbk` inside each mounted subvolume (`subvol=@data`,
`subvol=@containers`) without the btrfs top level mounted. No extra mount, `storage_mounts` unchanged.

## btrbk.conf (verified working)

```
lockfile                  /run/btrbk.lock
timestamp_format          long
snapshot_create           always
snapshot_preserve_min     2d
snapshot_preserve         no
target_preserve_min       no
target_preserve           14d 8w 12m 3y

volume /mnt/data
  snapshot_dir .btrbk
  subvolume .
    snapshot_name data
    target /mnt/backup/btrbk/data

volume /mnt/containers
  snapshot_dir .btrbk
  subvolume .
    snapshot_name containers
    target /mnt/backup/btrbk/containers
```

`volume` = the mounted source subvolume path (need not be a top level); `subvolume .` = the
volume itself (`config print` shows `subvolume /mnt/data`); `snapshot_dir` is relative to the
volume. Target `/mnt/backup/btrbk` is a mount of `@btrbk` (`subvol=@btrbk`) of the second filesystem.

## Evidence (setup: two loopback btrfs images; fs A with `@data`, `@containers`, mounted `subvol=`; fs B with `@btrbk`; `/mnt/data` holds `samba/`, `restic/`, and a nested snapper-style subvolume `.snapshots` containing a file)

| Question | Result | Source |
|---|---|---|
| `btrbk -n run` passes | Yes, with `.btrbk` present: lists `+++ /mnt/data/.btrbk/data.<ts>` and `*** /mnt/backup/btrbk/data/data.<ts>` | `btrbk -c conf -n run` |
| `.btrbk` must be pre-created | **Yes.** Without it: `!!! Aborted: Failed to fetch subvolume detail for snapshot_dir`, real run exit **10**, nothing created. btrbk does not create it | `btrbk -c conf run; echo $?` -> `rc=10` |
| Owner/mode | `mkdir -m 0700`, `root:root` works (run as root); stat `700 root:root`, snapshots inside are `drwxr-xr-x` | `stat -c '%a %U:%G'` |
| Real run, first | rc 0, non-incremental `***` receive into `<target>/data/`, `<target>/containers/` | `btrbk run` |
| Incremental, second run uses first as parent | Yes: `btrfs send -p '/mnt/data/.btrbk/data.A' '/mnt/data/.btrbk/data.B' \| btrfs receive '/mnt/backup/btrbk/data/'`; target `Parent UUID` set | `btrbk -l debug run`, `btrfs subvolume show` |
| Received `Received UUID` set | Yes for all received subvolumes | `btrfs subvolume show` |
| Snapshot of `@data` excludes nested `.snapshots` and `.btrbk/*` (BD-FR-56) | **Yes.** `btrfs send` omits nested subvolumes: received `data.<ts>/` holds `.btrbk` (empty plain dir), `restic`, `samba`; **no `.snapshots`**, the file inside the snapper subvolume is absent | `ls -A` of received snapshot |
| `restic_server_data_dir` in `data` snapshot (BD-FR-161) | Yes, `restic/` present as a plain directory | same |

## Snapshot dirs vs `samba_data_dir` and `.snapshots` (BD-FR-52, BD-FR-53)

`.btrbk` is a sibling of `samba/` and `.snapshots` directly under the mount root, so it is not
at/below `/mnt/data/samba` and not at/below a `.snapshots` directory. Snapshots are nested
subvolumes of `@data` (`btrfs subvolume list -o /mnt/data` shows `@data/.btrbk/data.<ts>` next
to `@data/.snapshots`), so they are invisible to snapper's own `.snapshots` and absent from snapper
snapshots and from the next btrbk snapshot. The `.btrbk` directory itself is a plain (non-subvolume)
directory and appears empty in snapshots and received copies.

## Must-follow for T-12

1. Create `<source>/<btrbk_snapshot_dirname>` before the first run (`ansible.builtin.file`, `state: directory`, `owner: root`, `group: root`, `mode: "0700"`) for every `btrbk_sources` entry; btrbk will not.
2. Use the config above; `volume <source path>` + `subvolume .`, `snapshot_dir <btrbk_snapshot_dirname>` (relative).
3. Target directories `<btrbk_target_dir>/<source name>/` must exist before the run (created in the experiment; not tested without them).
4. Retention caveat (BD-FR-57/58 test design): with `target_preserve 14d 8w 12m 3y`, `target_preserve_min no`, an extra snapshot taken the same day is created source-side but **not sent** (debug: `Preserving 0/1 items`), rc 0. Multiple runs per day therefore yield one received copy per day. For tests of incremental behaviour (T-27 to T-30, BD-AC-30) use `--override target_preserve_min=1h` or runs on different days.
5. Run 2 within one minute gets suffix `_1` with `timestamp_format long`; harmless.

## Not verified

Interrupted-transfer behaviour (BD-FR-62/63), `lockfile` concurrency (BD-FR-61), and kernel-specific behaviour on the NAS. Test-environment note: `--rm` containers leak loop devices; run `losetup -D` in a privileged container (and `umount`/`losetup -D` at script end) to avoid `device node /dev/loopN is lost`.

## Reproduce

Privileged `docker run --rm --privileged opensuse/tumbleweed`: add the `filesystems` repo, install `btrfsprogs btrbk`, `truncate -s 600M` two images, `mkfs.btrfs`, `losetup`, create subvolumes via a temporary top-level mount, remount with `-o subvol=@data` etc., write the config above, then `btrbk -c ... -n run`, `run`, `-l debug run`.
