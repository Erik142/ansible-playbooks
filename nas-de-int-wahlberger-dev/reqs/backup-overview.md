## Feature: Local backup disk, btrbk, and NAS-hosted restic REST server (overview)
status:            draft
priority:          must
version:           3.0
quality-pillars:   4,5,4,4,5,5,4,5
quality-reviewed:  2026-10-09

This feature is split across five files (see [index.md](index.md)).

| File | Holds |
|---|---|
| [backup-overview.md](backup-overview.md) (this file) | Problem, terms, constraints, actors, decisions, contract changes, assumptions; cross-cutting FRs, BRs and scenarios; NFRs; out of scope; decision log |
| [backup-disk-init.md](backup-disk-init.md) | Init playbook, VM gate, `backup_disk` role (mount, scrub, smartd, health check) |
| [backup-btrbk-and-db-dump.md](backup-btrbk-and-db-dump.md) | btrbk replication, database dumps |
| [backup-restic-server.md](backup-restic-server.md) | rest-server, firewall, cloud repository maintenance, prune guard |
| [backup-cutover-and-decommission.md](backup-cutover-and-decommission.md) | Runbook, cut-over flags, retirement of the old restic job, cloud changes, wiring, documentation, test fixtures |

ID convention: every ID carries the prefix `BD-` (for example BD-FR-01 or BD-AC-01), so these IDs never collide with the Tandoor feature's IDs ([tandoor-replaces-mealie.md](tandoor-replaces-mealie.md)). The ID map in [index.md](index.md#id-map) gives the file of every ID. Deleted IDs are kept as "[Deleted]" entries and are not reused.

### Problem Statement

Today both nightly off-host backups go to pi-de-int-wahlberger-dev. The NAS pushes restic snapshots of the Samba share and `/mnt/containers` there (htpasswd user `nas`), and cloud-wahlberger-dev pushes `/opt/podman` there (user `cloud`). The owner has installed a dedicated, empty HDD in the NAS and decided it replaces the Pi as the backup target for both hosts:
- The NAS's own data (`/mnt/data`, `/mnt/containers`) is replicated to the new disk as read-only btrfs snapshots by btrbk. The disk keeps them for 14 days, 8 weeks, 12 months and 3 years, independent of the snapper history on the source disks.
- The restic REST server for cloud-wahlberger-dev moves from the Pi to the NAS. Its repositories live on the NAS's data disk and reach the backup disk through the same nightly btrbk run. It runs in append-only mode, so a compromised cloud host cannot delete its own backups, and retention is applied on the NAS instead.

The backup disk holds only btrbk copies. It sits in the same chassis as the disks that hold the household's only copy of its data, so no automated run is allowed to format a disk. Formatting is a separate, explicit, human-run operation. It is proven first on a disposable VM, and it refuses any disk that is not exactly the expected, empty device. The Pi and its repositories stay untouched; retiring them is a separate follow-up.

Terms:
- **Backup disk**: the HDD `/dev/disk/by-id/wwn-0x500003982b7021c1`, enumerated as `/dev/sdc` today (the `sdX` name is never used). It is 6001175126016 bytes (BD-A-16).
- **Backup filesystem**: the btrfs filesystem labelled `backups` on the backup disk's single partition. Its only subvolume, `@btrbk`, is mounted at `/mnt/backup/btrbk`.
- **Mounted**: a path P counts as mounted when `findmnt -no UUID,OPTIONS P` reports two things:
  - the UUID of P's configured filesystem: `backup_disk_uuid` for a `backup_disk_mounts` path, or the `storage_mounts` UUID for `/mnt/data` and `/mnt/containers`;
  - a `subvol=` option equal to P's configured subvolume.

  A plain directory on the root filesystem at P does not count as mounted, and neither does a different filesystem or subvolume.
- **Init playbook**: `backup_disk_init.yml`, the only code path that writes a partition table, filesystem or subvolume to the backup disk.
- **Initialised state**: defined by BD-BR-02.
- **Normal run**: any `ansible-playbook site.yml` invocation, with or without `--tags`/`--skip-tags`.
- **Cut-over flags**: `backup_disk_enabled` and `restic_backup_decommission_enabled` in the NAS `vars.yml`. Both are `false` at the feature commit. The first becomes `true` in runbook step 3, the second in step 5.
- **btrbk run**: one activation of `btrbk.service`.
- **Dump step**: `db-dump.service`, pulled in before btrbk starts. It writes `pg_dump` files of Paperless-ngx, Immich and Tandoor and an `sqlite3 .backup` copy of Forgejo's DB.
- **Crash-consistent copy**: a btrfs snapshot of live files. It equals the on-disk state after a power loss.
- **Dump**: a transactionally consistent export (`pg_dump`, `sqlite3 .backup`).
- **Cloud repository**: `<restic_server_data_dir>/cloud`, by default `/mnt/data/restic-repos/cloud`. This is a plain directory inside the `@data` subvolume, outside `samba_data_dir` (BD-D-08). With `--private-repos`, user `<u>` maps to `<data dir>/<u>`.
- **Maintenance run**: one activation of `restic-server-maintenance.service`, which runs forget, prune and check locally on the cloud repository.
- **Health check**: `backup-disk-health.service`, started daily by `backup-disk-health.timer`.
- **VM fixture**: a disposable openSUSE Tumbleweed VM that is not nas, cloud or pi, described by `inventories/vm/`. Its disks:
  - a btrfs root disk;
  - two virtual disks holding btrfs `@data` and `@containers`, mounted at `/mnt/data` and `/mnt/containers` with snapper configs `data` and `containers`;
  - a spare virtual disk with a `/dev/disk/by-id/` path, used as the backup disk;
  - one scratch virtual disk.

  It also runs a fixture Postgres container and a fixture SQLite file. The VM is its own restic client.
- **Fixture overrides**: the values in `inventories/vm/group_vars/all/` that replace production values:
  - `backup_disk_device` and `backup_disk_expected_size_bytes`;
  - `storage_mounts`;
  - `db_dump_postgres` (a single `fixture` entry) and `db_dump_forgejo_db_path`;
  - `restic_server_allowed_sources` (the VM network's CIDR plus a dedicated test Podman network CIDR);
  - test values for `restic_server_clients`, `restic_server_maintenance_repo_password` and `notify_failure_resend_api_key`;
  - `backup_disk_freshness_checks`;
  - both cut-over flags set to `true`, except where a scenario sets them.
- **Alert raised**: on [V], the `notify-failure-immediate@<unit>.service` (or `notify-failure@`) instance for the failing unit ran (`journalctl`). On [H], the email arrives at `notify_failure_to_address`.
- **[S] / [V] / [H]**: where a scenario runs.
  - [S]: static, in the repository.
  - [V]: on the VM fixture.
  - [H]: on production. [H] scenarios are smoke checks only: read-only inspections and normal production runs. They inject no faults.

Constraints (given, not re-evaluated here):
- BD-C-01: The conventions in `nas-de-int-wahlberger-dev/CLAUDE.md` apply:
  - FQCN; ansible-core 2.16 module names.
  - Self-contained roles with `meta/argument_specs.yml` and `README.md`, and no `meta/main.yml` dependencies.
  - Role-prefixed variables.
  - `community.general.zypper`; firewalld.
  - Quadlets through the `container` role.
  - ansible-lint `production` profile.
- BD-C-02: Every secret lives in Ansible Vault, surfaced in `vars.yml` as `"{{ vault_<key> | default('') }}"`.
- BD-C-03: In this cycle, no playbook runs against nas, cloud or pi. [S] checks run now. Runs against the VM fixture are allowed now, and every [V] scenario must pass before production runbook step 2 (BD-BR-01). [H] scenarios run during and after the cut-over.
- BD-C-04: Owner decisions:
  - Roles `backup_disk`, `btrbk` and `restic_server`.
  - GPT with a single partition, `mkfs.btrfs -L backups`.
  - The backup disk holds only `@btrbk`. Restic repositories live on a main disk and reach the backup disk through btrbk (2026-10-09).
  - Mount by UUID with `compress=zstd:1,noatime`; no `nodatacow`.
  - btrbk rather than snbk, for an independent target retention.
  - rest-server `docker.io/restic/rest-server:0.14.0`, with `--private-repos` and `--append-only` (server-wide).
  - bcrypt htpasswd; fixed non-root user; `:Z` volume.
  - Port 8000/tcp allowed only from 10.10.0.0/16 (home LAN) and 10.243.0.0/16 (ZeroTier, cloud's only path; 2026-10-09).
  - NAS-side forget/prune/check with keep 7 daily, 4 weekly, 6 monthly.
  - Q1: btrbk proceeds after a failed dump.
  - Q2: btrbk from OBS `filesystems`.
  - Q3: cloud runs at 04:30.
  - The 100 GiB `--max-size` is sufficient.
- BD-C-05: Crash-consistent copies of Postgres, SQLite and restic repository files are accepted as backups.

The production cut-over runbook (primary flow, steps 0-7) is in [backup-cutover-and-decommission.md](backup-cutover-and-decommission.md#primary-flow).

Decisions (taken by this spec unless marked as owner decisions; the owner can override any of them):
- BD-D-01: `roles/restic_backup/` is deleted.
  - A `restic_backup_decommission` role removes the old units, script and env files once `restic_backup_decommission_enabled` is `true` (step 5), so the old job runs until the first btrbk run has succeeded.
  - The Pi's `nas` repository stays as is, frozen. `vault_restic_backup_repo_password` and `vault_restic_backup_rest_server_password` stay in Vault for restores from it.
- BD-D-02: The dumps move to a new role `db_dump` and are written to `/mnt/containers/db-dumps`, which btrbk snapshots. A failed dump raises an alert and does not stop btrbk (owner Q1).
- BD-D-03: btrbk is installed from OBS `filesystems/openSUSE_Tumbleweed` (owner Q2):
  - GPG checking on;
  - the signing key pinned by fingerprint;
  - priority 150, so packages present in OSS keep coming from OSS.

  A pinned upstream script is a fallback documented in the README only.
- BD-D-04: Initialisation is hardened:
  - only the init playbook does it;
  - the confirm value can come only from an extra-var;
  - `--check` writes nothing;
  - no force flags are used;
  - the disk's identity is checked by its by-id path and size;
  - the disk must be empty (refusal table BD-BR-03).
- BD-D-05: The backup filesystem is mounted with `nofail` and a 30 s device timeout. Mount guards follow BD-BR-04:
  - Ansible-time checks read the live mount table;
  - units declare `RequiresMountsFor=`.

  `btrbk.service` depends on the backup disk. `restic-server.service` and `restic-server-maintenance.service` depend only on `/mnt/data`. A unit blocked by a failed mount does not trigger `OnFailure=` (BD-A-19), so the health check raises the alert (BD-D-09).
- BD-D-06: The `firewall` role gains `firewall_rich_rules`. Production holds one rule per `restic_server_allowed_sources` entry (10.10.0.0/16 and 10.243.0.0/16). The port is not added to `firewall_allowed_ports`, which allows every source. The rules are not gated by a cut-over flag and apply from the feature commit. This is harmless, because nothing listens on port 8000 until step 5.
- BD-D-07: cloud gains `restic_backup_forget_enabled` (role default `true`), which is set to `false` at step 7, because append-only rejects forget and prune. cloud keeps its nightly `restic check`.
- BD-D-08: Repository location (owner directive 2026-10-09; the path is chosen by this spec, and the owner can override `restic_server_data_dir`). The backup disk holds only `@btrbk`. Restic repositories live at `/mnt/data/restic-repos`, a plain directory inside `@data`.
  - It sits outside `samba_data_dir` (`/mnt/data/samba`), `/mnt/data/.snapshots` and `/mnt/data/.btrbk`.
  - Rationale: capacity (the data disk is the larger main disk), and the NVMe `/mnt/containers` stays reserved for containers.
  - Consequences:
    - the existing snapper `data` config and the nightly btrbk `data` run capture the repository, so no extra snapper config is needed;
    - `:Z` relabels only that directory tree, never the Samba share's labels or read-only snapshot subvolumes (BD-FR-160).
- BD-D-09: The health check runs daily at 09:00. It fails, and so raises an alert, on any of these:
  - a backup mount that is not mounted;
  - a non-zero btrfs device error counter;
  - a stale btrbk target or cloud repository (no new entry within 26 h).
- BD-D-10: btrbk runs at 01:30, before the NAS rebootmgr window (03:00-04:00).
- BD-D-11: Maintenance runs at 06:00 (accepted by the owner).
- BD-D-12: cloud runs at 04:30 (owner Q3).
- BD-D-13: Cut-over flags: `backup_disk_enabled` (step 3) and `restic_backup_decommission_enabled` (step 5) on the NAS, and the two step-7 variables on cloud. With them, the feature commit can be merged and applied before the cut-over.
- BD-D-14: Maintenance run identity:
  - systemd `User=` and `Group=` are set to `restic_server_user`, so every file the run writes belongs to that account;
  - the password reaches restic only through `EnvironmentFile=`, which systemd reads as root, so the file can be `0600 root:root`.
- BD-D-15: Prune guard (BD-BR-07): the maintenance run prunes only when every snapshot's recorded time is within 6 h of its file's NAS-side modification time. Recovery from a bad prune uses snapper `data` snapshots or btrbk copies, restored with mtime-preserving copies (DOC-O7).
- BD-D-16: rest-server runs with `--max-size` of 100 GiB, confirmed sufficient by the owner.
- BD-D-17: Every [V] scenario passes before the production init (BD-BR-01).

Contract changes to existing behaviour:
- BD-CC-01: The NAS stops pushing restic snapshots to the Pi from runbook step 5. The Pi's `nas` repository is frozen.
- BD-CC-02: Tandoor FR-33/34/35/36/80/81, NFR-10 and AC-29/30/31/53 are superseded by BD-FR-51, BD-FR-65, BD-FR-71, BD-FR-74, BD-FR-75 and BD-FR-57; the Tandoor file carries a marker on each. Tandoor FR-81 is reversed by BD-FR-75. Tandoor NFR-07 is now met by BD-NFR-05.
- BD-CC-03: The Tandoor DB-password rotation (Tandoor FR-57, AC-12 row FR-57, AC-42) uses `--tags tandoor,db_dump`. Tandoor AC-06 covers `db_dump_credentials_dir` instead of `restic_backup_staging_dir`.
- BD-CC-04: Dumps move from `/var/lib/restic-backup/` to `/mnt/containers/db-dumps/`. Their credentials move to `db_dump_credentials_dir`. `restic_backup_*` dump variables become `db_dump_*`.
- BD-CC-05: Raw Postgres data directories and Forgejo's live `forgejo.db*` are now backed up as crash-consistent copies.
- BD-CC-06: The NAS gains one host-listening port, `restic_server_port` (8000/tcp), and one firewalld rich rule per allowed source CIDR (two in production).
- BD-CC-07: cloud-wahlberger-dev changes in four ways:
  - its schedule moves from 03:30 to 04:30 at the feature commit;
  - it gains `restic_backup_forget_enabled`;
  - at step 7 its target becomes `nas.de.int.wahlberger.dev`, without forget or prune;
  - its 7/4/6 retention is then applied by the NAS.
- BD-CC-08: Changes to existing NAS roles:
  - `firewall` gains `firewall_rich_rules`;
  - `disk_space` stops reporting usage for a path that is not a mount point;
  - the `snapper` role is unchanged, but snapshots of its `data` config now also contain the cloud repository, including pruned packs, until they expire (BD-A-09).
- BD-CC-09: `notify_failure` wiring changes. `restic-backup.service` is removed. Added: `btrbk.service`, `db-dump.service`, `restic-server.service`, `restic-server-maintenance.service`, `backup-disk-health.service` and the smartd hook.

Assumptions (each names the scenario that detects a wrong assumption):
- BD-A-01: Tumbleweed OSS has no `btrbk`, and OBS `filesystems/openSUSE_Tumbleweed` has `btrbk-0.32.6` (repository index checked 2026-10-09). BD-AC-29 and BD-AC-80 re-check.
- BD-A-02: Tumbleweed OSS ships `btrfsmaintenance` 0.5.2, `smartmontools` 7.5, `hdparm`, `restic` 0.19.1 and `python313-passlib`/`python314-passlib`. The passlib package must match Ansible's interpreter. BD-AC-40 detects a mismatch.
- BD-A-03: `--append-only` rejects every DELETE except on `locks/`. BD-AC-46 and BD-AC-81 detect a difference.
- BD-A-04: Verified by the owner on 2026-10-09: cloud reaches the NAS only through ZeroTier, from 10.243.0.0/16, and home-LAN clients come from 10.10.0.0/16. BD-AC-81 confirms both in production.
- BD-A-05: It is not verified that firewalld zone rules filter traffic to a Podman-published port, because DNAT traffic can bypass them. BD-FR-111 must hold either way; if a bypass is found, `restic-server` switches to host networking. BD-AC-45 detects a bypass.
- BD-A-06: The rest-server 0.14.0 entrypoint runs under a non-root `User=` that owns `/data` and the htpasswd file. BD-AC-39 detects a failure.
- BD-A-07: btrbk can keep its snapshot directory inside each mounted source subvolume (`<source>/.btrbk`) without the top level being mounted. Otherwise the implementation adds that mount without changing `storage_mounts`. BD-AC-07 and BD-AC-30 detect a problem.
- BD-A-08: `db_dump` reuses the container, database and user names of today's `restic_backup` defaults.
- BD-A-09: Capacity. The cloud repository (limited to 100 GiB by `--max-size`) lives on `@data`, so it holds space in two places:
  - on `@data`: the live repository, plus pruned packs held by snapper `data` snapshots (up to 2 years: 12 monthly and 2 yearly) and by btrbk source snapshots (2 days);
  - on the backup disk: btrbk copies of `@data` (including the repository) and `@containers` (14d 8w 12m 3y).

  Runbook step 1 stops unless:
  - the free space on `/mnt/data` is at least 3x the Pi's cloud repository size;
  - the used space of `/mnt/data` + `/mnt/containers` + the Pi's cloud repository is at most 50 % of the backup disk.

  `disk_space` alerts at 85 % on `/mnt/data` and `/mnt/backup/btrbk`.
- BD-A-10: The NAS's restic 0.19.x prunes cloud's repository without changing its format version. BD-AC-81 detects a problem.
- BD-A-11: Under SELinux:
  - the host-side maintenance run can access the `:Z`-labelled repository directory;
  - the relabel leaves the context of `samba_data_dir` unchanged.

  BD-AC-40 and BD-AC-48 detect a problem.
- BD-A-12: Only three things access the backup disk: the nightly btrbk run, the monthly scrub and the smartd self-tests. With spindown on (BD-FR-43), the disk therefore sits in standby most of the day, and `-n standby` (BD-FR-44) keeps smartd from waking it.
- BD-A-13: The NAS's `vault_restic_server_cloud_htpasswd_password` takes the Pi's current `vault_restic_server_cloud_htpasswd_password` value, so cloud's vault does not change.
- BD-A-14: The Immich DB (`/mnt/containers`) and library (`/mnt/data`) are snapshotted seconds apart and are not consistent with each other; this is accepted.
- BD-A-15: The backup filesystem uses the btrfs-progs default profile.
- BD-A-16: Verified by the owner on 2026-10-09: `lsblk -bdno SIZE /dev/sdc` prints `6001175126016`, the default `backup_disk_expected_size_bytes`. That the first and last 1 MiB read as zeros is still checked in runbook step 1.
- BD-A-17: The `filesystems` signing key has fingerprint `B1FB53748720472205FA601998C97FE7324E6311` ("filesystems OBS Project <filesystems@build.opensuse.org>") and expires 2027-05-07. It was fetched over HTTPS from download.opensuse.org on 2026-10-09.
  - It is cross-checked with `osc signkey filesystems` in runbook step 4 (DOC-N7).
  - On expiry, `zypper refresh` of that repository fails; renewal follows DOC-O11. There is no automatic alert.
- BD-A-18: Closed by the owner on 2026-10-09: the 100 GiB `--max-size` is sufficient for cloud.
- BD-A-19: A start job that fails because a `RequiresMountsFor=` mount cannot be mounted ends with result `dependency` and does not trigger `OnFailure=`. BD-AC-28 confirms.
- BD-A-20: btrfs reports file birth time (`stat -c %W` non-zero). BD-AC-55 detects a problem.
- BD-A-21: A restic client can set any snapshot time (`restic backup --time`). This is the threat behind BD-BR-07; BD-AC-47 uses it.
- BD-A-22: The 01:30 btrbk snapshot of `@data` captures the cloud repository crash-consistently.
  - Under normal schedules no cloud write (04:30) or prune (06:00) runs at 01:30.
  - If one overlaps (a catch-up after downtime), restic ignores unreferenced partial pack files, and `restic check` after a restore detects other damage (DOC-O7).

### Actors

| Actor | Human/System | Description |
|---|---|---|
| Owner/operator (Erik) | Human | Runs the VM tests, the init playbook, the playbooks and the runbook; holds Vault (1Password) |
| Ansible control node | System | Operator laptop or Semaphore; ansible-core 2.16 |
| NAS host | System | nas.de.int.wahlberger.dev: Tumbleweed, firewalld zone `public`, rootful Podman, snapper (`root`, `data`, `containers`), rebootmgr window 03:00-04:00 |
| VM fixture | System | Disposable test VM (see Terms) |
| Backup disk | Hardware | `/dev/disk/by-id/wwn-0x500003982b7021c1`, empty before the cut-over |
| btrbk, dump step, health check | System | `btrbk.service`, `db-dump.service`, `backup-disk-health.service` |
| rest-server, maintenance job | System | Container `restic-server`; `restic-server-maintenance.service` |
| cloud-wahlberger-dev | System | Hetzner VPS; restic client `cloud` over ZeroTier (10.243.0.0/16); `restic-backup.service` at 04:30 |
| pi-de-int-wahlberger-dev | System | Current rest-server; not changed (BD-BR-13) |
| notify_failure | System | Resend email: `notify-failure@` (5 failures in 10 min) and `notify-failure-immediate@` (every failure) |
| smartd, btrfsmaintenance, snapper, firewalld | System | Host services configured or used by this feature |

### Functional Requirements

Cross-cutting requirements. Area requirements are in the four area files.

- BD-FR-25 [Must]: If a path listed for a role in BD-BR-04 is not mounted when that role's check runs, then the role shall fail before any change, with a message naming the path. This applies to `btrbk`, `db_dump` and `restic_server`. The check reads the live mount table, not facts gathered at play start.
- BD-FR-27 [Must]: Each unit listed in BD-BR-04 shall declare `RequiresMountsFor=` with the paths listed for it.
- BD-FR-28 [Must]: If a `backup_disk_mounts` path is not mounted, then no unit of this feature shall create a file or subvolume below that path.
- BD-FR-33 [Must]: Each unit and timer listed in BD-BR-05 shall have the listed property value.

### Business Rules

- BD-BR-04: Mount guards. Every path listed must be mounted (Terms), both for the Ansible-time check (BD-FR-25, BD-FR-26) and for the unit's `RequiresMountsFor=` (BD-FR-27).

| Ansible-time check in role | Unit with `RequiresMountsFor=` | Paths |
|---|---|---|
| `backup_disk` (after its mount task) | none | every `backup_disk_mounts` path |
| `btrbk` | `btrbk.service` | `btrbk_target_dir`, every `btrbk_sources` path |
| `db_dump` | `db-dump.service` | the `storage_mounts` path that contains `db_dump_dir` (`/mnt/containers`) |
| `restic_server` | `restic-server.service`, `restic-server-maintenance.service` | the `storage_mounts` path that contains `restic_server_data_dir` (`/mnt/data`) |

- BD-BR-05: Unit properties. Production values are shown; `%n` expands to the unit name.

| Unit | Property | Value |
|---|---|---|
| `btrbk.timer` | `OnCalendar` / `Persistent` | `btrbk_on_calendar` (default `*-*-* 01:30:00`) / `true` |
| `btrbk.service` | `OnFailure` | `notify-failure-immediate@%n.service` |
| `db-dump.service` | `OnFailure` | `notify-failure-immediate@%n.service` |
| `restic-server.service` | `OnFailure` / `Restart` / `WantedBy` | `notify-failure@%n.service` / `always` / `default.target` |
| `restic-server-maintenance.timer` | `OnCalendar` / `Persistent` | `restic_server_maintenance_on_calendar` (default `*-*-* 06:00:00`) / `true` |
| `restic-server-maintenance.service` | `OnFailure` / `User` / `Group` | `notify-failure-immediate@%n.service` / `restic_server_user` / its primary group |
| `backup-disk-health.timer` | `OnCalendar` / `Persistent` | `backup_disk_health_on_calendar` (default `*-*-* 09:00:00`) / `true` |
| `backup-disk-health.service` | `OnFailure` | `notify-failure-immediate@%n.service` |
| cloud `restic-backup.timer` | `OnCalendar` | `*-*-* 04:30:00` |

### Inputs

The cross-cutting FRs have no inputs of their own. Inputs are listed in each area file.

### Outputs

| Name | Type | Constraints |
|---|---|---|
| `RequiresMountsFor=` and the BD-BR-05 properties on the feature's units | systemd unit properties | BD-FR-27, BD-FR-33 |

### Error Cases

| Condition | Expected behaviour |
|---|---|
| A BD-BR-04 path is not mounted at Ansible time | The role fails before any change, naming the path (BD-FR-25) |
| A BD-BR-04 path is not mounted when its unit starts | The unit does not start (result `dependency`), and nothing is written below a backup mount path (BD-FR-28). The health check raises the alert (BD-A-19, BD-D-09) |
| Second normal run without input changes | `changed=0` (BD-NFR-01) |

Area-specific error cases are in each area file.

### Acceptance Criteria

Scenario BD-AC-01 [S]: Static checks pass (BD-NFR-02)
- When the operator runs these commands:
  - in `nas-de-int-wahlberger-dev/`: `yamllint .`, `ansible-lint`, `ansible-playbook site.yml --syntax-check` and `ansible-playbook backup_disk_init.yml --syntax-check`;
  - in `cloud-wahlberger-dev/`: `yamllint .`, `ansible-lint` and `ansible-playbook site.yml --syntax-check`.
- Then every command exits 0

Scenario BD-AC-02 [S]: No lint suppression is added (BD-NFR-03)
- When the operator runs `git diff master -- nas-de-int-wahlberger-dev cloud-wahlberger-dev ':(exclude)nas-de-int-wahlberger-dev/reqs' | grep -E '^\+.*(noqa|skip_list|warn_list)'`
- Then it prints nothing

Scenario BD-AC-03 [S]: Molecule passes and documents its exclusions (BD-NFR-04, BD-FR-150, BD-FR-151)
- When the operator runs `molecule test` in `nas-de-int-wahlberger-dev/`
- Then it exits 0, with no idempotence change and no deprecation warning
- And `converge.yml` has a comment naming the reason for each of `backup_disk`, `btrbk`, `db_dump` and `restic_server` that it does not converge (BD-FR-150)
- And, if BD-FR-151 is implemented, `restic_backup_decommission` is converged

Scenario Outline BD-AC-27 [V]: Ansible-time mount guards read the live mount table (BD-FR-25, BD-BR-04)
- Given the VM after runbook step 5, with `<state>`
- When the operator runs `ansible-playbook -i inventories/vm site.yml --tags <tags>`
- Then `<expectation>`
- Examples:

| Row | `<state>` | `<tags>` | `<expectation>` |
|---|---|---|---|
| 1 | `/mnt/backup/btrbk` unmounted | `btrbk` | fails before any change, naming `/mnt/backup/btrbk` |
| 2 | `restic-server` stopped, `/mnt/data` unmounted | `btrbk` | fails before any change, naming `/mnt/data` |
| 3 | fixture DB stopped, `/mnt/containers` unmounted | `db_dump` | fails before any change, naming `/mnt/containers` |
| 4 | `restic-server` stopped, `/mnt/data` unmounted | `restic_server` | fails before any change, naming `/mnt/data` |
| 5 | `restic-server` stopped, the top level (`subvolid=5`) mounted at `/mnt/data` instead of `@data` | `restic_server` | fails before any change, naming `/mnt/data` |
| 6 | `/mnt/backup/btrbk` unmounted | `backup_disk,btrbk` | `failed=0`: `backup_disk` mounts the path first in the same play |

Scenario BD-AC-57 [V]: Units carry their properties at runtime (BD-FR-27, BD-FR-33, BD-BR-05)
- When the operator runs `systemctl show <unit> -p <property> --value` for every NAS row of BD-BR-05, and `-p RequiresMountsFor` for every unit of BD-BR-04
- Then each output equals or contains the listed value

Scenario BD-AC-58 [V]: Idempotent second run (BD-NFR-01)
- When the operator runs `site.yml` twice on the VM after runbook step 5
- Then the second recap shows `changed=0`

Scenario BD-AC-59 [V]: Exactly one new listening port (BD-NFR-07)
- When the operator compares `ss -tlnH` from before and after runbook step 5 on the VM
- Then the only added listener is on port 8000

Scenario BD-AC-60 [V]: rest-server returns after a reboot (BD-NFR-09)
- When the operator reboots the VM
- Then within 300 s after `running`/`degraded`, `curl -u cloud:<pw> http://<VM IP>:8000/cloud/config` returns `200`, and `/mnt/backup/btrbk` is mounted

Scenario Outline BD-AC-80 [H]: Post-cut-over smoke checks (read-only; one test per row)
- Given the runbook step named in the row has completed on the NAS
- When the operator runs `<check>`
- Then `<expectation>`
- Examples:

| Row | After step | `<check>` | `<expectation>` | Requirement |
|---|---|---|---|---|
| 1 | 3 | `findmnt -no UUID,OPTIONS /mnt/backup/btrbk`; its `/etc/fstab` line | as in BD-AC-26 | BD-FR-23 |
| 2 | 4 | `systemctl show -p Result btrbk.service` | `Result=success` | BD-FR-51, BD-FR-54 |
| 3 | 4 | `btrfs subvolume show` on the newest snapshot in `/mnt/backup/btrbk/{data,containers}/` | `Received UUID` not `-` | BD-FR-54 |
| 4 | 4 | `ls` of the newest `containers` snapshot's `db-dumps/` | `paperless.sql`, `immich.sql`, `tandoor.sql`, `forgejo.db` | BD-FR-65, BD-FR-66 |
| 5 | 4 | `zypper se -s -i btrbk`; `zypper lr -d` | `filesystems` repository, GPG check on, priority 150 | BD-FR-47, BD-FR-48, BD-FR-50 |
| 6 | 5 | `systemctl show` for the BD-BR-05 NAS rows | the listed values | BD-FR-33 |
| 7 | 5 | `firewall-cmd --zone=public --list-rich-rules`; `--list-ports` | one rule each for `10.10.0.0/16` and `10.243.0.0/16`; `8000/tcp` absent | BD-FR-109, BD-FR-110 |
| 8 | 5 | `podman inspect restic-server`; `podman top restic-server huser` | `--private-repos --append-only --max-size 107374182400`; UID not 0 | BD-FR-89 to BD-FR-92 |
| 9 | 5 | `ls -Zd /mnt/data/samba` (if SELinux is enabled) | equal to the value saved before step 5 | BD-FR-160 |
| 10 | 5 | `grep BTRFS_SCRUB_MOUNTPOINTS /etc/sysconfig/btrfsmaintenance` | `/mnt/backup/btrbk` plus every value saved before step 3 | BD-FR-30, BD-FR-31 |
| 11 | 5 | `journalctl -u smartd -b`; the smartd configuration | the by-id path is monitored; its line has `-a` and the BD-FR-38 schedule; every device line saved before step 3 is present | BD-FR-37, BD-FR-38, BD-FR-41, BD-FR-42 |
| 12 | 5 | `sha256sum /etc/snapper/configs/{data,containers}` | equal to the values saved before step 3 | BD-FR-64 |
| 13 | 7 | `systemctl start backup-disk-health.service` after one cloud run | `Result=success` | BD-FR-34 to BD-FR-36 |
| 14 | 7, after the next 01:30 run | `ls` of the newest received `data` snapshot | contains `restic-repos/cloud/config` | BD-FR-161 |

Scenario BD-AC-84 [H]: Idempotent second run in production (BD-NFR-01)
- When the operator runs `site.yml` a second time on the NAS and on cloud after the cut-over
- Then both recaps show `changed=0`

Scenario BD-AC-85 [H]: Exactly one new listening port in production (BD-NFR-07)
- When the operator compares `ss -tlnH` saved before step 1 with the output after step 5
- Then the only added listener is on port 8000

Scenario BD-AC-86 [H]: Run durations stay within budget (BD-NFR-11, BD-NFR-12)
- When the operator reads the journal start and end times of the first 7 nightly runs after the cut-over
- Then for every run whose dumps all succeeded, the time from `db-dump.service` start to the end of the incremental `btrbk.service` run (not the first full send) is at most 90 min
- And every cloud `restic-backup.service` run lasts at most 60 min

Scenario BD-AC-87 [H]: The NAS recovers from its first rebootmgr reboot (BD-NFR-09)
- Given the first rebootmgr reboot after the cut-over has happened (observed, not triggered)
- Then `restic-server.service` became active within 300 s after `running`/`degraded`
- And the next `backup-disk-health.service` run ends with `Result=success`

### Non-Functional Requirements

- BD-NFR-01: A second consecutive `site.yml` with unchanged inputs reports `changed=0`, for the NAS (VM fixture and production) and for cloud.
- BD-NFR-02: `yamllint`, `ansible-lint` (production profile) and `--syntax-check` exit 0 for the NAS `site.yml`, `backup_disk_init.yml` and cloud's `site.yml`.
- BD-NFR-03: The feature adds no lint suppression (`# noqa`, `skip_list`, `warn_list`).
- BD-NFR-04: `molecule test` in `nas-de-int-wahlberger-dev/` exits 0, with no idempotence change and no deprecation warning.
- BD-NFR-05: `/mnt/data` (including the cloud repository) and `/mnt/containers` have a recovery point objective of <= 24 h on the backup disk (daily btrbk run). A source whose newest received snapshot is older than 26 h raises an alert at the next daily health check. When the health check runs at its scheduled 09:00 time, that is at most 33 h after the last good scheduled run.
- BD-NFR-06: cloud's `/opt/podman` has a recovery point objective of <= 24 h on the NAS (daily 04:30 run). The 26 h freshness alert applies to the cloud repository.
- BD-NFR-07: The feature adds exactly one host-listening TCP port on the NAS (`restic_server_port`), and none on cloud.
- BD-NFR-08: With the backup filesystem absent, the NAS reaches `running` or `degraded` with no manual action, and rest-server keeps serving.
- BD-NFR-09: rest-server answers authenticated requests within 300 s after a reboot reaches `running` or `degraded`.
- BD-NFR-10: An alert starts within 5 min after a BD-BR-05 unit with `OnFailure=` fails. On production, the email arrives within 5 min.
- BD-NFR-11: In scheduled runs where every dump finishes before its timeout, the dump step plus the incremental btrbk run end within 90 min of 01:30, before the 03:00 rebootmgr window. The first full send is exempt.
  - Worst case: when dumps hit `db_dump_timeout`, the serial dumps take up to 4 x 30 min = 120 min, and the run can overlap the window. This is accepted: the failed dumps raise alerts, and an interrupted run is completed by the next one (BD-FR-62).
- BD-NFR-12: Each cloud nightly run (backup and check) lasts at most 60 min, so a 04:30 run ends 30 min before the 06:00 maintenance run.

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| BD-FR-25, BD-BR-04 | test [V] | BD-AC-27 |
| BD-FR-27, BD-FR-33, BD-BR-05 | inspection [S], test [V], smoke [H] | BD-AC-07, BD-AC-57, BD-AC-80 row 6 |
| BD-FR-28 | test [V] | BD-AC-28 |
| BD-NFR-01 | test [V], demonstration [H] | BD-AC-58, BD-AC-84 |
| BD-NFR-02, BD-NFR-03, BD-NFR-04 | test [S] | BD-AC-01, BD-AC-02, BD-AC-03 |
| BD-NFR-05, BD-NFR-06 | test [V]; analysis (daily timers with `Persistent=true` plus a 26 h threshold checked daily at 09:00) | BD-AC-55, BD-AC-57 |
| BD-NFR-07 | test [V], demonstration [H] | BD-AC-59, BD-AC-85 |
| BD-NFR-08 | test [V] | BD-AC-28 |
| BD-NFR-09 | test [V], demonstration [H] | BD-AC-60, BD-AC-87 |
| BD-NFR-10 | test [V], demonstration [H] | BD-AC-28, BD-AC-32, BD-AC-82 |
| BD-NFR-11, BD-NFR-12 | demonstration [H] | BD-AC-86 |

Area requirements are verified in each area file's Verification section.

### Out of Scope

- An offsite copy of the backup disk or of the restic repositories. Deferred to a separate feature.
- Restore procedures beyond the DOC-O runbook. The only drills are BD-AC-54 and BD-AC-83.
- Decommissioning the Pi, changing its roles, or deleting its repositories. This is a separate follow-up (BD-BR-13).
- Changing cloud's backup paths or exclusions. The schedule changes only as BD-FR-126 states.
- Playbook runs against nas, cloud or pi in this cycle (BD-C-03).
- SMART, scrub and freshness alerting for the existing disks. This is deferred to a separate monitoring feature.
- Backing up the NAS root filesystem.
- LUKS on the backup disk. The disk sits in the same chassis as the unencrypted source disks.
- TLS for the NAS rest-server. It is reachable only from 10.10.0.0/16 and 10.243.0.0/16, and the data is encrypted client-side.
- Importing the Pi's restic history into btrbk.
- Won't: per-user append-only (no such rest-server flag).
- Won't: `nodatacow`.
- Won't: snbk.
- Won't: formatting from `site.yml` (BD-FR-03).
- Won't: the NAS backing up to its own rest-server.
- Won't: automated deletion of the Pi's repositories.
- Won't: a restic subvolume or snapper config on the backup disk (owner, 2026-10-09; BD-D-08).

### Open Questions

None. The status stays `draft` until a human approves.

Decision log:
- Owner decisions supplied with the request (2026-10-09) are recorded in BD-C-04 and BD-BR-13.
- Owner answers: Q1 (btrbk proceeds after a failed dump), Q2 (OBS `filesystems`), Q3 (cloud at 04:30); the 06:00 maintenance run was accepted.
- First refactor (auditor priorities): VM gate, mount guards, prune guard, `--max-size`, run identity, `restic_backup_forget_enabled`, init hardening, dump timeout, health check, duration budgets, cut-over flags, render check, VM fixture, `BD-` IDs, Tandoor markers.
- Final loop: separate decommission flag (step 5); mtime-preserving restores and DOC-O10 re-baselining; freshness skips absent paths; `osc signkey` step and key renewal; named render check; extended destructive-command grep; reconciled NFR-11 and NFR-05; firewall rule ungated.
- Owner feedback (2026-10-09), applied in v3.0:
  1. The backup disk holds only `@btrbk`. The restic repositories move to `/mnt/data/restic-repos` (BD-D-08). This removed BD-FR-19, BD-FR-122, BD-FR-123 and BD-AC-53, and added BD-FR-160 and BD-FR-161.
  2. Allowed sources are a list covering 10.10.0.0/16 and 10.243.0.0/16 (ZeroTier).
  3. The disk size is verified (BD-A-16).
  4. The quota is confirmed (BD-A-18).
  5. `REQS.md` is split into `reqs/`.

  The FR/BR/NFR/AC numbering is otherwise unchanged. Also fixed: BD-FR-53 now references `samba_data_dir`, because `samba_mount_path` is `/mnt/data` itself.
