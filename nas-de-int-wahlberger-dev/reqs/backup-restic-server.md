## Feature: Local backup disk, btrbk, and NAS-hosted restic REST server (restic REST server, firewall, maintenance)
status:            ready
priority:          must
version:           3.0
quality:           feature-level scores in [backup-overview.md](backup-overview.md)

### Problem Statement

This file covers the `restic_server` role, which runs the append-only rest-server that cloud-wahlberger-dev backs up to. It also covers:
- the firewall rules that admit only the home LAN and ZeroTier;
- the NAS-side maintenance run that applies cloud's retention;
- the prune guard that protects that retention from forged snapshot times.

The repositories live at `/mnt/data/restic-repos` on the data disk, not on the backup disk (BD-D-08). Terms, decisions (BD-D-06, BD-D-08, BD-D-14 to BD-D-16), assumptions and NFRs are in [backup-overview.md](backup-overview.md). IDs from other files resolve through the [index.md ID map](index.md#id-map).

### Actors

See [backup-overview.md](backup-overview.md#actors). Main actors here: rest-server, the maintenance job, cloud-wahlberger-dev, firewalld and snapper (`data` config).

### Functional Requirements

#### G. restic REST server (role `restic_server`)
- BD-FR-87 [Must]: The playbook shall run rest-server as the Podman Quadlet container `restic-server` (unit `restic-server.service`), deployed through the `container` role.
- BD-FR-88 [Must]: `roles/restic_server/defaults/main.yml` shall pin `restic_server_image: docker.io/restic/rest-server:0.14.0` on a single line that the Renovate custom manager in `renovate.json` matches.
- BD-FR-89 [Must]: While `restic_server_private_repos` is `true` (default), rest-server shall run with `--private-repos`.
- BD-FR-90 [Must]: While `restic_server_append_only` is `true` (default), rest-server shall run with `--append-only`.
- BD-FR-91 [Must]: rest-server shall run with `--max-size <restic_server_max_size_bytes>` (default `107374182400`, 100 GiB; confirmed sufficient, BD-A-18).
- BD-FR-92 [Must]: The rest-server process shall run with the UID and GID of `restic_server_user` (default `restic-server`). Neither ID shall be 0.
- BD-FR-93 [Must]: The `restic_server` role shall create `restic_server_user` as a system account (UID below 1000) with login shell `/usr/sbin/nologin`.
- BD-FR-94 [Must]: `restic_server_data_dir` (default `/mnt/data/restic-repos`) shall be owned by `restic_server_user` and that account's primary group.
- BD-FR-95 [Must]: `restic_server_data_dir` shall have mode `0700`.
- BD-FR-96 [Must]: The `restic-server` container shall bind-mount `restic_server_data_dir` with the `:Z` option.
- BD-FR-97 [Must]: `restic_server_data_dir` shall be a directory on the `storage_mounts` filesystem mounted at `/mnt/data`, and shall not be at or below `samba_data_dir`, a `.snapshots` directory or a btrbk snapshot directory (BD-D-08).
- BD-FR-98 [Must]: The htpasswd file in `restic_server_data_dir` shall contain one bcrypt entry per `restic_server_clients` entry.
- BD-FR-99 [Must]: The htpasswd file shall have mode `0600` and owner `restic_server_user`.
- BD-FR-100 [Must]: The `restic_server` role shall install, with `community.general.zypper`, the passlib package that matches the Python interpreter Ansible uses on the host.
- BD-FR-101 [Must]: If `restic_server_clients` is empty, then the `restic_server` role shall fail before any change, with a message naming `restic_server_clients` and `roles/restic_server/README.md`.
- BD-FR-102 [Must]: If a `restic_server_clients` entry has an empty password, then the `restic_server` role shall fail before any change, with a message naming that entry's username.
- BD-FR-103 [Must]: If `restic_server_maintenance_repo_password` is empty, then the `restic_server` role shall fail before any change, with a message naming that variable.
- BD-FR-104 [Must]: When a `restic_server_clients` password changes, the new password shall authenticate within 60 s after the applying run ends.
- BD-FR-105 [Must]: When a `restic_server_clients` password changes, the old password shall get HTTP 401 within 60 s after the applying run ends.
- BD-FR-106 [Must]: The `restic_server` role shall install the `restic` package on the host.
- BD-FR-107 [Must]: No client password and no maintenance repository password shall appear in `/etc/containers/systemd/restic-server.container` or in any file under `/etc/systemd/system/`.
- BD-FR-160 [Must]: Starting `restic-server` shall change the SELinux context of no path outside `restic_server_data_dir`. In particular, `samba_data_dir` keeps its context (BD-A-11).

#### H. Firewall
- BD-FR-108 [Must]: The `firewall` role shall apply each `firewall_rich_rules` entry (default `[]`) as a firewalld rich rule in `firewall_zone`, both permanent and immediate.
- BD-FR-109 [Must]: For each `restic_server_allowed_sources` entry (production: `10.10.0.0/16` home LAN, `10.243.0.0/16` ZeroTier), the production `firewall_rich_rules` shall contain `rule family="ipv4" source address="<CIDR>" port port="<restic_server_port>" protocol="tcp" accept`.
- BD-FR-110 [Must]: `8000/tcp` shall appear neither in `firewall_zone`'s ports nor in any of its services.
- BD-FR-111 [Must]: rest-server shall not accept a TCP connection to `restic_server_port` from a source address outside every `restic_server_allowed_sources` CIDR, except from container networks on the NAS itself, which netavark places in the firewalld `trusted` zone; those still require htpasswd authentication and are append-only (BD-A-05, BD-A-23).

#### I. Cloud repository maintenance on the NAS
- BD-FR-112 [Must]: Every file and directory that a maintenance run creates in the repository shall be owned by `restic_server_user` (BD-D-14).
- BD-FR-113 [Must]: The maintenance run shall receive the repository password only from a file with mode `0600` and owner `root:root`, read by systemd through `EnvironmentFile=` (BD-D-14).
- BD-FR-114 [Must]: If any snapshot's recorded time is later than the modification time of its file in `<repository>/snapshots/` by more than `restic_server_maintenance_max_time_skew_hours` (default 6), or earlier by more than the past allowance (script option `--max-past-hours`, default 48; restic records the backup start, the file time is the upload end), then the maintenance run shall run neither forget nor prune (BD-BR-07).
- BD-FR-115 [Must]: When the maintenance run stops under BD-FR-114, `restic-server-maintenance.service` shall end in the `failed` state.
- BD-FR-116 [Must]: When the maintenance run stops under BD-FR-114, its journal shall list the ID of every offending snapshot.
- BD-FR-117 [Must]: When BD-FR-114 does not stop it, the maintenance run shall evaluate `restic forget --dry-run --json` on `<restic_server_data_dir>/<restic_server_maintenance_repo>` with `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`, abort without deleting if the removal set holds a snapshot ID the BD-FR-114 check did not see or the snapshot list changed meanwhile, then run `restic forget` on exactly those IDs and `restic prune`. These are the defaults of `restic_server_maintenance_keep_daily`, `_keep_weekly` and `_keep_monthly`.
- BD-FR-118 [Must]: After forget and prune exit 0, the maintenance run shall run `restic check --read-data-subset=<restic_server_maintenance_check_read_data_subset>` (default `10%`) on the same repository.
- BD-FR-119 [Must]: If forget, prune or check exits non-zero, then `restic-server-maintenance.service` shall end in the `failed` state.
- BD-FR-120 [Must]: If the repository is locked by another restic process, then the maintenance run shall wait up to `restic_server_maintenance_retry_lock` (default `30m`) for the lock before failing.
- BD-FR-121 [Must]: The maintenance run shall never run `restic init`.

#### J. Snapper safety net (deleted)
- BD-FR-122 [Deleted in v3.0]: was the `restic-repos` snapper config on the backup disk. It was replaced by the existing snapper `data` config, because the repositories now live in `@data` (BD-D-08).
- BD-FR-123 [Deleted in v3.0]: was the `create-config` assertion for `restic-repos`.

### Business Rules

- BD-BR-06: Append-only applies to every client of the NAS rest-server. Data leaves a repository there only through the NAS-local maintenance run or the owner's hand.
- BD-BR-07: Prune trust rule.
  - The threat: an append-only client cannot delete data, but it can write snapshots with any recorded time (BD-A-21). `restic forget` chooses which snapshots to keep by recorded time. Forged snapshots can therefore take the keep slots, and the next NAS-side prune would delete the real snapshots they displaced.
  - The rule: the maintenance run trusts recorded times only from 6 h after to 48 h before the NAS-observed file modification time (BD-FR-114; the asymmetry allows long backups). A client cannot set that time. A forged snapshot whose time is inside that window can only displace the snapshot of its own day.
  - Recovery from a prune that has already deleted data uses either of two copies, via the DOC-O7 procedure:
    - snapshots of the existing snapper `data` config, which contain `/mnt/data/restic-repos` (daily 7, weekly 4, monthly 12, yearly 2);
    - the btrbk copies of `@data` on the backup disk (14d 8w 12m 3y).

    DOC-O7 copies with `cp -a` or `rsync -a`, which preserve modification times, so the guard accepts the restored files.
  - Owner-side `restic tag`, `restic rewrite` or `restic copy` writes snapshot files with new modification times, which trips the guard by design. The documented re-baselining step (DOC-O10) is the only override.
- BD-BR-08: The cloud repository keeps 7 daily, 4 weekly and 6 monthly snapshots. Only the maintenance run applies that retention.
- BD-BR-09: Two shared secrets must hold equal values:
  - NAS `vault_restic_server_cloud_htpasswd_password` equals cloud `vault_restic_backup_rest_server_password`;
  - NAS `vault_restic_server_cloud_repo_password` equals cloud `vault_restic_backup_repo_password`.
- BD-BR-10: The NAS holds the cloud repository's encryption password, so root access on the NAS gives read access to cloud backup contents. The owner accepts this risk.

### Inputs

| Name | Type | Required | Constraints |
|---|---|---|---|
| `restic_server_image` | str | no | `docker.io/restic/rest-server:0.14.0` |
| `restic_server_data_dir` | path | no | Default `/mnt/data/restic-repos` (BD-D-08; the owner can override it, within BD-FR-97) |
| `restic_server_port` | int | no | Default `8000` |
| `restic_server_allowed_sources` | list of CIDR | yes | Production `["10.10.0.0/16", "10.243.0.0/16"]` (home LAN, ZeroTier; BD-A-04) |
| `restic_server_user` | str | no | Default `restic-server` |
| `restic_server_clients` | list of `{username, password}` | yes | Production: one entry, `cloud` (BD-FR-138) |
| `restic_server_private_repos` / `restic_server_append_only` | bool | no | Defaults `true` / `true` |
| `restic_server_max_size_bytes` | int | no | Default `107374182400` |
| `restic_server_maintenance_repo` | str | no | Default `cloud` |
| `restic_server_maintenance_repo_password` | str | yes | From `vault_restic_server_cloud_repo_password` (BD-BR-09) |
| `restic_server_maintenance_keep_daily` / `_keep_weekly` / `_keep_monthly` | int | no | Defaults `7` / `4` / `6` |
| `restic_server_maintenance_check_read_data_subset` | str | no | Default `10%` |
| `restic_server_maintenance_retry_lock` | str | no | Default `30m` |
| `restic_server_maintenance_max_time_skew_hours` | int | no | Default `6` |
| `restic_server_maintenance_on_calendar` | str | no | Default `*-*-* 06:00:00` |
| `firewall_rich_rules` | list of str | no | Default `[]`. Production: one BD-FR-109 rule per allowed source |

### Outputs

| Name | Type | Constraints |
|---|---|---|
| `/etc/containers/systemd/restic-server.container`; `restic-server.service` | Quadlet + unit | BD-FR-87 to BD-FR-96, BD-FR-107, BD-BR-05 |
| `/mnt/data/restic-repos/` with `.htpasswd` and `cloud/` | Directory tree | BD-FR-94 to BD-FR-99 |
| `restic-server-maintenance.service` / `.timer`; password file | Units + file | BD-FR-112 to BD-FR-121 |
| firewalld rich rules (one per allowed source) | Host state | BD-FR-108 to BD-FR-110 |

### Error Cases

| Condition | Expected behaviour |
|---|---|
| rest-server crash loop | `Restart=always`; alert after 5 failures in 10 min |
| Wrong client password; access to another user's repository path | HTTP 401; HTTP 401 or 403 (BD-FR-89) |
| A client sends DELETE or `forget` | HTTP 403, nothing deleted (BD-FR-90) |
| A client exceeds `--max-size` | rest-server rejects the upload; cloud's run fails and cloud alerts (BD-FR-91) |
| A connection arrives from outside both allowed CIDRs | Not accepted (BD-FR-111); local container networks are exempt (BD-A-23) |
| `/mnt/data` not mounted | rest-server and the maintenance run do not start (BD-BR-04). The host itself is degraded, because `/mnt/data` is a required boot mount |
| The backup disk is absent | No effect on rest-server or the maintenance run; only btrbk and the health check are affected (BD-BR-12) |
| A client writes snapshots with forged times | The maintenance run prunes nothing, fails, lists the IDs and raises an alert (BD-FR-114 to BD-FR-116). The owner removes the forged snapshots by hand (DOC-O8) |
| A prune deleted data wrongly | Restore from a snapper `data` snapshot or a btrbk copy with mtime-preserving copy (DOC-O7, BD-AC-54) |
| An owner-side `restic tag`/`rewrite`/`copy` | The guard trips at the next maintenance run; the owner re-baselines (DOC-O10) |
| The repository is locked at maintenance time | The run waits up to 30 min, then fails and raises an alert (BD-FR-120, BD-FR-119) |
| A stale lock from an interrupted cloud run | If the lock outlasts the retry window, the run fails and raises an alert. Recovery is `restic unlock` run as `restic_server_user` (DOC-O6) |
| Cloud repository missing on the NAS | The maintenance run fails, raises an alert, and creates no repository (BD-FR-121) |
| NAS and cloud repository passwords differ | The maintenance run fails (wrong password) and raises an alert |
| SELinux denies the maintenance run | The run fails and raises an alert (BD-A-11) |

### Acceptance Criteria

Scenario BD-AC-08 [S]: rest-server image pinned and Renovate-detectable (BD-FR-88)
- When the operator matches the `restic_server_image` line against the first custom-manager regex in `renovate.json`
- Then it matches, with depName `docker.io/restic/rest-server` and currentValue `0.14.0`

Scenario BD-AC-39 [V]: rest-server runs as specified (BD-FR-87, BD-FR-89 to BD-FR-93, BD-FR-96, BD-A-06)
- Given runbook step 5 has run on the VM
- Then `restic-server.service` is active
- And the command line from `podman inspect` contains `--private-repos`, `--append-only` and `--max-size 107374182400`
- And `podman top restic-server huser` prints `id -u restic-server`, which is not 0
- And `getent passwd restic-server` shows a UID below 1000 and the shell `/usr/sbin/nologin`
- And the Quadlet `Volume=` line for the data directory ends in `:Z`

Scenario BD-AC-40 [V]: Data directory, htpasswd, labels and secrets (BD-FR-94, BD-FR-95, BD-FR-97 to BD-FR-100, BD-FR-107, BD-FR-160, BD-A-11)
- Given SELinux enforcing on the VM, and `ls -Zd /mnt/data/samba` saved before `restic-server` first starts
- Then `stat -c '%a %U:%G' /mnt/data/restic-repos` prints `700 restic-server:<its group>` (BD-FR-94, BD-FR-95)
- And `findmnt -T /mnt/data/restic-repos -no TARGET` prints `/mnt/data`, and the path is not below `/mnt/data/samba`, `/mnt/data/.snapshots` or `/mnt/data/.btrbk` (BD-FR-97)
- And the htpasswd file has one `$2y$`/`$2b$` hash per client, with mode `600` and owner `restic-server` (BD-FR-98, BD-FR-99)
- And `rpm -q python3<minor>-passlib` succeeds for Ansible's discovered interpreter (BD-FR-100)
- And `grep -rlF` over the Quadlet file and `/etc/systemd/system/` finds no client password and no repository password (BD-FR-107)
- And after `restic-server` has started, `ls -Zd /mnt/data/samba` equals the saved value (BD-FR-160)

Scenario Outline BD-AC-41 [V]: Missing rest-server inputs fail before any change (BD-FR-101 to BD-FR-103)
- When the operator runs `site.yml --tags restic_server -e '<override>'`
- Then the play fails before any `restic_server` task reports `changed`, with a message naming `<named>`
- Examples: `restic_server_clients=[]` names `restic_server_clients` and `roles/restic_server/README.md`; a `cloud` entry with an empty password names `cloud`; `restic_server_maintenance_repo_password=""` names that variable

Scenario BD-AC-42 [V]: Authentication and repository isolation (BD-FR-89, BD-FR-98)
- Given the VM's client has run `restic init` on `rest:http://cloud:<pw>@<VM IP>:8000/cloud/`
- When `curl -s -o /dev/null -w '%{http_code}' -u <credentials> http://<VM IP>:8000/<path>` runs
- Then `cloud:<wrong>` on `cloud/config` gives `401`, `cloud:<pw>` on `cloud/config` gives `200`, and `cloud:<pw>` on `other/config` gives `401` or `403`

Scenario BD-AC-43 [V]: Password rotation takes effect within 60 s (BD-FR-104, BD-FR-105)
- When the operator changes the fixture client password and runs `site.yml --tags restic_server`
- Then within 60 s after the play ends, the new password gives `200` and the old one gives `401`

Scenario BD-AC-44 [V]: The size limit stops a client from filling the disk (BD-FR-91)
- Given `restic_server_max_size_bytes: 104857600` (100 MiB) has been applied
- When the client runs `restic backup` on 200 MiB of random data
- Then `restic backup` exits non-zero, and `du -sb /mnt/data/restic-repos` is at most 104857600 plus 1048576

Scenario BD-AC-45 [V]: Firewall rules admit both allowed source ranges and nothing else (BD-FR-108 to BD-FR-111, BD-A-05)
- Given the fixture `restic_server_allowed_sources` = the VM network's CIDR and the CIDR of a test Podman network `ac45-allowed`
- Then `firewall-cmd --list-rich-rules` (runtime and `--permanent`) shows one rule per allowed CIDR, and `--list-ports` and `--list-services` do not include `8000/tcp`
- And `curl -s -m 5 -o /dev/null -w '%{http_code}' http://<VM IP>:8000/` prints `401` in both allowed cases:
  - from a client on the VM network;
  - from `podman run --rm --network ac45-allowed docker.io/curlimages/curl:<pinned tag> ...`.
- And the same request from `podman run --rm --network podman ...` (default network, trusted zone, BD-A-23) prints `401`, not `200`: authentication still applies
- And the request from an external source after its rich rule is removed prints `000`

Scenario BD-AC-46 [V]: Append-only blocks deletion by the client (BD-FR-90, BD-BR-06, BD-A-03)
- When the client runs `restic backup /etc/hostname` (snapshot X), then `restic forget X`
- Then `restic forget` exits non-zero, and `restic snapshots` still lists X
- And `restic check` run by the client exits 0

Scenario Outline BD-AC-47 [V]: The prune guard rejects forged snapshot times (BD-FR-114 to BD-FR-116, BD-BR-07, BD-A-21)
- Given the client has at least 3 genuine snapshots, then runs `restic backup --time "<time>" /etc/hostname` (snapshot F), and the operator notes `restic snapshots --json | jq length`
- When the operator starts `restic-server-maintenance.service`
- Then the unit ends `failed`, and an alert is raised (BD-FR-115)
- And the snapshot count is unchanged, so nothing was forgotten (BD-FR-114)
- And the journal lists F's ID (BD-FR-116)
- Examples: `<time>` = now + 2 days; `<time>` = now - 3 days

Scenario BD-AC-48 [V]: A maintenance run applies retention and checks the repository (BD-FR-106, BD-FR-112, BD-FR-117, BD-FR-118, BD-BR-08, BD-A-11)
- Given genuine client snapshots only
- When the operator starts `restic-server-maintenance.service`
- Then `Result=success`, and `rpm -q restic` succeeds
- And the journal shows the script's line `retention policy: keep 7 daily, 4 weekly, 6 monthly snapshots; forgetting N verified snapshot(s)`, prune output, and `no errors were found`
- And `find /mnt/data/restic-repos/cloud ! -user restic-server` prints nothing
- And the next client `restic backup` exits 0

Scenario BD-AC-49 [V]: The maintenance run waits for a lock (BD-FR-120)
- When the operator, as `restic-server`, holds `restic mount /tmp/m` on the repository, starts the maintenance run with `--no-block`, and stops the mount after 2 min
- Then at 2 min the unit is `activating`, and within 30 min it ends with `Result=success`

Scenario BD-AC-50 [V]: A failing maintenance run raises an alert (BD-FR-119)
- When the operator changes the password in the maintenance password file by hand and starts the run
- Then the unit ends `failed`, and an alert is raised
- And `site.yml --tags restic_server` restores the file, reporting `changed` for it

Scenario BD-AC-51 [V]: The maintenance run never creates a repository (BD-FR-121)
- When the operator renames `/mnt/data/restic-repos/cloud` to `cloud.x` and starts the run
- Then the unit ends `failed`, and `/mnt/data/restic-repos/cloud/config` does not exist

Scenario BD-AC-52 [V]: The maintenance password stays out of unit files (BD-FR-113)
- Then `systemctl cat restic-server-maintenance.service | grep -cF '<password>'` prints `0`
- And the unit's `EnvironmentFile=` file is `600 root:root`

Scenario BD-AC-53 [Deleted in v3.0]: was the `restic-repos` snapper config check. That config no longer exists (BD-FR-122).

Scenario BD-AC-54 [V]: A wrong prune is undone from a snapper `data` snapshot (BD-BR-07, BD-FR-114, BD-FR-149 row DOC-O7)
- Given the client has 5 snapshots, `snapper -c data create` has made snapshot N, and the operator then runs `restic forget --keep-last 1 --prune` by hand as `restic-server`
- When the operator follows DOC-O7 with `/mnt/data/.snapshots/<N>/snapshot/restic-repos/cloud`
- Then `restic check --read-data` exits 0, `restic snapshots` lists 5 snapshots, and the next client backup exits 0
- And the next `restic-server-maintenance.service` run ends with `Result=success`, because the restore preserved modification times (BD-FR-114)

The [H] checks for this area are BD-AC-80 rows 7-9 in [backup-overview.md](backup-overview.md#acceptance-criteria) and BD-AC-81 in [backup-cutover-and-decommission.md](backup-cutover-and-decommission.md#acceptance-criteria).

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| BD-FR-87, BD-FR-89 to BD-FR-93, BD-FR-96 | test [V], smoke [H] | BD-AC-39, BD-AC-80 row 8 |
| BD-FR-88 | inspection [S] | BD-AC-08 |
| BD-FR-89, BD-FR-98 (behaviour) | test [V] | BD-AC-42 |
| BD-FR-90, BD-BR-06 (behaviour) | test [V] | BD-AC-46 |
| BD-FR-91 (behaviour) | test [V] | BD-AC-44 |
| BD-FR-94, BD-FR-95, BD-FR-97 to BD-FR-100, BD-FR-107, BD-FR-160 | test [V], smoke [H] | BD-AC-40, BD-AC-80 row 9 |
| BD-FR-101 to BD-FR-103 | test [V] | BD-AC-41 |
| BD-FR-104, BD-FR-105 | test [V] | BD-AC-43 |
| BD-FR-106, BD-FR-112, BD-FR-117, BD-FR-118, BD-BR-08 | test [V], smoke [H] | BD-AC-48, BD-AC-81 |
| BD-FR-108 to BD-FR-111 | test [V], smoke [H] | BD-AC-45, BD-AC-80 row 7, BD-AC-81 |
| BD-FR-113 | test [V] | BD-AC-52 |
| BD-FR-114 to BD-FR-116, BD-BR-07 | test [V] | BD-AC-47, BD-AC-54 |
| BD-FR-119 | test [V] | BD-AC-50 |
| BD-FR-120 | test [V] | BD-AC-49 |
| BD-FR-121 | test [V] | BD-AC-51 |
| BD-BR-09 | inspection [S] | BD-AC-09 |
| BD-BR-10 | inspection [S] | BD-AC-13 row DOC-O9 |

### Non-Functional Requirements

See [backup-overview.md](backup-overview.md#non-functional-requirements) (BD-NFR-06, BD-NFR-07 and BD-NFR-09 apply here).

### Out of Scope

See [backup-overview.md](backup-overview.md#out-of-scope).

### Open Questions

None.
