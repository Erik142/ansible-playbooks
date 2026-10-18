# Garage V3 results (T-18)

Run on the qemu fixture, 2026-10-18 (guest clock moved one day on by the second btrbk run: 2026-10-19). Spec v1.3. VM state of V2 kept (no reset). Fake fixture secrets only.
Scripts: `garage-v3-run.sh` (AC-53, 21, 68, backup run 1 under upload load, AC-20, 04, 45), `garage-v3-secrets.sh` (AC-67), `garage-v3-restore.sh` (AC-55, AC-56, second run), helpers in `garage-v3-guest.sh`.

| Scenario | Result | Evidence |
|---|---|---|
| GS-AC-53/1 | PASS | snapshot_dir .btrbk-garage: rc=2, names garage and the value, btrbk.conf unchanged |
| GS-AC-53/2 | PASS | snapshot_dir /mnt/data/samba/Delat/.btrbk-garage: rc=2, names garage and the value, btrbk.conf unchanged |
| GS-AC-53/3 | PASS | snapshot_dir /mnt/data/garage/.snap: rc=2, names garage and the value, btrbk.conf unchanged |
| GS-AC-53/4 | PASS | snapshot_dir /mnt/containers/.btrbk-garage: rc=2, names garage and the value, btrbk.conf unchanged |
| GS-AC-21/garage | PASS | rc=2, message names /mnt/data/garage |
| GS-AC-21/garage-absent | PASS | /mnt/data/garage still does not exist |
| GS-AC-21/garage-meta | PASS | rc=2, message names /mnt/containers/garage/meta |
| GS-AC-21/garage-meta-absent | PASS | /mnt/containers/garage/meta still does not exist |
| GS-AC-68//mnt/containers/garage/secrets | PASS | rc=2, message names the path, path afterwards absent |
| GS-AC-68//mnt/data/garage-secrets | PASS | rc=2, message names the path, path afterwards absent |
| GS-AC-20/run1 | PASS | btrbk.service Result=success, uploads ran during the run (count0=57 count1=69 ) |
| GS-AC-20/ts-pair | PASS | garage.20261018T1604 and garage-meta.20261018T1604, same <ts> (GS-A-17) |
| GS-AC-20/targets | PASS | received garage.20261018T1604 and garage-meta.20261018T1604 exist on the backup disk |
| GS-AC-20/meta-entries | PASS | received garage-meta.<ts> lists the same top-level entries as the source snapshot |
| GS-AC-20/no-inside | PASS | no .btrbk inside the Garage subvolumes |
| GS-AC-20/modes | PASS | 700 root:root on both snapshot directories |
| GS-AC-04/run1 | PASS | stub dirs present, non-directory entries below stubs: 0, secret files in containers.20261018T1604: 0 |
| GS-AC-45/V | PASS | backup-disk-health.service exit 0 (Result=success) with freshness paths garage and garage-meta |
| GS-AC-67/fsroot | PASS | findmnt FSROOT of /var/lib/garage/secrets = /@/var |
| GS-AC-67/rootid | PASS | secrets root id 258 (fs 5cf9e5f0-b2f5-4fbb-898a-9a047b0c2be7) differs, per filesystem, from /mnt/data=256 /mnt/containers=256 /mnt/data/garage=258 /mnt/containers/garage/meta=258 |
| GS-AC-67/find | PASS | no rpc_secret/admin_token in snapper snapshots (created for: containers data ), btrbk or backup directories (found 0) |
| GS-AC-55/restore-copy | PASS | garage stopped, data and metadata subvolumes restored from <ts>=20261018T1604 (rc=0) |
| GS-AC-55/secrets | PASS | ansible rc=0; secret modes: 400 garage:garage,400 garage:garage, |
| GS-AC-55/status | PASS | garage status exit 0, 0s after the start (limit 60) |
| GS-AC-55/object | PASS | selftest/up reads back with sha256 S (d2647014a332e5181506f89c5865e8d5e604a7d4c9fe092cb0f78fe81152c1fd vs d2647014a332e5181506f89c5865e8d5e604a7d4c9fe092cb0f78fe81152c1fd) |
| GS-AC-55/block-errors | PASS | block list-errors prints only the header line: [Hash  RC  Errors  Last error  Next try] |
| GS-AC-56/start | PASS | snapshots 1.9s apart (limit 10), restore rc=0, garage.service active, garage status exit 0 after 0s |
| GS-AC-56/A | PASS | A reads back with its original sha256 (45313f73b883b4e82d95c29cf80f41593bf1dff9dee8bdb690e11130ad9ee1be vs 45313f73b883b4e82d95c29cf80f41593bf1dff9dee8bdb690e11130ad9ee1be) |
| GS-AC-56/B | PASS | GET/HEAD of B returns 404 (404) |
| GS-AC-20/run2-after-restore | PASS | btrbk.service Result=success after the restore; garage.20261019T1610 / garage-meta.20261019T1610 same <ts>, received |
| GS-AC-04/run2 | PASS | later run: data.20261019T1610 holds 1 stub(s) in .btrbk-garage, non-directory entries below stubs: 0 |

Notes:
- Preparation (not a scenario): the backup disk was blank on this VM, so `backup_disk_init.yml` and `tests/vm/stack.sh` were run first (second stack run `changed=0`); `btrbk.conf` shows the four volumes in the order data, containers, garage-meta, garage (production `btrbk_sources` via `gen-prod-vars.py`; garage-meta first, GS-FR-79). Roles ran with Erik's uncommitted `backup_disk` health-script changes in the working tree.
- GS-AC-20 run 1 ran while three parallel uploaders wrote 64 KiB objects to `sstate` (object count 57 -> 69 -> 75 around the run): live LMDB snapshot (GS-R-03), pairing `<ts>` `20261018T1604` for both sources (GS-A-17; the `long` timestamp has minute resolution).
- GS-AC-45 [V]: the VM fixture's `backup_disk_freshness_checks` has no Garage paths, so the check was run after applying the production list (data, containers, restic cloud, garage, garage-meta) as extra var; health service exit 0.
- GS-AC-67 deviation (spec issue, report to requirements-engineer): btrfs root IDs are unique only per filesystem. `/var/lib/garage/secrets` (root fs) has ID 258, equal to the ID of `/mnt/data/garage` (258, on the `@data` filesystem); `/mnt/data` and `/mnt/containers` are both 256 on their own filesystems. The scenario text "root ID differs from every ... path" cannot hold literally; the script compares (filesystem UUID, root ID). All differ on that basis.
- GS-AC-55 / GS-AC-56 restore steps (for T-21, the README text): the backup disk is a different btrfs filesystem, so `btrfs subvolume snapshot` of `/mnt/backup/btrbk/garage/garage.<ts>` fails with "Invalid cross-device link". The working steps: (1) `btrfs send <backup snapshot> | btrfs receive <staging dir on the live filesystem>` for both sources (staging `/mnt/data/.restore-stage`, `/mnt/containers/.restore-stage`), (2) `systemctl stop garage.service`, (3) `mv` the live `/mnt/data/garage` and `/mnt/containers/garage/meta` aside, (4) `btrfs subvolume snapshot <received copy> <live path>` (writable) for both, (5) delete the staging copies, (6) `ansible-playbook site.yml --tags garage` (re-renders both secret files, 400 garage:garage), start the service, `garage status`, `garage block list-errors`, (7) delete the moved-aside subvolumes after the checks. `garage.toml` lives outside both subvolumes, so it is untouched. The role README must say send/receive, not snapshot.
- GS-AC-55 timing: the role itself started the service during the `--tags garage` run, so `garage status` was ready at once (0 s) after the explicit `systemctl start`; the 60 s bound is met with margin but not measured from a cold start.
- GS-AC-56: A restored with its sha256, B 404; the two snapshots were 1.9 s apart.
- Incident during the run (test-script bug, not a role defect): the first restore attempt used `btrfs subvolume snapshot` across filesystems, failed, and my script then deleted the moved-aside live subvolumes. The live store was therefore empty for a while; the V2 user state (layout, buckets, key, 10 MiB quota on private-test, lifecycle rule on sstate) was recovered from the backup pair `20261018T1604` and verified afterwards (quota and `expire-tmp` rule present, `block list-errors` clean). `garage-v3-guest.sh` now only deletes moved-aside copies after a successful restore.
- The next btrbk run after the restore (day +1) succeeded: both Garage sources replicated with a new same-`<ts>` pair; `data.<ts>/.btrbk-garage` held one empty stub for the earlier Garage snapshot (GS-AC-04 later-run bullet).
- Not run: GS-AC-04 / 20 on production hardware; `backup-disk-health` real freshness over days (T-26).
- Left on the VM for T-19: Garage running with the restored store (sstate holds `selftest/up`, the K object and the `load/*` objects), guest clock at 2026-10-19, backup disk initialised, backup stack applied.
