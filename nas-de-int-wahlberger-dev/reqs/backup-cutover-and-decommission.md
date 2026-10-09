## Feature: Local backup disk, btrbk, and NAS-hosted restic REST server (cut-over, decommission, wiring)
status:            ready
priority:          must
version:           3.0
quality:           feature-level scores in [backup-overview.md](backup-overview.md)

### Problem Statement

This file covers:
- the production cut-over runbook;
- the cut-over flags that let the feature commit be merged before the cut-over;
- the retirement of the NAS→Pi restic job;
- the cloud-wahlberger-dev changes;
- the playbook wiring, documentation and test fixtures (render check, VM fixture inventory).

Terms, decisions (BD-D-01, BD-D-07, BD-D-12, BD-D-13, BD-D-17), assumptions and NFRs are in [backup-overview.md](backup-overview.md). IDs from other files resolve through the [index.md ID map](index.md#id-map).

#### Primary flow

The production cut-over runbook, documented in the NAS `README.md` (BD-FR-147). It is not executed in this cycle.

0. Every [V] scenario passes on the VM fixture at the commit to be deployed (BD-BR-01).
1. Preconditions; stop unless all hold (BD-A-09, BD-A-16):
   - `lsblk -bdno SIZE <by-id path>` is within 1 % of `backup_disk_expected_size_bytes`;
   - the first and last 1 MiB of the disk read as zeros (`cmp -n 1048576 /dev/zero ...`);
   - the free space on `/mnt/data` is at least 3x the size of the Pi's cloud repository (`du -sb /mnt/data/restic-repos/cloud` on the Pi);
   - the used space of `/mnt/data` + `/mnt/containers` + the Pi's cloud repository is at most 50 % of the backup disk.
2. Run `ansible-playbook backup_disk_init.yml --check -e backup_disk_init_confirm=<by-id path>` and review the output. Then run the same command without `--check`.
3. In `vars.yml`, set `backup_disk_uuid` to the printed UUID and `backup_disk_enabled: true`. Run `site.yml --tags backup_disk`.
4. Run `osc signkey filesystems | gpg --show-keys --with-fingerprint` and confirm the fingerprint equals `btrbk_zypper_repo_gpg_fingerprint`; do not continue otherwise. Then run `site.yml --tags db_dump,btrbk`, then `btrbk -n run`, then `systemctl start btrbk.service`, and check the step-4 smoke rows of BD-AC-80.
5. Set `restic_backup_decommission_enabled: true` in `vars.yml` and run the full `site.yml`. This removes the old restic job and deploys rest-server, the maintenance timer and the health check.
6. Migrate the cloud repository:
   - stop `restic-backup.timer` on cloud and confirm the service is inactive;
   - confirm `restic list locks` is empty on the Pi;
   - run `rsync -a --numeric-ids pi:/mnt/data/restic-repos/cloud/ nas:/mnt/data/restic-repos/cloud/`;
   - run `chown -R restic-server: /mnt/data/restic-repos/cloud`;
   - run `restic check --read-data` as `restic-server`;
   - compare the snapshot counts on the Pi and the NAS.
7. Cloud cut-over change: add `restic_backup_rest_server_host: nas.de.int.wahlberger.dev` and `restic_backup_forget_enabled: false` to cloud's `vars.yml`. Run cloud `site.yml --tags restic_backup`, start one cloud backup, then start one maintenance run on the NAS (BD-AC-81).

### Actors

See [backup-overview.md](backup-overview.md#actors). Main actors here: the owner, cloud-wahlberger-dev, pi-de-int-wahlberger-dev (not changed) and the NAS host.

### Functional Requirements

#### B. Cut-over flag (`backup_disk_enabled`)
- BD-FR-17 [Must]: `vars.yml` at the feature commit shall set `backup_disk_enabled: false`, with a comment naming runbook step 3 as the step that sets it to `true`.
- BD-FR-18 [Must]: While `backup_disk_enabled` is `false`, a normal run shall report every task of the roles `backup_disk`, `btrbk`, `db_dump` and `restic_server` as `ok` or `skipped`.
- BD-FR-19 [Deleted in v3.0]: was the gating of the snapper `restic-repos` config, which no longer exists.

#### F. Retirement of the NAS→Pi restic backup
- BD-FR-77 [Must]: `site.yml` shall contain no `restic_backup` role entry.
- BD-FR-78 [Must]: The repository shall contain no `nas-de-int-wahlberger-dev/roles/restic_backup/` directory.
- BD-FR-79 [Must]: When a normal run with `restic_backup_decommission_enabled: true` ends, no `restic-backup.timer` unit shall exist on the host.
- BD-FR-80 [Must]: When a normal run with `restic_backup_decommission_enabled: true` ends, no `restic-backup.service` unit shall exist on the host.
- BD-FR-81 [Must]: When a normal run with `restic_backup_decommission_enabled: true` ends, none of `/usr/local/bin/restic-backup.sh`, `/etc/restic-backup` and `/var/lib/restic-backup` shall exist.
- BD-FR-82 [Must]: When none of the files of BD-FR-79 to BD-FR-81 exists, the `restic_backup_decommission` tasks shall report no change.
- BD-FR-83 [Must]: No task added or changed by this feature shall connect to `pi.de.int.wahlberger.dev` or modify a repository on the Pi.
- BD-FR-84 [Must]: `vars.yml` shall contain no `restic_backup_*` variable.
- BD-FR-85 [Must]: The encrypted `vault.yml` shall keep `vault_restic_backup_repo_password` and `vault_restic_backup_rest_server_password`.
- BD-FR-86 [Must]: `vault.yml.example` shall keep a placeholder for each BD-FR-85 key. Each placeholder shall have a comment stating that the key is kept only to restore from the Pi's frozen `nas` repository.

#### K. cloud-wahlberger-dev
- BD-FR-124 [Must]: While the new cloud role variable `restic_backup_forget_enabled` (default `true`) is `false`, the rendered `/usr/local/bin/restic-backup.sh` shall contain no `restic forget` command and no `restic prune` command.
- BD-FR-125 [Must]: The rendered cloud `restic-backup.sh` shall run `restic check --read-data-subset=<restic_backup_check_read_data_subset>` whatever the value of `restic_backup_forget_enabled`.
- BD-FR-126 [Must]: cloud's effective `restic_backup_on_calendar` at the feature commit shall be `*-*-* 04:30:00` (owner Q3).
- BD-FR-127 [Must]: cloud's effective `restic_backup_paths` (`["/opt/podman"]`) and `restic_backup_exclude` (`[]`) shall be unchanged.
- BD-FR-128 [Must]: With the runbook step 7 values (`restic_backup_rest_server_host: nas.de.int.wahlberger.dev`, `restic_backup_forget_enabled: false`), the rendered cloud `RESTIC_REPOSITORY` shall be `rest:http://cloud:<password>@nas.de.int.wahlberger.dev:8000/cloud/`.
- BD-FR-129 [Should]: The cloud `roles/restic_backup/README.md` shall contain the DOC-K1 item of BD-AC-13.
- BD-FR-130 [Should]: The cloud `roles/restic_backup/README.md` shall contain the DOC-K2 item of BD-AC-13.
- BD-FR-131 [Must]: No file under `pi-de-int-wahlberger-dev/` shall change in this feature.

#### L. Wiring, documentation and test fixtures (NAS)
- BD-FR-132 [Must]: `site.yml` shall list `backup_disk` after `storage` and before `snapper`.
- BD-FR-133 [Must]: `site.yml` shall list `restic_server` after `firewall`, `podman` and `storage`.
- BD-FR-134 [Must]: `site.yml` shall list `db_dump` after `paperless_ngx`, `immich`, `tandoor` and `forgejo`.
- BD-FR-135 [Must]: `site.yml` shall list `btrbk` after `db_dump` and `backup_disk`.
- BD-FR-136 [Must]: Each `site.yml` entry for `backup_disk`, `btrbk`, `db_dump`, `restic_server` and `restic_backup_decommission` shall carry `tags: [<role name>]`.
- BD-FR-137 [Must]: The encrypted `vault.yml` shall contain `vault_restic_server_cloud_htpasswd_password` and `vault_restic_server_cloud_repo_password`.
- BD-FR-138 [Must]: `vars.yml` shall define `restic_server_clients` as the single entry `{username: cloud, password: "{{ vault_restic_server_cloud_htpasswd_password | default('') }}"}`.
- BD-FR-139 [Must]: `vars.yml` shall define `restic_server_maintenance_repo_password: "{{ vault_restic_server_cloud_repo_password | default('') }}"`.
- BD-FR-140 [Must]: `vault.yml.example` shall contain a placeholder for each BD-FR-137 key, commented with the cloud-wahlberger-dev key whose value it must equal (BD-BR-09).
- BD-FR-141 [Must]: `vars.yml` shall define `restic_server_allowed_sources: ["10.10.0.0/16", "10.243.0.0/16"]` and derive `firewall_rich_rules` from it, with a comment naming the home LAN and ZeroTier ranges and stating that the rule port must equal `restic_server_port`.
- BD-FR-142 [Must]: Each new role (`backup_disk`, `btrbk`, `db_dump`, `restic_server`, `restic_backup_decommission`) shall declare every variable of its `defaults/main.yml` in `meta/argument_specs.yml`, with `type` and `description`.
- BD-FR-143 [Must]: `roles/backup_disk/meta/argument_specs.yml` shall have the entry points `main` and `init`.
- BD-FR-144 [Must]: `roles/firewall/meta/argument_specs.yml` shall declare `firewall_rich_rules`.
- BD-FR-145 [Must]: Each new role's `README.md` shall contain the DOC-R items of BD-AC-13.
- BD-FR-146 [Must]: `CLAUDE.md` shall contain the DOC-C items of BD-AC-13.
- BD-FR-147 [Must]: `README.md` shall contain the DOC-N items (the cut-over runbook) of BD-AC-13.
- BD-FR-148 [Must]: `roles/backup_disk/README.md` shall contain the DOC-B items of BD-AC-13.
- BD-FR-149 [Must]: The NAS documentation shall contain the DOC-O items (operations and restore) of BD-AC-13.
- BD-FR-150 [Must]: `molecule/default/converge.yml` shall contain, for each new role it does not converge, a comment naming why.
- BD-FR-151 [Could]: `molecule/default/converge.yml` shall converge `restic_backup_decommission`.
- BD-FR-152 [Should]: No line in `nas-de-int-wahlberger-dev/` outside `reqs/` and `PLAN.md` shall describe `restic_backup` or `restic-backup.service` as deployed on the NAS.
- BD-FR-153 [Must]: `roles/tandoor/README.md` shall contain the DOC-T item of BD-AC-13.
- BD-FR-154 [Must]: The repository shall contain the render check `nas-de-int-wahlberger-dev/tests/render-check.sh`, which needs no live host. It renders the btrbk configuration and every systemd unit and timer template of this feature with the fixture overrides, then runs `btrbk -c <file> config print` and `systemd-analyze verify` in a disposable openSUSE Tumbleweed container.
- BD-FR-155 [Must]: The repository shall contain the VM fixture inventory `inventories/vm/`: a group `nas` with one host, the fixture overrides, and a README with the DOC-V items of BD-AC-13.
- BD-FR-156 [Must]: No file under `inventories/vm/` shall contain a value from the production `vault.yml`.

#### M. Decommission flag
- BD-FR-157 [Must]: `vars.yml` at the feature commit shall set `restic_backup_decommission_enabled: false`, with a comment naming runbook step 5 as the step that sets it to `true`.
- BD-FR-158 [Must]: While `restic_backup_decommission_enabled` is `false`, a normal run shall report every task of `restic_backup_decommission` as `ok` or `skipped`, whatever the value of `backup_disk_enabled`.

### Business Rules

- BD-BR-13: The Pi is not changed. Its `nas` and `cloud` repositories stay as frozen fallbacks; decommissioning it is a separate follow-up.
- BD-BR-14: Cut-over order:
  1. `restic_backup_decommission_enabled` is set to `true`, which removes the old NAS→Pi job (step 5), only after the first btrbk run has exited 0 (step 4).
  2. cloud is switched (step 7) only after the migrated repository has passed `restic check --read-data` on the NAS (step 6).

### Inputs

| Name | Type | Required | Constraints |
|---|---|---|---|
| `backup_disk_enabled` | bool | yes | Cut-over flag. `false` at the feature commit (BD-FR-17); `true` from step 3 |
| `restic_backup_decommission_enabled` | bool | yes | Cut-over flag. `false` at the feature commit (BD-FR-157); `true` from step 5 |
| `vault_restic_server_cloud_htpasswd_password`, `vault_restic_server_cloud_repo_password` | str (Vault) | yes | Equal to cloud's keys (BD-BR-09); the htpasswd value reuses the Pi's current value (BD-A-13) |
| cloud `restic_backup_forget_enabled` | bool | no | Role default `true`; `false` from runbook step 7 |
| cloud `restic_backup_rest_server_host` | str | no | `pi.de.int.wahlberger.dev` until step 7, then `nas.de.int.wahlberger.dev` |
| cloud `restic_backup_on_calendar` | str | no | `*-*-* 04:30:00` from the feature commit |

### Outputs

| Name | Type | Constraints |
|---|---|---|
| Host without the old restic job | Host state | BD-FR-79 to BD-FR-81 |
| cloud: rendered env file, script and timer | Files | BD-FR-124 to BD-FR-128 |
| `site.yml`, `vars.yml`, `vault.yml(.example)` changes | Repository files | BD-FR-132 to BD-FR-141, BD-FR-157 |
| Documentation, render check, `inventories/vm/` | Repository files | BD-FR-145 to BD-FR-156 |

### Error Cases

| Condition | Expected behaviour |
|---|---|
| Normal run before the cut-over (both flags `false`) | The four backup roles and the decommission role report only `ok`/`skipped` (BD-FR-18, BD-FR-158). The old NAS→Pi job keeps running |
| `restic_backup_decommission_enabled: true` set before the first btrbk run succeeded | Violates BD-BR-14. The runbook's "do not continue unless" check (DOC-N4) prevents it |
| cloud switched to the NAS before the migration | cloud's bootstrap would create an empty repository. BD-BR-14 prevents this. DOC-N5 gives the recovery: stop cloud's timer, delete the new directory, migrate |
| NAS rebooted outside the rebootmgr window during cloud's 04:30 run | cloud's run fails and cloud alerts; the next night succeeds |
| Rollback needed | DOC-N5: revert cloud's step-7 vars; `git revert` of the feature commit restores the NAS restic job |

### Acceptance Criteria

Scenario BD-AC-05 [S]: Role order and tags (BD-FR-132 to BD-FR-136)
- When the operator runs `ansible-playbook site.yml --list-tasks` and `--tags <role> --list-tasks` for each new role
- Then the first task of each role appears in this order:
  - `storage` < `backup_disk` < `snapper`;
  - `firewall`, `podman`, `storage` < `restic_server`;
  - `paperless_ngx`, `immich`, `tandoor`, `forgejo` < `db_dump` < `btrbk`;
  - `backup_disk` < `btrbk`.
- And each `--tags <role>` listing contains that role's tasks

Scenario BD-AC-06 [S]: Argument specs (BD-FR-142 to BD-FR-144)
- When the operator compares each new role's `defaults/main.yml` with its `meta/argument_specs.yml`
- Then every default is declared with `type` and `description`; `backup_disk` has the entry points `main` and `init`; `firewall` declares `firewall_rich_rules`

Scenario BD-AC-07 [S]: The render check passes (BD-FR-154, BD-FR-23, BD-FR-27, BD-FR-33, BD-FR-43, BD-FR-44, BD-FR-57, BD-FR-58, BD-A-07)
- Given Docker or Podman on the control machine
- When the operator runs `tests/render-check.sh` in `nas-de-int-wahlberger-dev/` (fixture overrides), then `tests/render-check.sh -e backup_disk_hdparm_spindown=120`
- Then both exit 0
- And `btrbk -c <rendered> config print` shows, for both sources, `snapshot_dir .btrbk`, `snapshot_preserve_min 2d`, `snapshot_preserve no`, `target_preserve 14d 8w 12m 3y` and `target_preserve_min no`
- And `systemd-analyze verify` reports no error for any rendered unit or timer
- And the rendered units carry every BD-BR-05 property and every BD-BR-04 `RequiresMountsFor=` path
- And the option string the mount task passes equals BD-FR-23's string
- And with spindown 120, the boot-time mechanism runs `hdparm -S 120 <device>`, and the smartd line contains `-n standby`

Scenario BD-AC-09 [S]: Vars, vault and flag wiring (BD-FR-17, BD-FR-45, BD-FR-84 to BD-FR-86, BD-FR-109, BD-FR-137 to BD-FR-141, BD-FR-157, BD-BR-09)
- Given `vars.yml`, `vault.yml.example`, and the decrypted NAS and cloud `vault.yml` files
- Then `vars.yml` sets `backup_disk_enabled: false` with the step-3 comment (BD-FR-17), and `restic_backup_decommission_enabled: false` with the step-5 comment (BD-FR-157)
- And `disk_space_paths` lists `/`, `/mnt/data`, `/mnt/containers` and `/mnt/backup/btrbk` (BD-FR-45)
- And `grep -nE '^\s*restic_backup_' vars.yml` prints nothing (BD-FR-84)
- And the NAS `vault.yml` has the two BD-FR-85 keys and the two BD-FR-137 keys, and `vault.yml.example` has placeholders for all four, with the BD-FR-86 and BD-FR-140 comments
- And `vars.yml` defines `restic_server_clients` and `restic_server_maintenance_repo_password` exactly as BD-FR-138 and BD-FR-139 state
- And `restic_server_allowed_sources` is `["10.10.0.0/16", "10.243.0.0/16"]`, and `firewall_rich_rules` evaluates to one BD-FR-109 rule per entry, with the BD-FR-141 comment
- And the decrypted values meet both BD-BR-09 equalities

Scenario BD-AC-10 [S]: The NAS restic_backup role is gone (BD-FR-77, BD-FR-78)
- When the operator runs `git ls-files nas-de-int-wahlberger-dev/roles/restic_backup` and `grep -nE 'role:\s*restic_backup\b' nas-de-int-wahlberger-dev/site.yml`
- Then both print nothing

Scenario BD-AC-11 [S]: The Pi is untouched and never contacted (BD-FR-83, BD-FR-131, BD-BR-13)
- When the operator runs `git diff master --stat -- pi-de-int-wahlberger-dev` and `git diff master -- nas-de-int-wahlberger-dev cloud-wahlberger-dev ':(exclude)*.md' | grep -E '^\+.*pi\.de\.int\.wahlberger\.dev'`
- Then the first prints nothing
- And the second matches only cloud's pre-cut-over default `restic_backup_rest_server_host`, if that line is touched at all

Scenario Outline BD-AC-12 [S]: cloud renders as specified (BD-FR-124 to BD-FR-128)
- Given `cloud-wahlberger-dev/` at the feature commit, `D` = an empty scratch directory, and the Vault password available through `ansible.cfg`
- When the operator runs this command once for each template `t` in `restic-backup.env`, `restic-backup.sh` and `restic-backup.timer`:
  `ansible localhost -c local -e @roles/restic_backup/defaults/main.yml -e @inventories/production/group_vars/all/vault.yml -e @inventories/production/group_vars/all/vars.yml <overrides> -m ansible.builtin.template -a "src=$PWD/roles/restic_backup/templates/<t>.j2 dest=$D/<t>"`
- Then the rendered files show `<expectation>`
- And in both rows:
  - `$D/restic-backup.sh` contains `restic check --read-data-subset=10%` (BD-FR-125);
  - `$D/restic-backup.timer` contains `OnCalendar=*-*-* 04:30:00` (BD-FR-126);
  - the script's backup paths and excludes are `/opt/podman` and none (BD-FR-127).
- Examples:

| Row | `<overrides>` | `<expectation>` |
|---|---|---|
| 1 (feature commit) | none | `RESTIC_REPOSITORY` host is `pi.de.int.wahlberger.dev`; the script contains `restic forget` |
| 2 (runbook step 7) | `-e restic_backup_rest_server_host=nas.de.int.wahlberger.dev -e restic_backup_forget_enabled=false` | `RESTIC_REPOSITORY=rest:http://cloud:<password>@nas.de.int.wahlberger.dev:8000/cloud/` (BD-FR-128); the script contains no `restic forget` and no `restic prune` (BD-FR-124) |

Scenario Outline BD-AC-13 [S]: Documentation contains one required item (BD-FR-129, BD-FR-130, BD-FR-145 to BD-FR-149, BD-FR-153, BD-FR-155, BD-BR-01, BD-BR-10, BD-BR-14)
- When the operator reads `<file>`
- Then it contains `<item>`
- Examples (one test per row):

| ID | `<file>` | `<item>` |
|---|---|---|
| DOC-R1 | each new role's `README.md` | A purpose section |
| DOC-R2 | each new role's `README.md` | A role variables section referring to `defaults/main.yml` |
| DOC-R3 | each new role's `README.md` | A "does not do" section |
| DOC-C1 | `CLAUDE.md` | Stack rows for `backup_disk`, `btrbk`, `db_dump`, `restic_server` and `restic_backup_decommission` |
| DOC-C2 | `CLAUDE.md` | No Stack row describing `restic_backup` as deployed |
| DOC-C3 | `CLAUDE.md` | A `notify_failure` row naming the BD-CC-09 units |
| DOC-C4 | `CLAUDE.md` "Data & secrets" | The backup disk and `/mnt/backup/btrbk`; the restic repositories at `/mnt/data/restic-repos` |
| DOC-C5 | `CLAUDE.md` "Data & secrets" | "Only `backup_disk_init.yml` formats the backup disk" |
| DOC-C6 | `CLAUDE.md` "Data & secrets" | The two BD-FR-137 keys, and the two BD-FR-85 keys with their restore-only reason |
| DOC-C7 | `CLAUDE.md` "Entry point & commands" | `tests/render-check.sh` and the `-i inventories/vm` command line |
| DOC-N1 | `README.md` "Backups" | Runbook steps 0-7 in order, each with its exact command |
| DOC-N2 | `README.md` "Backups" | Step 1 checks: size within 1 %, zero first and last MiB, `/mnt/data` free space at least 3x the Pi's cloud repository, the 50 % backup-disk rule |
| DOC-N3 | `README.md` "Backups" | Migration commands: stop and verify cloud's timer; `restic list locks` on the Pi; `rsync -a --numeric-ids pi:/mnt/data/restic-repos/cloud/ nas:/mnt/data/restic-repos/cloud/`; `chown -R restic-server:`; `restic check --read-data` as `restic-server`; snapshot-count comparison |
| DOC-N4 | `README.md` "Backups" | The BD-BR-01 and BD-BR-14 gates as "do not continue unless" checks |
| DOC-N5 | `README.md` "Backups" | Rollback: cloud back to the Pi by reverting the step-7 vars (snapshots taken on the NAS after migration are not on the Pi); the NAS restored to restic by `git revert` of the feature commit; recovery from a cloud switched before migration |
| DOC-N6 | `README.md` "Backups" | The cut-over flags, and the statement that the Pi stays unchanged |
| DOC-N7 | `README.md` "Backups" | Step 4's `osc signkey filesystems` fingerprint cross-check, as a "do not continue unless" check |
| DOC-B1 | `roles/backup_disk/README.md` | The init command, first with `--check`, then without |
| DOC-B2 | `roles/backup_disk/README.md` | The R-01 to R-10 table and the initialised-state definition (`@btrbk` only) |
| DOC-B3 | `roles/backup_disk/README.md` | How to set `backup_disk_expected_size_bytes` from `lsblk -bdno SIZE` |
| DOC-B4 | `roles/backup_disk/README.md` | Partial-init recovery: verify the by-id path and size, run `wipefs -a <by-id path>` by hand, re-run the init |
| DOC-B5 | `roles/backup_disk/README.md` | `ansible-playbook site.yml --skip-tags backup_disk,btrbk` for use while the disk is dead |
| DOC-O1 | NAS docs | Restoring one file from `/mnt/backup/btrbk/<source>/<snapshot>/` |
| DOC-O2 | NAS docs | Restoring a whole source subvolume with btrfs send/receive |
| DOC-O3 | NAS docs | Restoring a database from `/mnt/containers/db-dumps/` |
| DOC-O4 | NAS docs | `restic restore`, run on cloud against the NAS rest-server |
| DOC-O5 | NAS docs | Restoring from the Pi's frozen `nas` repository with the BD-FR-85 keys |
| DOC-O6 | NAS docs | `restic unlock`, run as `restic_server_user` |
| DOC-O7 | NAS docs | Restoring the cloud repository: stop `restic-server` and the maintenance timer; copy the repository back with `cp -a` or `rsync -a` (owner and modification times preserved, so the prune guard BD-FR-114 still passes) from either `/mnt/data/.snapshots/<n>/snapshot/restic-repos/cloud` (snapper `data`) or `/mnt/backup/btrbk/data/<snapshot>/restic-repos/cloud`; start again; run `restic check` |
| DOC-O8 | NAS docs | What to do when the prune guard trips: inspect the listed IDs, remove forged snapshots by hand |
| DOC-O9 | `roles/restic_server/README.md` | The BD-BR-10 risk statement |
| DOC-O10 | NAS docs | Re-baselining after an owner-side `restic tag`, `restic rewrite` or `restic copy`: after verifying the snapshots, `touch -d "<recorded time>" <repository>/snapshots/<id>` for each new file, then a maintenance run |
| DOC-O11 | NAS docs | Renewing the `filesystems` repository key when `btrbk-key-refresh.service` alerts (BD-FR-166) or after expiry (2027-05-07): same fingerprint, remove the old `gpg-pubkey` package, run `site.yml --tags btrbk` and `systemctl start btrbk-key-refresh.service`; new fingerprint, verify with `osc signkey filesystems`, update `btrbk_zypper_repo_gpg_fingerprint` first (BD-FR-164). Confirm `zypper refresh` succeeds |
| DOC-O12 | `roles/restic_server/README.md` | The repository location decision (BD-D-08), its effect on snapper `data` and btrbk, and how to override `restic_server_data_dir` within BD-FR-97 |
| DOC-T | `roles/tandoor/README.md` | The rotation step `ansible-playbook site.yml --tags tandoor,db_dump`, and no `--tags tandoor,restic_backup` |
| DOC-K1 | cloud `roles/restic_backup/README.md` | With `restic_backup_forget_enabled: false`, the target is append-only and the NAS applies retention |
| DOC-K2 | cloud `roles/restic_backup/README.md` | 04:30 avoids the NAS rebootmgr window of 03:00-04:00 |
| DOC-V | `inventories/vm/README.md` | Commands that prepare the VM fixture: disks, `@data`/`@containers`, snapper configs, the fixture Postgres container and SQLite file, and the `ac45-allowed` Podman network |

Scenario BD-AC-14 [S]: No NAS document describes the old job as deployed (BD-FR-152)
- When the operator runs `grep -rn -i 'restic_backup\|restic-backup' nas-de-int-wahlberger-dev --exclude-dir=reqs --exclude=PLAN.md`
- Then every match is one of these:
  - in `roles/restic_backup_decommission/`;
  - about the Pi's frozen `nas` repository or the BD-FR-85 keys;
  - describing the job as removed.

Scenario BD-AC-16 [S]: The VM fixture holds no production secret (BD-FR-155, BD-FR-156)
- When the operator runs `grep -rF '<value>' nas-de-int-wahlberger-dev/inventories/vm/` for each value in the decrypted production `vault.yml`
- Then every search prints nothing (BD-FR-156)
- And `inventories/vm/hosts.yml` has exactly one host, in group `nas` (BD-FR-155)

Scenario BD-AC-25 [V]: Before the cut-over, nothing changes (BD-FR-18, BD-FR-158)
- Given `backup_disk_enabled: false`, `restic_backup_decommission_enabled: false`, no backup filesystem, and dummy `restic-backup.timer`/`.service` units plus the three BD-FR-81 paths
- When the operator runs `ansible-playbook -i inventories/vm site.yml`
- Then every task of `backup_disk`, `btrbk`, `db_dump`, `restic_server` and `restic_backup_decommission` reports `ok` or `skipped`, and the play shows `failed=0`
- And the dummy units and paths still exist

Scenario BD-AC-38 [V]: The old restic job is removed only by its own flag, idempotently (BD-FR-79 to BD-FR-82, BD-FR-158)
- Given the dummy units and paths of BD-AC-25, and `backup_disk_enabled: true`
- When the operator runs `site.yml` with `restic_backup_decommission_enabled: false`
- Then the dummy units and paths still exist (BD-FR-158)
- When the operator sets `restic_backup_decommission_enabled: true` and runs `site.yml`, then runs it again
- Then after the first of these runs, `systemctl cat restic-backup.timer` and `systemctl cat restic-backup.service` both report no such unit, and the three paths do not exist
- And in the second run, every `restic_backup_decommission` task reports `ok` or `skipped`

Scenario BD-AC-81 [H]: Migration, first cloud backup and first maintenance run (BD-FR-109, BD-FR-128, BD-BR-09, BD-BR-14, BD-A-03, BD-A-04, BD-A-10)
- Given runbook steps 1-5 have completed, and cloud's timer is stopped
- When the operator runs steps 6 and 7
- Then before step 7, `restic check --read-data` on `/mnt/data/restic-repos/cloud` exits 0, and `restic snapshots --json | jq length` is equal on the Pi and the NAS
- And cloud's `restic-backup.service`, connecting over ZeroTier from 10.243.0.0/16, ends with `Result=success`, including its `restic check`
- And `restic snapshots --latest 1` on the NAS shows a cloud snapshot from that run, and cloud's journal shows no `forget` output
- And `curl -s -o /dev/null -w '%{http_code}' http://nas.de.int.wahlberger.dev:8000/` from a LAN client in 10.10.0.0/16 prints `401`
- And the following `restic-server-maintenance.service` run ends with `Result=success`, and `find /mnt/data/restic-repos/cloud ! -user restic-server` prints nothing

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| BD-FR-17, BD-FR-157 | inspection [S] | BD-AC-09 |
| BD-FR-18, BD-FR-158 | test [V] | BD-AC-25, BD-AC-38 |
| BD-FR-77, BD-FR-78 | inspection [S] | BD-AC-10 |
| BD-FR-79 to BD-FR-82 | test [V] | BD-AC-38 |
| BD-FR-83, BD-FR-131, BD-BR-13 | inspection [S] | BD-AC-11 |
| BD-FR-84 to BD-FR-86, BD-FR-137 to BD-FR-141 | inspection [S] | BD-AC-09 |
| BD-FR-124 to BD-FR-128 | inspection [S], smoke [H] | BD-AC-12, BD-AC-81 |
| BD-FR-129, BD-FR-130, BD-FR-145 to BD-FR-149, BD-FR-153 | inspection [S] | BD-AC-13 (one row per item) |
| BD-FR-132 to BD-FR-136 | inspection [S] | BD-AC-05 |
| BD-FR-142 to BD-FR-144 | inspection [S] | BD-AC-06 |
| BD-FR-149 (DOC-O1, DOC-O7 behaviour) | demonstration [V], [H] | BD-AC-54, BD-AC-83 |
| BD-FR-150, BD-FR-151 | test [S] | BD-AC-03 |
| BD-FR-152 | inspection [S] | BD-AC-14 |
| BD-FR-154 | test [S] | BD-AC-07 |
| BD-FR-155, BD-FR-156 | inspection [S] | BD-AC-16, BD-AC-13 row DOC-V |
| BD-BR-14 | inspection [S] (runbook gates), demonstration [H] | BD-AC-13 row DOC-N4, BD-AC-81 |

### Non-Functional Requirements

See [backup-overview.md](backup-overview.md#non-functional-requirements) (BD-NFR-01 to BD-NFR-04, BD-NFR-06 and BD-NFR-12 apply here).

### Out of Scope

See [backup-overview.md](backup-overview.md#out-of-scope).

### Open Questions

None.
