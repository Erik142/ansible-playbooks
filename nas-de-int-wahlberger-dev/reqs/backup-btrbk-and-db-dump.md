## Feature: Local backup disk, btrbk, and NAS-hosted restic REST server (btrbk replication and database dumps)
status:            ready
priority:          must
version:           3.0
quality:           feature-level scores in [backup-overview.md](backup-overview.md)

### Problem Statement

This file covers two roles:
- `btrbk`, which every night replicates `/mnt/data` (including the cloud restic repository at `/mnt/data/restic-repos`, BD-D-08) and `/mnt/containers` to the backup disk as read-only btrfs snapshots, with a target retention that is independent of the source;
- `db_dump`, which writes database dumps into `/mnt/containers` right before the snapshot.

Terms, decisions (BD-D-02, BD-D-03, BD-D-08, BD-D-10), assumptions and NFRs are in [backup-overview.md](backup-overview.md). IDs from other files resolve through the [index.md ID map](index.md#id-map).

### Actors

See [backup-overview.md](backup-overview.md#actors). Main actors here: btrbk, the dump step, the NAS host and notify_failure.

### Functional Requirements

#### D. Replication with btrbk (role `btrbk`)
- BD-FR-47 [Must]: The `btrbk` role shall install the `btrbk` package from the zypper repository `btrbk_zypper_repo_url`.
- BD-FR-48 [Must]: The repository of BD-FR-47 shall have GPG signature checking enabled.
- BD-FR-49 [Must]: If the repository signing key's fingerprint is not `btrbk_zypper_repo_gpg_fingerprint`, then the `btrbk` role shall fail before adding the repository or its key.
- BD-FR-50 [Must]: After a run of the `btrbk` role, `btrbk` shall be the only installed package whose repository is the repository of BD-FR-47.
- BD-FR-51 [Must]: When a btrbk run executes, btrbk shall create one read-only snapshot of each `btrbk_sources` entry in `<source path>/<btrbk_snapshot_dirname>` (BD-A-07).
- BD-FR-52 [Must]: The btrbk snapshot directory shall not be a `.snapshots` directory or below one.
- BD-FR-53 [Must]: The btrbk snapshot directory shall not be at or below `samba_data_dir` (`/mnt/data/samba`, the Samba share's parent).
- BD-FR-54 [Must]: When a btrbk run executes, btrbk shall transfer each new source snapshot with btrfs send/receive into `<btrbk_target_dir>/<source name>/`.
- BD-FR-55 [Must]: When the target holds a received snapshot whose source-side counterpart still exists, btrbk shall send the new snapshot incrementally, with that pair as parent.
- BD-FR-56 [Must]: No received snapshot shall contain files from a snapper `.snapshots` subvolume.
- BD-FR-57 [Must]: btrbk shall delete a received snapshot only when `btrbk_target_preserve` (default `14d 8w 12m 3y`) and `btrbk_target_preserve_min` (default `no`) allow it.
- BD-FR-58 [Must]: btrbk shall delete a source-side btrbk snapshot only when `btrbk_snapshot_preserve_min` (default `2d`) and `btrbk_snapshot_preserve` (default `no`) allow it.
- BD-FR-59 [Must]: btrbk shall keep, for each source, the newest source-side snapshot that has a received counterpart.
- BD-FR-60 [Must]: If btrbk exits with a non-zero status (including 10, partial failure), then `btrbk.service` shall end in the `failed` state.
- BD-FR-61 [Must]: When `btrbk.service` is started, or `btrbk run` is invoked, while a btrbk run is active, no second btrbk process shall run at the same time.
- BD-FR-62 [Must]: If a btrbk run is interrupted during a transfer, then the next btrbk run shall exit with status 0.
- BD-FR-63 [Must]: After the run of BD-FR-62, every subvolume below `btrbk_target_dir` shall have a `Received UUID`.
- BD-FR-64 [Must]: The `snapper` role and the files `/etc/snapper/configs/data` and `/etc/snapper/configs/containers` shall be unchanged by this feature.
- BD-FR-161 [Must]: Each received `data` snapshot shall contain `restic_server_data_dir` as it was at snapshot time. No btrbk configuration excludes it (BD-D-08).

#### F. Repository signing-key renewal and expiry alert (role `btrbk`)
- BD-FR-162 [Must]: `btrbk-key-refresh.timer` shall start `btrbk-key-refresh.service` on `btrbk_key_refresh_on_calendar` (default `weekly`, `Persistent=true`). The service has `OnFailure=notify-failure-immediate@%n.service`, no `RequiresMountsFor=`, and its start waits up to 300 s for a running zypper.
- BD-FR-163 [Must]: `btrbk-key-refresh.service` shall fetch the key from `btrbk_zypper_repo_key_url` over HTTPS only, with a timeout. If the fetch fails, then the service shall fail (exit 3) with a message naming the URL.
- BD-FR-164 [Must]: If the fetched file does not hold exactly one primary key (one `pub` record), or its primary fingerprint differs from `btrbk_zypper_repo_gpg_fingerprint`, then the service shall fail (exit 2) without importing anything, and its message shall name both fingerprints and `osc signkey filesystems` (a possible rotation or tampering needs a human; BD-FR-49 uses the same rule).
- BD-FR-165 [Must]: If the fingerprint matches, then the service shall run `rpm --import` on the verified file and `zypper --non-interactive refresh <btrbk_zypper_repo_alias>`. It shall not use `--gpg-auto-import-keys` or any option that disables a signature check. A failure of either command fails the service (exit 1) with the command's output.
- BD-FR-166 [Must]: If the fetched key expires in fewer than `btrbk_key_warn_days` (default `60`) days, then the service shall fail (exit 1) with a message naming the days left, after having tried the import and the refresh of BD-FR-165. A key with no expiry date passes.
- BD-FR-167 [Must]: If OBS re-issues the same key (same fingerprint) with a later expiry, then the next run of `btrbk-key-refresh.service` shall exit 0 and send no alert. The role's install step (BD-FR-49) imports the key only when it is absent; the timer is what refreshes an installed key.
- BD-FR-168 [Should]: `btrbk_key_refresh_on_calendar` and `btrbk_key_warn_days` shall be declared in `meta/argument_specs.yml` with the defaults above.

#### E. Database dumps (role `db_dump`)
- BD-FR-65 [Must]: When `btrbk.service` starts, the dump step shall write one `pg_dump` file per `db_dump_postgres` entry into `db_dump_dir`, before btrbk creates the snapshot of `/mnt/containers`.
- BD-FR-66 [Must]: When `btrbk.service` starts, the dump step shall write an `sqlite3 .backup` copy of `db_dump_forgejo_db_path` into `db_dump_dir`, before btrbk creates the snapshot of `/mnt/containers`.
- BD-FR-67 [Must]: If `db_dump_dir` is not below a `btrbk_sources` path, then the `db_dump` role shall fail before any change, with a message naming `db_dump_dir`.
- BD-FR-68 [Must]: `db_dump_dir` (default `/mnt/containers/db-dumps`) shall have mode `0700` and owner `root:root`.
- BD-FR-69 [Must]: Each dump file shall be written under a temporary name and renamed to its final name only after its dump command exited 0.
- BD-FR-70 [Must]: Each dump file shall have mode `0600` and owner `root:root`.
- BD-FR-71 [Must]: Every credentials file used by the dump step shall be in `db_dump_credentials_dir` (default `/var/lib/db-dump`), which is not on a `btrbk_sources` filesystem.
- BD-FR-72 [Must]: Every credentials file used by the dump step shall have mode `0600` and owner `root:root`.
- BD-FR-73 [Must]: Each dump command shall be stopped after `db_dump_timeout` (default `30min`), and a stopped dump counts as failed.
- BD-FR-74 [Must]: If any dump fails, then `db-dump.service` shall end in the `failed` state.
- BD-FR-75 [Must]: If the dump step fails, then btrbk shall still create and transfer the snapshots of the same btrbk run (owner Q1).
- BD-FR-76 [Should]: If one dump fails, then the dump step shall still run every remaining dump of the same run.

### Business Rules

- BD-BR-11: Crash-consistent copies are valid backups, for databases and for the restic repository (BD-C-05). Dumps are an additional copy, so a failed dump does not cancel the btrbk run (BD-FR-75).
- BD-BR-15: btrbk target retention, btrbk source retention and snapper retention are three independent settings. Changing one leaves the other two unchanged.

### Inputs

| Name | Type | Required | Constraints |
|---|---|---|---|
| `btrbk_sources` | list of `{name, path}` | no | Default `data` → `/mnt/data` and `containers` → `/mnt/containers`. Each path is a `storage_mounts` path |
| `btrbk_target_dir` | path | no | Default `/mnt/backup/btrbk` |
| `btrbk_snapshot_dirname` | str | no | Default `.btrbk`; not `.snapshots` |
| `btrbk_snapshot_preserve_min` / `btrbk_snapshot_preserve` | str | no | Defaults `2d` / `no` |
| `btrbk_target_preserve` / `btrbk_target_preserve_min` | str | no | Defaults `14d 8w 12m 3y` / `no` |
| `btrbk_on_calendar` | str | no | Default `*-*-* 01:30:00` |
| `btrbk_zypper_repo_url` | URL | no | Default `https://download.opensuse.org/repositories/filesystems/openSUSE_Tumbleweed/` |
| `btrbk_zypper_repo_priority` | int | no | Default `150` |
| `btrbk_zypper_repo_gpg_fingerprint` | str (40 hex) | no | Default `B1FB53748720472205FA601998C97FE7324E6311` (BD-A-17) |
| `btrbk_key_refresh_on_calendar` / `btrbk_key_warn_days` | str / int | no | Defaults `weekly` / `60` (BD-FR-162, BD-FR-166) |
| `db_dump_dir` | path | no | Default `/mnt/containers/db-dumps` |
| `db_dump_credentials_dir` | path | no | Default `/var/lib/db-dump` |
| `db_dump_postgres` | list of `{name, container, database, user, password}` | no | Default entries `paperless`, `immich` and `tandoor`, carrying today's names (BD-A-08) |
| `db_dump_forgejo_db_path` | path | no | Default `{{ forgejo_volume_dir }}/data/forgejo.db` |
| `db_dump_timeout` | str | no | Default `30min` |

### Outputs

| Name | Type | Constraints |
|---|---|---|
| btrbk configuration; `btrbk.service`, `btrbk.timer`, `db-dump.service` | Config + systemd units | BD-FR-57, BD-FR-58, BD-BR-05 |
| Source snapshots `<source>/.btrbk/<name>.<timestamp>` | Read-only subvolumes | BD-FR-51 to BD-FR-53 |
| Received snapshots `/mnt/backup/btrbk/<name>/<name>.<timestamp>` | Read-only subvolumes with `Received UUID` | BD-FR-54 to BD-FR-57, BD-FR-161 |
| `/mnt/containers/db-dumps/{paperless,immich,tandoor}.sql`, `forgejo.db` | Files | `0600 root:root` |
| zypper repository `filesystems` | Repository definition | BD-FR-47 to BD-FR-50 |

### Error Cases

| Condition | Expected behaviour |
|---|---|
| btrbk fails (exit non-zero, target full, read-only target) | `btrbk.service` fails and raises an alert (BD-FR-60, BD-BR-05) |
| btrbk run still active at the next trigger, or a manual `btrbk run` | No second process runs at the same time (BD-FR-61) |
| btrbk run interrupted (power loss, reboot, kill) | The next run exits 0, and no target subvolume lacks a `Received UUID` (BD-FR-62, BD-FR-63) |
| OBS repository unreachable, or the key fingerprint differs | The `btrbk` role fails, before adding the repository in the fingerprint case (BD-FR-49). The fallback is the README's pinned upstream script (BD-D-03) |
| A dump fails or exceeds `db_dump_timeout` | `db-dump.service` fails and raises an alert (BD-FR-73, BD-FR-74). The other dumps run (BD-FR-76). The previous file is kept (BD-FR-69). btrbk proceeds (BD-FR-75) |
| A source filesystem fills with btrbk source snapshots or with the restic repository | `disk_space` alerts at 85 % (BD-FR-45). btrbk fails and raises an alert (BD-FR-60) |
| btrbk snapshots `@data` while rest-server writes | The received copy of the repository is crash-consistent (BD-A-22). It is checked with `restic check` when restored (DOC-O7) |

### Acceptance Criteria

Scenario BD-AC-15 [S]: The snapper role is untouched (BD-FR-64)
- When the operator runs `git diff master -- nas-de-int-wahlberger-dev/roles/snapper/`
- Then it prints nothing

Scenario Outline BD-AC-29 [V]: btrbk comes from the pinned repository only (BD-FR-47 to BD-FR-50, BD-A-01)
- Given the VM with `<state>`
- When the operator runs `site.yml --tags btrbk`
- Then `<expectation>`
- Examples:

| Row | `<state>` | `<expectation>` |
|---|---|---|
| 1 | defaults | `zypper se -s -i btrbk` shows the `filesystems` repository; `zypper lr -d` shows GPG check on and priority 150; `zypper se -i -r <alias>` lists only btrbk; searching only the OSS repositories (`zypper se -r oss -r non-oss -r update btrbk`) finds nothing (a plain search still lists the installed package) |
| 2 | `btrbk_zypper_repo_gpg_fingerprint` = 40 zeros, repository not yet added | the play fails before `zypper lr` shows the repository, and the message names the fingerprint (BD-FR-49) |

Scenario BD-AC-30 [V]: The first btrbk run replicates both sources, the repository and fresh dumps (BD-FR-51 to BD-FR-54, BD-FR-56, BD-FR-65, BD-FR-66, BD-FR-161)
- Given BD-AC-26 has passed, the VM client has initialised the cloud repository, and `btrbk -n run` reports no error
- When the operator runs `systemctl start btrbk.service`
- Then the unit's `Result=success`
- And each `<source>/.btrbk` holds a snapshot with `ro=true` (BD-FR-51), and neither directory is a `.snapshots` path or below `samba_data_dir` (BD-FR-52, BD-FR-53)
- And `/mnt/backup/btrbk/{data,containers}/` each hold a subvolume whose `Received UUID` is not `-` (BD-FR-54)
- And `find /mnt/backup/btrbk/data/<newest>/.snapshots -mindepth 1 -maxdepth 1` prints nothing (BD-FR-56)
- And `/mnt/backup/btrbk/data/<newest>/restic-repos/cloud/config` exists (BD-FR-161)
- And `/mnt/backup/btrbk/containers/<newest>/db-dumps/` contains `fixture.sql` and `forgejo.db`, each with an mtime after the run's start and before the source snapshot's `Creation time` (BD-FR-65, BD-FR-66)

Scenario BD-AC-31 [V]: The second run is incremental (BD-FR-55, BD-FR-59)
- Given BD-AC-30 has passed
- When the operator moves the VM clock one day on (`date -s '+1 day'`; `target_preserve` keeps only the first snapshot of each day, so a second run on the same day creates a source snapshot but sends nothing) and starts `btrbk.service` again
- Then btrbk's summary in the journal (no `transaction_log` is configured) shows, for each source, a `>>>` incremental receive entry (BD-FR-55)
- And each `<source>/.btrbk` still holds the snapshot named as that parent, and the new snapshot (BD-FR-59)

Scenario BD-AC-32 [V]: A btrbk failure fails the unit and raises an alert (BD-FR-60, BD-BR-05)
- When the operator runs `btrfs property set -ts /mnt/backup/btrbk ro true`, starts `btrbk.service`, and then resets the property to `false`
- Then the unit ends `failed`, and an alert is raised within 5 min
- And the next start ends with `Result=success`

Scenario BD-AC-33 [V]: No two btrbk processes run at the same time (BD-FR-61)
- Given a 5 GiB random file under `/mnt/data`, so that the transfer takes more than 10 s
- When the operator runs `systemctl start --no-block btrbk.service` twice and then `btrbk run`, sampling `pgrep -c -x btrbk` every second
- Then no sample exceeds 1, and `btrbk run` exits non-zero with a lock message

Scenario BD-AC-34 [V]: An interrupted transfer is completed by the next run (BD-FR-62, BD-FR-63)
- Given a 5 GiB random file under `/mnt/data`
- When the operator runs `systemctl kill btrbk.service` while a `btrfs receive` process exists, then `systemctl start btrbk.service`
- Then the second start ends with `Result=success`, and every subvolume below `/mnt/backup/btrbk` has a `Received UUID` that is not `-`

Scenario Outline BD-AC-35 [V]: Dump files and credentials (BD-FR-67, BD-FR-68, BD-FR-70 to BD-FR-72)
- When the operator runs `<command>`
- Then `<expectation>`
- Examples:

| Row | `<command>` | `<expectation>` |
|---|---|---|
| 1 | `stat -c '%a %U:%G' /mnt/containers/db-dumps` | `700 root:root` (BD-FR-68) |
| 2 | `stat -c '%a %U:%G' /mnt/containers/db-dumps/*` | every line `600 root:root` (BD-FR-70) |
| 3 | `df --output=target` and `stat` on each credentials file the dump step reads | target `/` or `/var` (the root filesystem; `/var` is a separate subvolume mount on Tumbleweed, never `/mnt/data` or `/mnt/containers`), mode `600 root:root` (BD-FR-71, BD-FR-72) |
| 4 | `site.yml --tags db_dump -e db_dump_dir=/var/tmp/db-dumps` | fails before any change, naming `db_dump_dir` (BD-FR-67) |

Scenario BD-AC-36 [V]: A failed dump keeps the previous file and does not stop btrbk (BD-FR-69, BD-FR-74 to BD-FR-76, BD-BR-11)
- Given BD-AC-30 has passed, and the operator notes the `sha256sum` of `fixture.sql` and the mtime of `forgejo.db`
- When the operator stops the fixture DB container and starts `btrbk.service`
- Then `db-dump.service` ends `failed`, and an alert is raised (BD-FR-74)
- And `fixture.sql` has the noted checksum (BD-FR-69)
- And `forgejo.db` has a later mtime (BD-FR-76)
- And `btrbk.service` ends with `Result=success`, and a new received `containers` snapshot exists (BD-FR-75)

Scenario BD-AC-37 [V]: A hanging dump is stopped by the timeout (BD-FR-73)
- Given `db_dump_timeout: 60s`, and an open `psql` session holding `LOCK TABLE <fixture table> IN ACCESS EXCLUSIVE MODE`
- When the operator starts `btrbk.service`
- Then `db-dump.service` ends `failed` within 120 s, and its journal reports the timeout
- And `btrbk.service` ends with `Result=success`

Scenario BD-AC-88 [S]: The key refresh units and script are well-formed (BD-FR-162, BD-FR-163, BD-FR-165, BD-FR-168)
- When the operator runs `tests/render-check.sh` and `pytest tests/unit/test_btrbk_key_refresh.py`
- Then `systemd-analyze verify` reports nothing for `btrbk-key-refresh.service` and `.timer`, and the script compiles
- And the service has `OnFailure=notify-failure-immediate@%n.service` and no `RequiresMountsFor=`, and the timer has `OnCalendar=weekly` and `Persistent=true`
- And the script contains no `--gpg-auto-import-keys`, `--no-gpg-checks` or insecure curl option, and fetches with `--proto =https`
- And `meta/argument_specs.yml` declares `btrbk_key_refresh_on_calendar` and `btrbk_key_warn_days`

Scenario BD-AC-89 [V]: A matching key far from expiry renews silently (BD-FR-164, BD-FR-165, BD-FR-166, BD-FR-167)
- Given the VM after `site.yml --tags btrbk`
- When the operator runs `systemctl start btrbk-key-refresh.service`
- Then the unit's `Result=success` and no failure email is sent
- And its journal reports the key as verified, imported and the repository refreshed, with the days left

Scenario BD-AC-90 [V]: A key with another fingerprint is never imported (BD-FR-164)
- Given the VM, and `btrbk_zypper_repo_key_url` pointing (via a test web server over HTTPS) at a different valid key
- When the operator runs `systemctl start btrbk-key-refresh.service`
- Then the unit ends `failed` with exit status 2 and a failure email is sent
- And the journal names both fingerprints
- And `rpm -qa gpg-pubkey` is unchanged

Scenario BD-AC-91 [V]: A key near expiry alerts after the renewal attempt (BD-FR-166)
- Given the VM, and `btrbk_key_warn_days` set above the days left until the key's expiry (2027-05-07), e.g. `3650`
- When the operator runs `systemctl start btrbk-key-refresh.service`
- Then the unit ends `failed` with exit status 1, the journal names the days left, and it shows that `rpm --import` and `zypper refresh` ran first
- And a failure email is sent

Scenario BD-AC-92 [V]: An unreachable key URL fails the unit (BD-FR-163)
- Given the VM, and `btrbk_zypper_repo_key_url` pointing at a closed port
- When the operator runs `systemctl start btrbk-key-refresh.service`
- Then the unit ends `failed` with exit status 3 and the journal names the URL

Scenario BD-AC-83 [H]: Restoring one file from the btrbk target (BD-FR-149 row DOC-O1)
- Given a file `<f>` under `/mnt/data/samba/` that has not changed since the newest received `data` snapshot
- When the operator follows DOC-O1 to copy `<f>` to `/tmp/r`
- Then `sha256sum /tmp/r` equals `sha256sum <f>`

The [H] smoke rows for this area (BD-AC-80 rows 2-5, 12, 14) are in [backup-overview.md](backup-overview.md#acceptance-criteria).

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| BD-FR-47 to BD-FR-50 | test [V], smoke [H] | BD-AC-29, BD-AC-80 row 5 |
| BD-FR-51 to BD-FR-54, BD-FR-56, BD-FR-65, BD-FR-66 | test [V], smoke [H] | BD-AC-30, BD-AC-80 rows 2-4 |
| BD-FR-55 | test [V] | BD-AC-31 |
| BD-FR-57, BD-FR-58, BD-BR-15 | inspection [S]; analysis (multi-month deletion follows btrbk's documented `*_preserve` semantics) | BD-AC-07 |
| BD-FR-59 | test [V]; analysis (btrbk's built-in incremental-base rule, over runs longer than the test) | BD-AC-31 |
| BD-FR-60 | test [V] | BD-AC-32 |
| BD-FR-61 | test [V] | BD-AC-33 |
| BD-FR-62, BD-FR-63 | test [V] | BD-AC-34 |
| BD-FR-64 | inspection [S], smoke [H] | BD-AC-15, BD-AC-80 row 12 |
| BD-FR-67, BD-FR-68, BD-FR-70 to BD-FR-72 | test [V] | BD-AC-35 |
| BD-FR-69, BD-FR-74 to BD-FR-76, BD-BR-11 | test [V] | BD-AC-36 |
| BD-FR-73 | test [V] | BD-AC-37 |
| BD-FR-161 | test [V], smoke [H] | BD-AC-30, BD-AC-80 row 14 |
| BD-FR-162, BD-FR-163, BD-FR-165, BD-FR-168 | inspection [S], test [V] | BD-AC-88, BD-AC-89, BD-AC-92 |
| BD-FR-164 | inspection [S] (unit tests), test [V] | BD-AC-88, BD-AC-90 |
| BD-FR-166, BD-FR-167 | inspection [S] (unit tests), test [V]; analysis (that OBS re-extends before expiry and that `rpm --import` replaces an installed key cannot be tested before 2027-05-07, BD-A-17) | BD-AC-89, BD-AC-91 |

### Non-Functional Requirements

See [backup-overview.md](backup-overview.md#non-functional-requirements) (BD-NFR-05 and BD-NFR-11 apply here).

### Out of Scope

See [backup-overview.md](backup-overview.md#out-of-scope).

### Open Questions

None.
