## Plan: Local backup disk, btrbk, and NAS-hosted restic REST server          spec: nas-de-int-wahlberger-dev/reqs/index.md (backup-overview.md, backup-disk-init.md, backup-btrbk-and-db-dump.md, backup-restic-server.md, backup-cutover-and-decommission.md, v3.0)   planned: 2026-10-09   status: planned

Branch `feature/nas-backup-disk`. This file is separate from the older Tandoor plan (`PLAN.md`), which this plan never touches. All paths are relative to the repository root `ansible-playbooks/` unless they start with a role name or `tests/`, in which case they are relative to `nas-de-int-wahlberger-dev/` ("NAS dir"). Cloud paths are written `cloud-wahlberger-dev/...`.

### Assumptions / open risks

Execution constraints
- **No playbook runs against nas, cloud or pi** (BD-C-03). Verification is static ([S]: `yamllint`, `ansible-lint`, `--syntax-check`, `--list-tasks`, `grep`/`git diff` checks, `tests/render-check.sh`, `systemd-analyze verify` inside a disposable Tumbleweed container, `pytest` for the maintenance script) plus optional runs against a disposable VM fixture ([V]). The VM is not provisioned by this plan. VM tasks T-27 to T-30 are written so they can be executed as soon as the owner provides a VM; until then they stay `blocked: no VM` and the [V] scenarios are reported as "authored, statically verified, not executed". The production gate BD-BR-01 (runbook step 2) stays closed until T-27 to T-30 pass.
- **[H] scenarios (BD-AC-80 to BD-AC-87) are never run by an agent.** T-31 is the owner-run production validation and needs separate, explicit authorisation. "Simulator/VM-only" is never reported as production-verified.
- Local tooling: `yamllint`, `ansible-lint`, `ansible-playbook` (core 2.16), `docker` and `podman` exist. `systemd-analyze`, `btrbk` and `pytest` do not exist on the control machine: `systemd-analyze`/`btrbk` run inside the render-check container; `pytest` goes into a throwaway venv in the scratchpad (not committed).
- Working tree already has unrelated uncommitted edits (`roles/tandoor/defaults/main.yml`, `roles/mealie_decommission/README.md`, `PLAN.md`, `reqs/*`). No task here may touch `roles/tandoor/defaults/`, `roles/mealie_decommission/` or `PLAN.md`.

Global "must not touch" (applies to every task unless it explicitly owns the file)
- `pi-de-int-wahlberger-dev/**` (BD-FR-131), `roles/snapper/**` (BD-FR-64), `reqs/**`, `PLAN.md`, `PLAN-backup.md`.
- Hot shared files, writable only by the named serial tasks: `site.yml` (T-19, T-20), `inventories/production/group_vars/all/vars.yml` (T-19, T-20), `vault.yml.example` (T-19, T-20), `vault.yml` (owner action inside T-20, see below), `CLAUDE.md` (T-24), `README.md` (T-23), `molecule/default/converge.yml` (T-21), `.github/workflows/ci.yml` (T-25), `inventories/vm/group_vars/all/vars.yml` (T-01; later fixes only through T-19/T-20), `roles/restic_backup/` (deleted by T-19 only).
- `renovate.json` needs no change: the existing generic custom-manager regex already matches `restic_server_image: docker.io/restic/rest-server:0.14.0` (BD-AC-08 is verified by T-14, not edited).

Risks and decisions the plan makes (each is recoverable by the owner)
- **Spec defect, BD-AC-09 vs BD-FR-157.** BD-AC-09 says `grep -nE '^\s*restic_backup_' vars.yml` prints nothing, yet BD-FR-157 requires `vars.yml` to set `restic_backup_decommission_enabled: false`, which that grep matches. Plan treats BD-FR-157 as authoritative and verifies BD-FR-84 with `grep -nE '^\s*restic_backup_' vars.yml | grep -v '^[0-9]*:restic_backup_decommission_enabled:'`. The spec pattern should be fixed by `requirements-engineer`; it does not block planning. BD-AC-14 has the same near-conflict (flag line and the `restic_backup_decommission` role entry in `site.yml`); the plan counts them as "describing the job as removed" and puts that wording into their comments.
- **Flag gating lives in `site.yml`.** `backup_disk_enabled` and `restic_backup_decommission_enabled` are applied as `when:` on the role entries (not inside role tasks), so a disabled role reports only `skipped` tasks (BD-FR-18, BD-FR-158) and stays self-contained. `restic_backup_decommission` depends only on its own flag.
- **`vault.yml` is encrypted and its password comes from 1Password.** Agents cannot add `vault_restic_server_cloud_htpasswd_password` / `vault_restic_server_cloud_repo_password` (BD-FR-137, values must equal the Pi's / cloud's, BD-A-13, BD-BR-09). This is an **owner action** listed in T-20; agents add the `vars.yml` indirections and `vault.yml.example` placeholders, and BD-AC-09's decrypted-value checks stay `pending-owner` until the owner has done it.
- **A-05 (firewall vs Podman DNAT) and A-07 (btrbk snapshot dir) are unverified.** T-04 and T-03 are time-boxed spikes. If T-04 cannot get empirical evidence without a VM, its default recommendation is host networking for `restic-server`, because BD-FR-111 then holds by construction (INPUT chain). T-14 implements whatever T-04 records; BD-AC-45 in T-29 confirms.
- **Maintenance logic is a Python script, not shell.** The prune guard (BD-FR-114) and the forget/prune/check/lock sequence are fiddly and security relevant; a script with a fake `restic` and `pytest` gives a host-side closed verification loop. It is deployed by `restic_server`; no Python beyond the host's `python3` is required.
- **AC-04 greps cover every role file.** The destructive-command pattern of BD-AC-04 (a) is run over `roles/*/tasks|handlers|templates|files` and `site.yml`: outside `roles/backup_disk/tasks/init*.yml` no file may contain `mkfs`, `wipefs`, `parted`, `sfdisk`, `sgdisk`, `dd`, `blkdiscard`, `shred`, `cryptsetup`, `btrfs subvolume create|delete`, `btrfs device add|delete|remove`, `btrfs replace`, `chattr` or the community.general parted/filesystem/btrfs_subvolume modules, even in comments or README-in-templates. Static `include_*`/`import_*` file names only (BD-AC-04 (b)). Every role task must respect this.
- **Editing the forgejo Quadlet comment restarts Forgejo once.** BD-FR-152 requires removing the `roles/restic_backup` mention in `roles/forgejo/templates/forgejo.container.j2`; any change to a rendered Quadlet notifies the container restart handler. T-22 uses a Jinja comment and records the one-time restart in the forgejo README and the task log (low risk, home service).
- `db_dump` reads `btrbk_sources`, `storage_mounts` and `forgejo_volume_dir` from other roles' defaults. This works because role defaults of all roles in a play are visible to later roles (Ansible default `DEFAULT_PRIVATE_ROLE_VARS=false`); `ansible.cfg` must not set it. T-13 verifies with `--list-tasks`/`--syntax-check` plus a VM run (T-28).
- BD-A-09 capacity, BD-A-16 disk size, BD-A-17 key expiry (2027-05-07) are runbook/doc items (T-23), not code.
- Forgejo `forgejo.db` dumped with host `sqlite3` (package `sqlite3`); `db_dump` must install it (the old role did).
- CI runners (GitHub Actions ubuntu) have docker; the render-check job is added in T-25 and is the only CI change.
- Maximum parallelism is not constrained by the request; G1 has 11 file-disjoint tasks. The orchestrator should run G1 in at most 4 to 5 worktrees at a time (suggested order inside G1: T-07, T-11, T-13, T-15, T-04, T-03 first, then the rest).

### Definition of Done (all tasks)
- Code formatted and linted: from the NAS dir, `yamllint .` and `ansible-lint` (production profile) exit 0; `ansible-playbook site.yml --syntax-check` exits 0 (and `ansible-playbook backup_disk_init.yml --syntax-check` once T-07 exists); for cloud tasks the same in `cloud-wahlberger-dev/`. Role tasks that are not yet wired into `site.yml` are checked with `tests/syntax-check-role.sh <role>` (provided by T-01).
- Task acceptance criteria verified by qa-verifier; unit tests for new logic to the test-quality tier; no skipped/weakened tests; no new warnings; no `# noqa`, `skip_list`, `warn_list` (BD-NFR-03); docs/config updated; no secrets committed; no production vault value in `inventories/vm/`.
- Role conventions (BD-C-01, BD-FR-142): FQCN, ansible-core 2.16 module names, self-contained role (`defaults/`, `tasks/`, `meta/main.yml`, `meta/argument_specs.yml` declaring every default with `type` and `description`, `README.md` with a purpose section, a role-variables section referring to `defaults/main.yml`, and a "does not do" section), role-prefixed variables, no `meta/main.yml` dependencies, `community.general.zypper`, Quadlets through the `container` role.
- Every new unit/template is registered in the render check with a `tests/render.d/NN-<name>.yml` file, and `tests/render-check.sh` stays green.
- Tasks that name a `[V]` scenario implement it but do not claim it verified; that happens in T-27 to T-30.

### Execution order
Walking skeleton: **T-01** (render-check harness + VM fixture inventory + role syntax helper, proving container, rendering, `btrbk config print`, `systemd-analyze verify`, lint and syntax-check end to end on an existing template).

Parallel groups (all members file-disjoint; start a group when its dependencies are done):
- G1 (after T-01): {T-02, T-03, T-04, T-05, T-06, T-07, T-11, T-13, T-15, T-17, T-18}
- G2: {T-08 (after T-07), T-12 (after T-11, T-03), T-14 (after T-04)}
- G3: {T-09 (after T-08), T-16 (after T-14, T-15)}
- G4: {T-10 (after T-09)}
- G5 (serial hot-file task): {T-19} after T-05, T-06, T-10, T-12, T-13, T-17
- G6: {T-20, T-21, T-22} after T-19 (T-20 also after T-16; T-21 also after T-16)
- G7: {T-23, T-24, T-26} after T-20 (T-23 also after T-10, T-16, T-18)
- G8: {T-25} after T-21, T-22, T-23, T-24
- Sequential on one VM: T-27 -> T-28 -> T-29 -> T-30 (after T-25, T-26), then owner-run T-31.

Same-role chains are sequential by construction: backup_disk T-07 -> T-08 -> T-09 -> T-10; btrbk T-11 -> T-12; restic_server T-14 -> T-16 (T-15, the Python maintenance script, is a separate file set that T-16 consumes).

Critical path: T-01 -> T-07 -> T-08 -> T-09 -> T-10 -> T-19 -> T-20 -> T-23 -> T-25 -> T-27 -> T-28 -> T-29 -> T-30 -> T-31.
Spikes: T-03 (A-07), T-04 (A-05). Simulator-gated tasks: T-27 to T-30. Hardware (production) task: T-31, not executed this cycle.

### Tasks

#### T-01 — Walking skeleton: render-check harness, VM fixture inventory, role syntax helper          [ ] todo
- Type: skeleton
- Requirements: BD-FR-154, BD-FR-155, BD-FR-156, BD-NFR-02 (enabler for BD-FR-23/27/33/43/44/57/58, BD-AC-07, BD-AC-16)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G0
- Depends on: none
- Files owned (may modify): `tests/render-check.sh`, `tests/lib/**`, `tests/render.d/00-smoke.yml`, `tests/syntax-check-role.sh`, `inventories/vm/hosts.yml`, `inventories/vm/group_vars/all/vars.yml`    Must not touch: all roles, `site.yml`, production inventory
- Context: Everything later plugs into this. `tests/render-check.sh [-e k=v ...]` renders templates on the host with `ansible localhost -m template` using the fixture overrides, then verifies the output inside a disposable `opensuse/tumbleweed` container (docker or podman): `btrbk -c <file> config print` (btrbk installed from the OBS `filesystems` repo with its key fingerprint checked, which doubles as the first check of BD-A-01) and `systemd-analyze verify` for units/timers. Plug-in interface: each later task adds one file `tests/render.d/NN-<name>.yml` listing `{role, src, dest, kind: btrbk-conf|systemd-unit|text, vars}` and optional assertion lines (grep patterns). `inventories/vm/` holds one host in group `nas` and the fixture overrides listed in the spec Terms (backup_disk_device and size, storage_mounts, db_dump_postgres single `fixture` entry and db_dump_forgejo_db_path, restic_server_allowed_sources = VM CIDR plus the `ac45-allowed` Podman CIDR placeholders, test restic_server_clients / maintenance password / notify_failure_resend_api_key, backup_disk_freshness_checks, both cut-over flags true), with obviously fake test secrets.
- Acceptance criteria (verifiable):
  - [ ] Given Docker or Podman and no live host, when `tests/render-check.sh` runs with only `00-smoke.yml` registered (it renders the existing `roles/notify_failure/templates/notify-failure-immediate@.service.j2` and a hand-written minimal sample btrbk config), then it exits 0, `systemd-analyze verify` ran on the unit and `btrbk -c <sample> config print` ran in the container.
  - [ ] Given a deliberately broken unit file added temporarily to `tests/render.d/`, when the script runs, then it exits non-zero naming the file (negative test, not committed).
  - [ ] `tests/render-check.sh -e backup_disk_hdparm_spindown=120` passes extra vars through to the render step (exit 0, variable visible to templates).
  - [ ] `inventories/vm/hosts.yml` has exactly one host, in group `nas` (BD-FR-155); `grep -rF` of every value in the decrypted production `vault.yml` against `inventories/vm/` prints nothing (BD-FR-156; run only if the vault password is available, else mark pending-owner and grep for `vault_` indirections and known placeholder patterns instead).
  - [ ] `tests/syntax-check-role.sh backup_disk` (any role name) builds a temp playbook in a temp dir and runs `ansible-playbook -i inventories/vm --syntax-check` and `--list-tasks` for that role, exiting non-zero for a non-existent role.
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/render-check.sh -e backup_disk_hdparm_spindown=120 && yamllint . && ansible-lint && ansible-playbook -i inventories/vm --list-hosts site.yml`
- Gate: host    Risk/notes: container image pull and OBS key fetch need network; `systemd-analyze verify` complains about missing referenced units (`notify-failure-immediate@.service`, `db-dump.service`): the harness must render dependency stub units into the same verify directory. Reads production `vars.yml` only as non-secret context if needed; never commits decrypted values.

#### T-02 — VM fixture README (DOC-V)          [ ] todo
- Type: docs
- Requirements: BD-FR-155 (README part), BD-AC-13 row DOC-V
- Agent: docs-writer    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `inventories/vm/README.md`    Must not touch: everything else
- Context: Commands the owner runs to prepare a disposable Tumbleweed VM that matches the fixture overrides: btrfs root disk; two virtual disks formatted btrfs with `@data` and `@containers` mounted at `/mnt/data` and `/mnt/containers` plus snapper configs `data` and `containers`; a spare disk with a `/dev/disk/by-id/` path (the backup disk); one scratch disk; a fixture Postgres container and SQLite file; the `ac45-allowed` Podman network; how to point `inventories/vm/hosts.yml` at the VM; the run order of T-27 to T-30. States clearly that the VM is its own restic client and never nas, cloud or pi.
- Acceptance criteria (verifiable):
  - [ ] Given the README, when read, then it contains commands for each DOC-V item: disks, `@data`/`@containers` and snapper configs, fixture Postgres container, fixture SQLite file, `ac45-allowed` Podman network (BD-AC-13 DOC-V).
  - [ ] The by-id path, sizes, subvolume names, and fixture container/database/user names in the README equal the values in `inventories/vm/group_vars/all/vars.yml`.
  - [ ] No production hostname other than as a "never target" warning, and no secret value, appears in the README.
- Verification: `grep -n -E 'snapper|ac45-allowed|postgres|sqlite|by-id|@data|@containers' nas-de-int-wahlberger-dev/inventories/vm/README.md`; manual diff of names against `vars.yml`; `yamllint .` unaffected.
- Gate: host    Risk/notes: cannot be executed without a VM; correctness of the commands is proven in T-27 onwards (fix-ups come back through this task).

#### T-03 — Spike: btrbk snapshot directory layout (BD-A-07)          [ ] todo
- Type: spike
- Requirements: BD-A-07 (gates BD-FR-51 to BD-FR-56, BD-FR-161, BD-AC-07, BD-AC-30)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `tests/spikes/A-07-btrbk-snapshot-dir.md`    Must not touch: all roles
- Context: Decision needed before T-12: can btrbk keep `<source>/.btrbk` snapshot directories inside the mounted `@data`/`@containers` subvolumes without the btrfs top level being mounted, and what exact btrbk configuration does that? Time box 2 h. Method in order of preference: disposable VM (T-02 notes), else privileged container with loopback btrfs images (two filesystems, subvolumes `@data` and `@containers` mounted with `subvol=`, one target filesystem with `@btrbk`), else documentation reading, clearly labelled "unverified, confirm with BD-AC-30".
- Acceptance criteria (verifiable):
  - [ ] The file records a decision (A-07 holds, or fallback = extra mount of the top level that leaves `storage_mounts` unchanged) with the exact `btrbk.conf` directives (`volume`, `subvolume`, `snapshot_dir`, `target`, `lockfile`, retention keys) and how each evidence item was obtained (command output excerpt or doc reference) and its confidence (verified/unverified).
  - [ ] It answers: does a snapshot of `@data` that contains `.btrbk/` and a snapper `.snapshots` nested subvolume exclude both from the received copy (BD-FR-56); does `btrbk -n run` pass; does an incremental second run use the first as parent; does the `.btrbk` directory need pre-creation, ownership and mode.
  - [ ] It states what happens to snapshot dirs relative to `samba_data_dir` and `.snapshots` (BD-FR-52, BD-FR-53).
- Verification: reviewer reads the file; any claimed command output is reproducible with the stated commands in the same container/VM; no repository file other than the spike note changes (`git status --short`).
- Gate: host (container) or simulator (VM)    Risk/notes: Docker Desktop's kernel may lack btrfs; fall back to the VM or to a labelled desk study. Output is a decision for T-12, not production code.

#### T-04 — Spike: firewalld rich rules vs Podman-published port (BD-A-05)          [ ] todo
- Type: spike
- Requirements: BD-A-05 (gates BD-FR-87, BD-FR-109 to BD-FR-111, BD-AC-45, BD-AC-80 row 7)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `tests/spikes/A-05-firewall-podman.md`    Must not touch: all roles
- Context: Zone rich rules may not filter traffic that Podman DNATs to a published container port. Decision for T-14: keep `PublishPort=8000:8000` or run `restic-server` with host networking (`Network=host`, listener bound as configured), such that BD-FR-111 holds in both allowed cases (VM network, `ac45-allowed` Podman network) and fails closed for the default Podman network and any outside source. Needs real firewalld + nftables: VM only (firewalld's nft backend does not work in containers, per `CLAUDE.md`). Time box 2 h. Without a VM the spike is a documented desk analysis (firewalld/netavark behaviour for the installed Podman version) with the safe default recorded.
- Acceptance criteria (verifiable):
  - [ ] The note records, per `Network` mode tested, the HTTP code seen from (a) a client on the VM network, (b) a container on a Podman network inside an allowed CIDR, (c) a container on the default Podman network (`000` expected) with the exact commands.
  - [ ] It names the chosen mode with the Quadlet lines (`PublishPort=`/`Network=`/rest-server `--listen`) and states what the role must do so the choice is idempotent and `8000/tcp` appears in neither `firewall_zone` ports nor services (BD-FR-110).
  - [ ] If no VM was available it says so, marks evidence "unverified", and recommends host networking as the default; T-29 BD-AC-45 is named as the confirming test.
- Verification: reviewer reads the note; command outputs reproducible on the VM; `git status --short` shows only the note.
- Gate: simulator (VM) or host (desk analysis)    Risk/notes: host networking changes how `restic-server` interacts with `caddy.network`; rest-server needs none of it.

#### T-05 — firewall role: `firewall_rich_rules`          [ ] todo
- Type: slice
- Requirements: BD-FR-108, BD-FR-144, BD-CC-08 (firewall part), BD-D-06
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `roles/firewall/tasks/main.yml`, `roles/firewall/defaults/main.yml`, `roles/firewall/meta/argument_specs.yml`, `roles/firewall/README.md`    Must not touch: other roles, `vars.yml`
- Context: Adds a generic `firewall_rich_rules` list (default `[]`); the production values are set later by T-20 from `restic_server_allowed_sources` (BD-D-06). The rules apply to `firewall_zone`, permanent and immediate, via `ansible.posix.firewalld` `rich_rule`. The molecule test excludes the firewall role, so no container run.
- Acceptance criteria (verifiable):
  - [ ] Given default variables, when the role's tasks are listed, then the rich-rule loop exists and with `firewall_rich_rules: []` reports no item (skipped/empty loop).
  - [ ] Given `firewall_rich_rules` with two rules, when `tests/syntax-check-role.sh firewall` runs with that override and `--list-tasks`, then it succeeds and the task uses `rich_rule`, `zone: "{{ firewall_zone }}"`, `permanent: true`, `immediate: true`, `state: enabled` (BD-FR-108).
  - [ ] `meta/argument_specs.yml` declares `firewall_rich_rules` (type list, elements str, description) (BD-FR-144); `README.md` documents it and that ports stay out of `firewall_allowed_ports`.
  - [ ] The rich-rule task is placed after the allowed-services/ports tasks so SSH cannot be locked out by it.
- Verification: `cd nas-de-int-wahlberger-dev && tests/syntax-check-role.sh firewall && ansible-lint roles/firewall && yamllint roles/firewall`; `grep -n rich_rule roles/firewall/tasks/main.yml`.
- Gate: host    Risk/notes: runtime proof (rules present in runtime and permanent config) is BD-AC-45 in T-29.

#### T-06 — disk_space: do not report non-mount paths          [ ] todo
- Type: slice
- Requirements: BD-FR-46, BD-CC-08 (disk_space part), BD-FR-45 (value set in T-19)
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `roles/disk_space/templates/disk-space-check.sh.j2`, `roles/disk_space/README.md`, `roles/disk_space/defaults/main.yml`, `roles/disk_space/meta/argument_specs.yml`    Must not touch: `vars.yml`
- Context: When `/mnt/backup/btrbk` is not mounted (disk absent), the check must not report the root filesystem's usage under that path. It logs `<path>: not a mount point` and reports no usage figure and no threshold crossing for that entry.
- Acceptance criteria (verifiable):
  - [ ] Given a `disk_space_paths` entry that is a plain directory on the root filesystem, when the rendered check script runs against it, then the journal/stdout line is exactly `<path>: not a mount point`, no usage line is printed for it and it does not alter the stored crossing state.
  - [ ] Given a real mount point (the container's `/`) the existing behaviour (usage line, 85 % threshold, dedupe) is unchanged.
  - [ ] `molecule test` still exits 0 with no idempotence change and no deprecation warning (BD-NFR-04, covers the disk_space role).
- Verification: `cd nas-de-int-wahlberger-dev && molecule test` (docker) ; run the rendered script in a container with a temp directory path; `ansible-lint roles/disk_space`.
- Gate: host    Risk/notes: the check uses `mountpoint -q` or `findmnt`; avoid a Btrfs-specific test. The runtime check on a detached disk is BD-AC-28 (T-30).

#### T-07 — backup_disk role scaffold and the init playbook (the only code that formats the disk)          [ ] todo
- Type: slice
- Requirements: BD-FR-01, BD-FR-02, BD-FR-03, BD-FR-04, BD-FR-05, BD-FR-06, BD-FR-07, BD-FR-08, BD-FR-09, BD-FR-10, BD-FR-11, BD-FR-12, BD-FR-13, BD-FR-14, BD-FR-15, BD-FR-16, BD-FR-143, BD-FR-145 (backup_disk), BD-FR-148 (DOC-B1 to B4), BD-BR-02, BD-BR-03, BD-D-04
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `backup_disk_init.yml`, `roles/backup_disk/defaults/main.yml`, `roles/backup_disk/meta/main.yml`, `roles/backup_disk/meta/argument_specs.yml`, `roles/backup_disk/tasks/init.yml`, `roles/backup_disk/tasks/init_*.yml`, `roles/backup_disk/README.md`, `tests/render.d/10-backup-disk-init.yml` (if any template)    Must not touch: `site.yml`, `vars.yml`, other roles
- Context: Highest-risk, destructive part (the disk sits next to the household's only data), so it comes first in the role chain. Creates the whole `defaults/main.yml` and `argument_specs.yml` for **all** `backup_disk` variables from the spec's Inputs table (including those used by T-08 to T-10) with entry points `main` and `init`. `backup_disk_init.yml` has one play, `hosts: nas`, importing the role with `tasks_from: init` using static file names (no templated include names). `backup_disk_init_confirm` is never defined anywhere in the repository; it is read only (BD-FR-05). All ten refusal conditions R-01 to R-10 are evaluated before the first write, every holding ID is named in one failure message, R-09 lists signatures with type and offset from `wipefs --no-act`, `--check` evaluates everything and writes nothing, no `-f/--force` option appears (BD-FR-11), the table is GPT with one partition 1 MiB to within the last 1 MiB, `mkfs.btrfs -L backups`, single subvolume `@btrbk` below top level 5, prints the filesystem UUID, and a second run on the initialised unmounted disk reports `changed=0`.
- Acceptance criteria (verifiable):
  - [ ] Given the repository, when the four BD-AC-04 greps run over `R` (roles tasks/handlers/templates/files, inventories group_vars/host_vars, `site.yml`), then every (a) match is in `roles/backup_disk/tasks/init*.yml`; no (b) match uses `{{` or names an `init*` file outside `backup_disk_init.yml`; (c) matches only readers of `backup_disk_init_confirm`; (d) prints nothing; `backup_disk_init.yml` has one play with `hosts: nas` (BD-AC-04, BD-FR-01 to BD-FR-05, BD-FR-11).
  - [ ] Given `site.yml` as it is now, `grep -n 'backup_disk_init\|tasks/init' site.yml` prints nothing and stays that way after T-19 (BD-FR-02).
  - [ ] The refusal table R-01 to R-10 and the failure-message format (all holding IDs, R-09 signature list) are implemented as separate assert tasks that all run before any write task; the write tasks are guarded by `not ansible_check_mode` and by "not in initialised state".
  - [ ] `meta/argument_specs.yml` has entry points `main` and `init` and every default has `type` and `description` (BD-FR-143, BD-FR-142); `ansible-playbook backup_disk_init.yml --syntax-check` passes.
  - [ ] `README.md` has DOC-R1 to R3 and DOC-B1 (`--check` first, then without), DOC-B2 (R-01 to R-10 table and the `@btrbk`-only initialised-state definition), DOC-B3 (`lsblk -bdno SIZE` for `backup_disk_expected_size_bytes`), DOC-B4 (partial-init recovery with manual `wipefs -a <by-id path>`).
- Verification: `cd nas-de-int-wahlberger-dev && ansible-playbook backup_disk_init.yml --syntax-check && ansible-playbook -i inventories/vm backup_disk_init.yml --list-tasks && ansible-lint && yamllint .` plus the four BD-AC-04 commands (record exact output in the task log); `grep -rn 'backup_disk_init_confirm' inventories roles/*/defaults roles/*/vars *.yml`.
- Gate: host (the 17 BD-AC-20 rows, BD-AC-21 to BD-AC-23 are executed in T-27)    Risk/notes: never run the init playbook, even with `--check`, against anything but the VM; the sizes in `inventories/vm` differ from the production default. Do not use the Ansible parted/filesystem modules if their idempotence cannot refuse non-empty disks; shell tasks are allowed but only in `init*.yml`.

#### T-08 — backup_disk role: mount `@btrbk` (main entry point)          [ ] todo
- Type: slice
- Requirements: BD-FR-20, BD-FR-21, BD-FR-22, BD-FR-23, BD-FR-24, BD-FR-26, BD-FR-28 (role part), BD-FR-29, BD-FR-145, BD-FR-148 (DOC-B5), BD-BR-02, BD-BR-04 (backup_disk row), BD-BR-12, BD-D-05
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-07
- Files owned (may modify): `roles/backup_disk/tasks/main.yml`, `roles/backup_disk/tasks/mount.yml`, `roles/backup_disk/defaults/main.yml`, `roles/backup_disk/meta/argument_specs.yml`, `roles/backup_disk/README.md`    Must not touch: `site.yml`, `vars.yml`, `tasks/init*.yml`
- Context: Normal-run side. Preconditions fail before any change (empty `backup_disk_uuid` naming it and `roles/backup_disk/README.md`; UUID not present; not btrfs / wrong label / not on a partition of `backup_disk_device`, naming the mismatching property). Persists one fstab line per `backup_disk_mounts` entry with exactly `subvol=<subvol>,compress=zstd:1,noatime,nofail,x-systemd.device-timeout=<backup_disk_device_timeout>`, source `UUID=<uuid>`, type `btrfs`, then mounts, then asserts against the **live** mount table that the path is mounted with that UUID and subvol (else fail naming path and subvolume). Sets root dir of the mounted subvolume to `0700 root:root`. Never sets the `C` attribute; never creates or deletes subvolumes (the `@btrbk` subvolume must already exist; a filesystem without it fails the mount assertion).
- Acceptance criteria (verifiable):
  - [ ] Given `backup_disk_uuid: ""`, when the role's first task block is evaluated (or rendered via `tests/syntax-check-role.sh` with a stub), then the fail message names `backup_disk_uuid` and `roles/backup_disk/README.md` (BD-FR-20); for the other precondition failures the message names the UUID (BD-FR-21), `label`/`device` property (BD-FR-22), or `@btrbk` (BD-FR-26).
  - [ ] The fstab option string passed to the mount task equals BD-FR-23's string for the default and for an overridden `backup_disk_device_timeout` (verified via `tests/render.d/11-backup-disk-mount.yml` which renders the option string).
  - [ ] No task sets `+C` or calls chattr (BD-FR-24); no task in `tasks/main.yml` or `tasks/mount.yml` matches the BD-AC-04 (a) pattern.
  - [ ] `README.md` has DOC-B5 (`ansible-playbook site.yml --skip-tags backup_disk,btrbk` while the disk is dead) and the BD-BR-12 behaviour statement.
- Verification: `cd nas-de-int-wahlberger-dev && tests/syntax-check-role.sh backup_disk && tests/render-check.sh && ansible-lint roles/backup_disk && yamllint roles/backup_disk` and BD-AC-04 (a) grep over `roles/backup_disk/tasks/main.yml tasks/mount.yml`.
- Gate: host    Risk/notes: BD-AC-24 rows 1 to 5, BD-AC-26 and BD-AC-27 row 6 run in T-27/T-30. The real-world proof that the fstab line mounts at boot is BD-AC-80 row 1.

#### T-09 — backup_disk role: scrub, smartd, optional spindown          [ ] todo
- Type: slice
- Requirements: BD-FR-30, BD-FR-31, BD-FR-32, BD-FR-37, BD-FR-38, BD-FR-39, BD-FR-40, BD-FR-41, BD-FR-42, BD-FR-43, BD-FR-44, BD-D-04 (n/a), BD-A-12, BD-A-02
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G3
- Depends on: T-08
- Files owned (may modify): `roles/backup_disk/tasks/main.yml`, `roles/backup_disk/tasks/scrub.yml`, `roles/backup_disk/tasks/smartd.yml`, `roles/backup_disk/tasks/spindown.yml`, `roles/backup_disk/templates/**` (smartd hook, hdparm unit), `roles/backup_disk/README.md`, `roles/backup_disk/defaults/main.yml`, `roles/backup_disk/meta/argument_specs.yml`, `tests/render.d/12-backup-disk-smartd.yml`    Must not touch: `tasks/init*.yml`, `tasks/mount.yml`, other roles
- Context: Installs `btrfsmaintenance`, `smartmontools`, `hdparm`; extends `BTRFS_SCRUB_MOUNTPOINTS` with the backup mount while keeping every existing value; enables `btrfs-scrub.timer` with period at most monthly. smartd monitors the backup disk by by-id path with `-a`, `-s <backup_disk_smartd_schedule>`, and a mail hook that sends through the `notify_failure` Resend credentials (`/etc/notify-failure/notify-failure.env`) containing the device path and smartd's message within 5 min; all pre-existing device and `DEVICESCAN` lines are kept; `smartd.service` enabled and active. With `backup_disk_hdparm_spindown > 0`: a boot-time oneshot unit runs `hdparm -S <n> <device>` and the smartd line gains `-n standby`; with 0 neither exists.
- Acceptance criteria (verifiable):
  - [ ] Given a `BTRFS_SCRUB_MOUNTPOINTS` value with existing entries (fixture file in a container), when the task logic runs twice, then the line contains the backup mount plus every old value, and the second run reports no change (BD-FR-30, BD-FR-31, BD-NFR-01).
  - [ ] Rendered smartd line contains the by-id path, `-a`, and `-s (S/../../7/01|L/../01/./10)` by default; pre-existing smartd.conf lines (DEVICESCAN and device lines) survive in a fixture-file test (BD-FR-37, BD-FR-38, BD-FR-42).
  - [ ] With `-e backup_disk_hdparm_spindown=120` the render check shows a unit running `hdparm -S 120 <device>` and `-n standby` in the smartd line; with the default neither is rendered (BD-AC-07 spindown clause, BD-FR-43, BD-FR-44).
  - [ ] The smartd hook script (rendered) contains the device path and message text in the email body and uses the Resend credentials file; `shellcheck`-clean if shellcheck is available in the render container.
  - [ ] `systemctl` enablement tasks for `smartd.service` and `btrfs-scrub.timer` exist (BD-FR-32, BD-FR-41); `README.md` documents scrub period and smartd behaviour.
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/render-check.sh -e backup_disk_hdparm_spindown=120 && tests/syntax-check-role.sh backup_disk && ansible-lint roles/backup_disk`; BD-AC-04 greps (no `chattr`/`dd`/`wipefs` text).
- Gate: host    Risk/notes: a VM's virtual disks lack SMART, so BD-FR-37/38/41/42 are smoke-checked only in production (BD-AC-80 row 11, T-31) and BD-FR-39/40 by BD-AC-82. `hdparm -S` is a drive setting, not a data write (BD-FR-03); documented in the README. The `btrfsmaintenance` sysconfig line editing must preserve unknown formatting (`lineinfile`/`replace` with a regex, not a rewrite).

#### T-10 — backup_disk role: daily health check          [ ] todo
- Type: slice
- Requirements: BD-FR-34, BD-FR-35, BD-FR-36, BD-FR-159, BD-FR-33 (backup-disk-health rows), BD-FR-28 (health never writes below backup mount), BD-NFR-05 (alert), BD-NFR-06 (cloud repo freshness), BD-D-09, BD-A-20
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G4
- Depends on: T-09
- Files owned (may modify): `roles/backup_disk/tasks/main.yml`, `roles/backup_disk/tasks/health.yml`, `roles/backup_disk/templates/backup-disk-health.*.j2`, `roles/backup_disk/README.md`, `roles/backup_disk/defaults/main.yml`, `roles/backup_disk/meta/argument_specs.yml`, `tests/render.d/13-backup-disk-health.yml`, `tests/unit/test_backup_disk_health.py` (only if the script is Python)    Must not touch: other roles
- Context: `backup-disk-health.service` (oneshot, `OnFailure=notify-failure-immediate@%n.service`) and `.timer` (`OnCalendar=backup_disk_health_on_calendar`, default 09:00, `Persistent=true`). The script fails when a `backup_disk_mounts` path is not mounted, when `btrfs device stats --check` exits non-zero for the backup filesystem, or when no direct child of a `backup_disk_freshness_checks` path has `stat -c %W` birth time within that entry's `max_age_hours` (journal names the path); a freshness path that does not exist logs `<path>: absent, skipped` and does not fail. No file is written below the backup mount. The unit does **not** use `RequiresMountsFor` for the backup mount (it must run and fail when the disk is gone; BD-BR-04 table lists none for this role).
- Acceptance criteria (verifiable):
  - [ ] Given a fake mount table, fake `btrfs device stats` output and a temp directory tree with controlled birth times (container test or script test harness), when the check runs, then it exits 0 for fresh entries, non-zero naming the path for a stale entry, `max_age_hours: 0` fails, a missing path logs `<path>: absent, skipped` and exits 0, a non-zero counter fails, an unmounted path fails (BD-FR-34, BD-FR-35, BD-FR-36, BD-FR-159).
  - [ ] Rendered `backup-disk-health.timer` has `OnCalendar=*-*-* 09:00:00` and `Persistent=true`; the service has `OnFailure=notify-failure-immediate@%n.service`; `systemd-analyze verify` passes (BD-BR-05 rows).
  - [ ] The health script contains no write below `backup_disk_mounts` paths and no match for the BD-AC-04 (a) pattern.
  - [ ] `README.md` documents the health check, the 26 h freshness model and the Defaults for `backup_disk_freshness_checks` (production list is set in T-20).
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/syntax-check-role.sh backup_disk && ansible-lint roles/backup_disk && yamllint .`; run the rendered health script in the render container against the fake fixtures.
- Gate: host    Risk/notes: birth time on btrfs depends on the kernel/coreutils (BD-A-20) and is proven in BD-AC-55 (T-30). The non-zero device-counter path is verified by analysis (BD-FR-35 verification note): the unit fails exactly when `btrfs device stats --check` exits non-zero.

#### T-11 — btrbk role: pinned OBS repository and package          [ ] todo
- Type: slice
- Requirements: BD-FR-47, BD-FR-48, BD-FR-49, BD-FR-50, BD-D-03, BD-A-01, BD-A-17, BD-FR-145 (btrbk)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `roles/btrbk/defaults/main.yml`, `roles/btrbk/meta/**`, `roles/btrbk/tasks/main.yml`, `roles/btrbk/tasks/install.yml`, `roles/btrbk/README.md`    Must not touch: `site.yml`, `vars.yml`
- Context: First slice of the btrbk role and defines all btrbk defaults/argument_specs from the spec's Inputs table. Adds the zypper repository `btrbk_zypper_repo_url` with GPG check on and priority `btrbk_zypper_repo_priority` (150), imports the signing key only after checking that the key's fingerprint equals `btrbk_zypper_repo_gpg_fingerprint` (fails before adding the repository or key otherwise, BD-FR-49), installs `btrbk`. After the run, `btrbk` must be the only installed package from this repository (BD-FR-50): never `zypper dup`/`--allow-vendor-change` for the repo; priority 150 keeps OSS packages on OSS.
- Acceptance criteria (verifiable):
  - [ ] Given default variables and a stub key file with a different fingerprint, when the fingerprint-check task runs, then it fails with a message naming `btrbk_zypper_repo_gpg_fingerprint` and no repository or key task runs after it (BD-FR-49, BD-AC-29 row 2).
  - [ ] The repo task sets `gpgcheck`/`repo_gpgcheck` on and `priority: 150`; no task disables GPG checking (BD-FR-48).
  - [ ] In a Tumbleweed container, adding the repo with the production URL and fingerprint and installing `btrbk` succeeds; `zypper se -s -i btrbk` shows the `filesystems` repository; `zypper se btrbk` with only OSS enabled finds nothing (BD-A-01, BD-AC-29 row 1 as a container test).
  - [ ] `meta/argument_specs.yml` declares every default; README has DOC-R1 to R3 plus the fallback (pinned upstream script) note of BD-D-03 and the key-renewal pointer for DOC-O11.
- Verification: `cd nas-de-int-wahlberger-dev && tests/syntax-check-role.sh btrbk && ansible-lint roles/btrbk && yamllint roles/btrbk`; container check recorded in the task log: `podman run --rm opensuse/tumbleweed sh -c '<zypper commands>'`.
- Gate: host (container); BD-AC-29 itself runs in T-28    Risk/notes: the key expires 2027-05-07 (BD-A-17); there is no alert, only DOC-O11. OBS reachability is a runtime risk (error case in the spec).

#### T-12 — btrbk role: configuration, units, retention, locking          [ ] todo
- Type: slice
- Requirements: BD-FR-51, BD-FR-52, BD-FR-53, BD-FR-54, BD-FR-55, BD-FR-56, BD-FR-57, BD-FR-58, BD-FR-59, BD-FR-60, BD-FR-61, BD-FR-62, BD-FR-63, BD-FR-64, BD-FR-161, BD-FR-25 (btrbk), BD-FR-27 (btrbk.service), BD-FR-28, BD-FR-33 (btrbk rows), BD-FR-65/66 (ordering part: pulls in `db-dump.service` before btrbk), BD-FR-75, BD-BR-04, BD-BR-05, BD-BR-15, BD-D-10, BD-NFR-05, BD-NFR-10
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-11, T-03
- Files owned (may modify): `roles/btrbk/tasks/main.yml`, `roles/btrbk/tasks/config.yml`, `roles/btrbk/templates/**`, `roles/btrbk/defaults/main.yml`, `roles/btrbk/meta/argument_specs.yml`, `roles/btrbk/handlers/main.yml`, `roles/btrbk/README.md`, `tests/render.d/20-btrbk.yml`    Must not touch: `tasks/install.yml` logic, `roles/snapper/**`, other roles
- Context: Implements the T-03 decision. Renders `/etc/btrbk/btrbk.conf` with a `lockfile`, `snapshot_dir .btrbk` (never `.snapshots`, never below `samba_data_dir`), `snapshot_preserve_min 2d`, `snapshot_preserve no`, `target_preserve 14d 8w 12m 3y`, `target_preserve_min no`, one section per `btrbk_sources` entry sending into `<btrbk_target_dir>/<name>/`, and no exclusion of `restic_server_data_dir` (BD-FR-161). Retention keys come from the role variables independently of snapper (BD-BR-15). Units: `btrbk.service` (oneshot, `ExecStart=/usr/bin/btrbk run`, non-zero exit including 10 fails the unit, `OnFailure=notify-failure-immediate@%n.service`, `RequiresMountsFor=` the target and every source path, `Wants=db-dump.service` and `After=db-dump.service` so a failed dump does not stop btrbk), `btrbk.timer` (`OnCalendar=*-*-* 01:30:00`, `Persistent=true`). Before any change the role asserts, from the live mount table, that `btrbk_target_dir` and every source path are mounted with the right UUID/subvol (BD-FR-25), and it creates the `.btrbk` snapshot directories inside mounted sources only, never below an unmounted backup path (BD-FR-28). `snapper` role and its configs unchanged (BD-FR-64).
- Acceptance criteria (verifiable):
  - [ ] Given the fixture overrides, when `tests/render-check.sh` runs, then `btrbk -c <rendered> config print` shows for both sources `snapshot_dir .btrbk`, `snapshot_preserve_min 2d`, `snapshot_preserve no`, `target_preserve 14d 8w 12m 3y`, `target_preserve_min no` (BD-AC-07, BD-FR-57, BD-FR-58); and changing only `btrbk_target_preserve` changes only the target lines (BD-BR-15).
  - [ ] Rendered `btrbk.service` carries `OnFailure=notify-failure-immediate@%n.service` and `RequiresMountsFor=` including `/mnt/backup/btrbk`, `/mnt/data`, `/mnt/containers`, and `Wants=`/`After=db-dump.service`; `btrbk.timer` carries `OnCalendar=*-*-* 01:30:00` and `Persistent=true`; `systemd-analyze verify` passes (BD-BR-04, BD-BR-05, BD-FR-27, BD-FR-33).
  - [ ] The config has no `snapshot_dir` equal to or below `.snapshots` or `/mnt/data/samba`, and no exclude of `restic-repos` (BD-FR-52, BD-FR-53, BD-FR-161) - checked by grep in the render assertion file.
  - [ ] The mount-guard task fails before any change naming the missing path when the live mount table lacks it (tested by a stubbed `findmnt` fixture or deferred to BD-AC-27 rows 1 to 2; the task text must name the path via `fail_msg`) (BD-FR-25).
  - [ ] `git diff master -- roles/snapper/` prints nothing (BD-AC-15).
  - [ ] README has DOC-R1 to R3, the retention table (btrbk target vs source vs snapper independence) and the restore-pointer for DOC-O1/O2.
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/render-check.sh -e btrbk_target_preserve='7d' && tests/syntax-check-role.sh btrbk && ansible-lint roles/btrbk && git diff master -- roles/snapper/ | wc -l`.
- Gate: host; BD-AC-29 to BD-AC-34 run in T-28    Risk/notes: if T-03 chose the fallback (extra top-level mount), this task adds that mount without touching `storage_mounts`. BD-FR-62/63 (interrupted transfer) rely on btrbk's own behaviour and are proven in BD-AC-34. The Samba share lives under `/mnt/data/samba`, so `.btrbk` at `/mnt/data/.btrbk` stays outside it.

#### T-13 — db_dump role: dumps before every btrbk run          [ ] todo
- Type: slice
- Requirements: BD-FR-65, BD-FR-66, BD-FR-67, BD-FR-68, BD-FR-69, BD-FR-70, BD-FR-71, BD-FR-72, BD-FR-73, BD-FR-74, BD-FR-76, BD-FR-25 (db_dump), BD-FR-27 (db-dump.service), BD-FR-33 (db-dump row), BD-BR-11, BD-D-02, BD-CC-03, BD-CC-04, BD-A-08, BD-NFR-11, BD-FR-145 (db_dump)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `roles/db_dump/**`, `tests/render.d/21-db-dump.yml`    Must not touch: `roles/restic_backup/**` (read it for the existing `pg_dump` command lines, credentials templates and the sqlite step; it is deleted by T-19), `roles/paperless_ngx`, `roles/immich`, `roles/tandoor`, `roles/forgejo`
- Context: Moves the dumps out of the old `restic_backup` role. Writes `paperless.sql`, `immich.sql`, `tandoor.sql` (one `pg_dump` per `db_dump_postgres` entry, same container/database/user names as today) and an `sqlite3 .backup` copy `forgejo.db` of `db_dump_forgejo_db_path` into `db_dump_dir` (`/mnt/containers/db-dumps`, `0700 root:root`). Each dump goes to a temp name and is renamed only when its command exited 0 (the previous file stays on failure); files `0600 root:root`; credentials files in `db_dump_credentials_dir` (`/var/lib/db-dump`, mode `0600 root:root`, not on a `btrbk_sources` filesystem). Each dump is limited by `db_dump_timeout` (30 min); a stopped dump counts as failed; all remaining dumps still run; the service ends `failed` if any failed (so `OnFailure=` fires). `db-dump.service` has `RequiresMountsFor=` the `/mnt/data`-style `storage_mounts` path containing `db_dump_dir` (`/mnt/containers`). The role fails before any change if `db_dump_dir` is not below a `btrbk_sources` path, naming `db_dump_dir`, and if the `/mnt/containers` mount is not live-mounted (BD-FR-25). Installs `sqlite3` (and the Postgres client tooling the old role used inside containers if any). Role is not triggered by the timer itself: only `btrbk.service` pulls it in.
- Acceptance criteria (verifiable):
  - [ ] Given the fixture overrides, when the dump script is rendered and run in the render container against a fake `podman exec` shim, then success writes `<name>.sql` via temp-and-rename; a failing shim leaves the previous file byte-identical and the script continues with the remaining dumps and finally exits non-zero (BD-FR-69, BD-FR-74, BD-FR-76).
  - [ ] A dump command that sleeps beyond `db_dump_timeout=2s` is terminated and counts as failed (BD-FR-73).
  - [ ] Rendered unit has `OnFailure=notify-failure-immediate@%n.service` and `RequiresMountsFor=/mnt/containers`; no timer is installed; `systemd-analyze verify` passes (BD-BR-05 db-dump row).
  - [ ] The role asserts `db_dump_dir` below a `btrbk_sources` path and fails otherwise (override `db_dump_dir=/var/tmp/db-dumps`) naming `db_dump_dir` (BD-FR-67, BD-AC-35 row 4), and its mode/owner tasks produce `0700 root:root`, dump files `0600 root:root`, credentials `0600 root:root` under `/var/lib/db-dump` (BD-FR-68, BD-FR-70 to BD-FR-72).
  - [ ] No credential value appears in any rendered unit or the Quadlet; the Tandoor rotation text in README names `--tags tandoor,db_dump` (BD-CC-03).
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/syntax-check-role.sh db_dump && ansible-lint roles/db_dump && yamllint roles/db_dump`; shim-based run recorded in the task log.
- Gate: host; BD-AC-30, BD-AC-35 to BD-AC-37 run in T-28    Risk/notes: the real Postgres containers cannot be exercised until the VM exists; the dump command lines must be copied exactly from the old role so behaviour is unchanged. Per-dump `timeout` must not match the BD-AC-04 pattern.

#### T-14 — restic_server role: rest-server container, account, htpasswd, secrets hygiene          [ ] todo
- Type: slice
- Requirements: BD-FR-87, BD-FR-88, BD-FR-89, BD-FR-90, BD-FR-91, BD-FR-92, BD-FR-93, BD-FR-94, BD-FR-95, BD-FR-96, BD-FR-97, BD-FR-98, BD-FR-99, BD-FR-100, BD-FR-101, BD-FR-102, BD-FR-103, BD-FR-104, BD-FR-105, BD-FR-107, BD-FR-110, BD-FR-111, BD-FR-160, BD-FR-25 (restic_server), BD-FR-27 (restic-server.service), BD-FR-33 (restic-server row), BD-BR-04, BD-BR-05, BD-BR-06, BD-BR-10 (DOC-O9), BD-D-06 (port not in firewall ports), BD-D-08 (DOC-O12), BD-FR-145 (restic_server)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-01, T-04    (same-role chain: T-14 -> T-16)
- Files owned (may modify): `roles/restic_server/defaults/main.yml`, `roles/restic_server/meta/**`, `roles/restic_server/tasks/main.yml`, `roles/restic_server/tasks/server.yml`, `roles/restic_server/templates/restic-server.container.j2`, `roles/restic_server/handlers/main.yml`, `roles/restic_server/README.md`, `tests/render.d/30-restic-server.yml`    Must not touch: `roles/restic_server/files/**` (T-15), `tasks/maintenance.yml` and maintenance templates (T-16), `firewall` role
- Context: Creates `restic_server` with all defaults/argument_specs from the Inputs table (including the maintenance ones used by T-15/T-16). Deploys Quadlet `restic-server` via the `container` role with `docker.io/restic/rest-server:0.14.0` on a single `restic_server_image:` line (Renovate-matchable), `--private-repos` and `--append-only` while their booleans are true, `--max-size 107374182400`, run as the UID/GID of `restic_server_user` (system account, UID < 1000, `/usr/sbin/nologin`), data dir `restic_server_data_dir` (`/mnt/data/restic-repos`) bind-mounted with `:Z`, owner that account, mode `0700`, on the `/mnt/data` mount and not at or below `samba_data_dir`, `.snapshots` or the btrbk snapshot dir (checked by assert, BD-FR-97). The htpasswd file (bcrypt, one entry per `restic_server_clients` entry, `0600`, owner the service account) is built with `community.general.htpasswd` after installing the passlib package matching Ansible's interpreter via `community.general.zypper` (name derived from the discovered Python minor version). Empty `restic_server_clients`, an empty client password and an empty maintenance repo password each fail before any change with the named message. A password change restarts the container so the new password works and the old gets 401 within 60 s. No client or maintenance password is in the Quadlet or in `/etc/systemd/system/`. Unit: `restic-server.service` has `Restart=always`, `WantedBy=default.target`, `OnFailure=notify-failure@%n.service`, `RequiresMountsFor=` the `/mnt/data` mount. Network mode per T-04 (published port or host networking). The SELinux relabel by `:Z` must not alter `samba_data_dir`'s context (BD-FR-160), which is why the data directory is a dedicated subdirectory.
- Acceptance criteria (verifiable):
  - [ ] Given the Renovate custom-manager regex from `renovate.json`, when run against the `restic_server_image` line, then it yields depName `docker.io/restic/rest-server` and currentValue `0.14.0` (BD-AC-08, BD-FR-88).
  - [ ] Rendered Quadlet contains `--private-repos`, `--append-only`, `--max-size 107374182400`, a `Volume=` line for the data dir ending `:Z`, `User=`/`Group=` of the service account (numeric), the T-04 network lines, and `Restart=always`, `WantedBy=default.target`, `OnFailure=notify-failure@%n.service`, `RequiresMountsFor=/mnt/data`; `8000/tcp` is nowhere in role tasks touching firewalld (BD-AC-39 static part, BD-FR-110, BD-FR-87 to BD-FR-93, BD-FR-96).
  - [ ] Overrides `restic_server_clients=[]`, an empty `cloud` password, and `restic_server_maintenance_repo_password=""` each make the role's validation tasks fail with messages naming `restic_server_clients` + `roles/restic_server/README.md`, `cloud`, and that variable respectively, before any task would report changed (BD-AC-41, evidenced statically by assert task order and messages).
  - [ ] htpasswd task: `no_log: true`, mode `0600`, owner `restic_server_user`, bcrypt, one entry per client; the passlib package name is computed from `ansible_python.version`, and `rpm -q` assertion exists (BD-FR-98, BD-FR-99, BD-FR-100).
  - [ ] `grep -rF` of a test password over rendered Quadlet shows no hit (BD-FR-107, rendered via `tests/render.d/30-restic-server.yml`).
  - [ ] `README.md` contains DOC-R1 to R3, DOC-O9 (the BD-BR-10 risk statement: root on the NAS reads cloud backup contents) and DOC-O12 (location decision, effect on snapper `data` and btrbk, how to override `restic_server_data_dir` within BD-FR-97).
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/syntax-check-role.sh restic_server && ansible-lint roles/restic_server && yamllint roles/restic_server`; Renovate check: `python3 -c` using the first custom-manager regex on the `restic_server_image` line (record output).
- Gate: host; BD-AC-39 to BD-AC-46 run in T-29    Risk/notes: A-06 (entrypoint under non-root `User=`), A-11 (SELinux labels) and A-05 (T-04) are unverified until the VM run; BD-FR-111 is not claimed met until BD-AC-45 passes.

#### T-15 — Maintenance runner: prune guard, forget/prune, check (Python with pytest)          [ ] todo
- Type: slice
- Requirements: BD-FR-112 (logic: no root-owned files created), BD-FR-114, BD-FR-115, BD-FR-116, BD-FR-117, BD-FR-118, BD-FR-119, BD-FR-120, BD-FR-121, BD-BR-07, BD-BR-08, BD-D-15
- Agent: python-engineer    Priority: P0    Size: M    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `roles/restic_server/files/restic-maintenance.py`, `tests/unit/test_restic_maintenance.py`, `tests/unit/conftest.py`, `tests/unit/requirements.txt`    Must not touch: other `roles/restic_server/**` files, `site.yml`
- Context: Pure logic with a closed host-side verification loop. CLI: `restic-maintenance.py --repo-root <restic_server_data_dir> --repo <name> --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --check-subset 10% --retry-lock 30m --max-skew-hours 6 [--restic <path>]`; the repository password comes from the environment (`RESTIC_PASSWORD` provided by systemd `EnvironmentFile=`), never from argv. Order: refuse if the repository directory (`<root>/<name>/config`) is missing and never run `restic init` (BD-FR-121); read `restic snapshots --json`; for every snapshot compare its recorded `time` with the modification time of `<repo>/snapshots/<id>`; if any differs by more than `--max-skew-hours`, print every offending ID, run neither forget nor prune, exit non-zero (BD-FR-114 to BD-FR-116); else run `restic forget --prune --keep-daily N --keep-weekly N --keep-monthly N --retry-lock <t>`, then `restic check --read-data-subset=<subset> --retry-lock <t>`; any non-zero restic exit makes the script exit non-zero. Output goes to stdout/stderr for the journal. No file content with the maintenance password is written.
- Acceptance criteria (verifiable):
  - [ ] Given a fake `restic` executable (records argv and environment, returns canned `snapshots --json`) and a temp repo directory whose snapshot files have controlled mtimes, when snapshots are within the skew limit, then the recorded call sequence is exactly `snapshots --json`, `forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --retry-lock 30m`, `check --read-data-subset=10% --retry-lock 30m` and exit 0 (BD-FR-117, BD-FR-118, BD-FR-120).
  - [ ] Given a snapshot with recorded time = now + 2 days (or now - 3 days) relative to its file mtime, then no `forget`/`prune` call occurs, the exit code is non-zero, and the output lists that snapshot's full ID and no genuine snapshot IDs (BD-FR-114, BD-FR-116, BD-AC-47 both rows' logic); a boundary case exactly at the limit passes and one second above fails.
  - [ ] Given a missing repository directory, then the exit code is non-zero, the fake restic recorded no `init`, and no directory was created (BD-FR-121).
  - [ ] Given forget failing, prune failing or check failing (each simulated), the script exits non-zero and later steps are skipped appropriately (BD-FR-119).
  - [ ] The password never appears in the recorded argv; `restic init` string does not appear in the script source; the script source has no match for the BD-AC-04 (a) pattern.
  - [ ] `python3 -m pytest tests/unit -q` passes in a clean venv with only `pytest` installed; tests cover every branch above (test-quality tier: assertions on call sequences, not only exit codes).
- Verification: in the scratchpad: `python3 -m venv .v && .v/bin/pip install pytest && cd nas-de-int-wahlberger-dev && ../.v/bin/pytest tests/unit -q`; `grep -nE 'init' roles/restic_server/files/restic-maintenance.py`; the BD-AC-04 (a) grep over the file.
- Gate: host    Risk/notes: `restic forget --retry-lock` needs restic >= 0.16 (NAS has 0.19.1, BD-A-02). Snapshot IDs in `snapshots --json` are full 64-hex IDs, equal to the file names in `snapshots/`. BD-A-21 (clients can set any snapshot time) is the threat model; document it in the script header.

#### T-16 — restic_server role: maintenance service, timer, password file          [ ] todo
- Type: slice
- Requirements: BD-FR-106, BD-FR-107 (maintenance part), BD-FR-112, BD-FR-113, BD-FR-27 (maintenance unit), BD-FR-33 (maintenance rows), BD-FR-25 (restic_server), BD-D-11, BD-D-14, BD-BR-05, BD-A-11 (host-side access), BD-NFR-10
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G3
- Depends on: T-14, T-15
- Files owned (may modify): `roles/restic_server/tasks/main.yml`, `roles/restic_server/tasks/maintenance.yml`, `roles/restic_server/templates/restic-server-maintenance.*.j2`, `roles/restic_server/templates/restic-maintenance.env.j2`, `roles/restic_server/defaults/main.yml`, `roles/restic_server/meta/argument_specs.yml`, `roles/restic_server/README.md`, `tests/render.d/31-restic-server-maintenance.yml`    Must not touch: `roles/restic_server/files/**` (T-15), `templates/restic-server.container.j2` (T-14)
- Context: Installs `restic`, deploys the script from T-15 (`copy` from `files/`), writes the password file via `template` with mode `0600 root:root` and `no_log`, and defines `restic-server-maintenance.service` (oneshot, `User=`/`Group=` = `restic_server_user` and its primary group, `EnvironmentFile=<password file>` read by systemd as root, `Environment=HOME=...`/cache dir for the nologin account, `RequiresMountsFor=` the `/mnt/data` mount, `TimeoutStartSec` larger than the 30 min lock wait plus prune time, `OnFailure=notify-failure-immediate@%n.service`) and `.timer` (`OnCalendar=*-*-* 06:00:00`, `Persistent=true`). Every file the run creates is owned by `restic_server_user`.
- Acceptance criteria (verifiable):
  - [ ] Rendered service has `User=` and `Group=` equal to `restic_server_user` and its group, `EnvironmentFile=` pointing at the password file, `RequiresMountsFor=/mnt/data`, `OnFailure=notify-failure-immediate@%n.service`; rendered timer has `OnCalendar=*-*-* 06:00:00` and `Persistent=true`; `systemd-analyze verify` passes (BD-BR-05 rows, BD-FR-27, BD-FR-33).
  - [ ] The password file task has `mode: "0600"`, `owner: root`, `group: root`, `no_log: true`; `grep -rF` of a test maintenance password over all rendered units and the Quadlet finds nothing (BD-FR-113, BD-AC-52 static part).
  - [ ] A `zypper` task installs `restic` (BD-FR-106); the unit's `ExecStart` calls the T-15 script with `--repo cloud`, keeps and subset from the role variables (BD-FR-117, BD-FR-118).
  - [ ] README documents the maintenance run, the prune guard, DOC-O6 (`restic unlock` as the service account), DOC-O8 (guard tripped: inspect IDs, remove forged snapshots by hand) and DOC-O10 (re-baselining with `touch -d`).
- Verification: `cd nas-de-int-wahlberger-dev && tests/render-check.sh && tests/syntax-check-role.sh restic_server && ansible-lint roles/restic_server && yamllint roles/restic_server`.
- Gate: host; BD-AC-47 to BD-AC-52, BD-AC-54 run in T-29    Risk/notes: BD-A-11 (the host-side run reading the `:Z`-labelled tree) is only provable under SELinux on the VM (BD-AC-40, BD-AC-48).

#### T-17 — restic_backup_decommission role (NAS to Pi job retirement)          [ ] todo
- Type: slice
- Requirements: BD-FR-79, BD-FR-80, BD-FR-81, BD-FR-82, BD-FR-158, BD-FR-83, BD-FR-142, BD-FR-145 (restic_backup_decommission), BD-D-01, BD-BR-14 (step order is enforced by the flag, documented here), BD-CC-01
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `roles/restic_backup_decommission/**`    Must not touch: `roles/restic_backup/**` (deleted in T-19), `site.yml`, `vars.yml`
- Context: Idempotent teardown of the old NAS to Pi restic job once `restic_backup_decommission_enabled` is true at step 5: stop and disable `restic-backup.timer` and `restic-backup.service`, remove their unit files, `/usr/local/bin/restic-backup.sh`, `/etc/restic-backup` and `/var/lib/restic-backup`, then daemon-reload. The role is written so that when none of those exist, every task reports ok (no change). The role performs no network operation and never contacts the Pi (BD-FR-83). The flag itself is applied by `when:` in `site.yml` (T-19); the role has no flag variable in its defaults, only the paths/unit names (declared in argument_specs).
- Acceptance criteria (verifiable):
  - [ ] Given a Tumbleweed systemd container with dummy `restic-backup.timer`/`.service` units and the three paths (as in BD-AC-25's setup), when the role runs, then afterwards `systemctl cat restic-backup.timer` and `systemctl cat restic-backup.service` report no such unit and none of the three paths exist (BD-FR-79 to BD-FR-81).
  - [ ] When the role runs again, every task reports `ok` or `skipped` (BD-FR-82); `molecule`-style two-pass check shows `changed=0` on the second pass.
  - [ ] `grep -rn 'pi.de.int.wahlberger.dev' roles/restic_backup_decommission` prints nothing (BD-FR-83); the role has `README.md` (DOC-R1 to R3) and argument_specs.
- Verification: `cd nas-de-int-wahlberger-dev && tests/syntax-check-role.sh restic_backup_decommission && ansible-lint roles/restic_backup_decommission` and a two-pass run via a temporary scratchpad molecule scenario or `podman`/`docker` systemd container (reuse `molecule/default/Dockerfile.j2`): first pass changed, second pass changed=0.
- Gate: host (container)    Risk/notes: converging this role in the shipped molecule scenario is T-21 (BD-FR-151, Could). The VM proof is BD-AC-38 (T-30).

#### T-18 — cloud-wahlberger-dev restic_backup: forget switch, 04:30, docs          [ ] todo
- Type: slice
- Requirements: BD-FR-124, BD-FR-125, BD-FR-126, BD-FR-127, BD-FR-128, BD-FR-129, BD-FR-130, BD-FR-131, BD-D-07, BD-D-12, BD-CC-07, BD-NFR-06, BD-NFR-12
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-01
- Files owned (may modify): `cloud-wahlberger-dev/roles/restic_backup/defaults/main.yml`, `cloud-wahlberger-dev/roles/restic_backup/templates/restic-backup.sh.j2`, `cloud-wahlberger-dev/roles/restic_backup/meta/argument_specs.yml`, `cloud-wahlberger-dev/roles/restic_backup/README.md`    Must not touch: `cloud-wahlberger-dev/inventories/**` (step-7 variables are added at runbook step 7, not at the feature commit), `pi-de-int-wahlberger-dev/**`, `restic-backup.env.j2`, `restic-backup.timer.j2` unless the schedule is read from a variable there (it is)
- Context: Adds `restic_backup_forget_enabled` (role default `true`, declared in argument_specs). While false the rendered script contains no `restic forget` and no `restic prune` but keeps the nightly `restic check --read-data-subset=<…>`. The effective `restic_backup_on_calendar` default becomes `*-*-* 04:30:00` (comment updated: avoids the NAS rebootmgr window 03:00-04:00; a run of at most 60 min (BD-NFR-12) ends before the NAS maintenance run at 06:00); `restic_backup_paths` (`/opt/podman`) and `restic_backup_exclude` (`[]`) unchanged. With the step-7 values the rendered `RESTIC_REPOSITORY` is `rest:http://cloud:<password>@nas.de.int.wahlberger.dev:8000/cloud/`. The pre-cut-over default host stays `pi.de.int.wahlberger.dev`. README gets DOC-K1 (append-only, NAS applies retention when forget is off) and DOC-K2 (04:30 avoids 03:00-04:00).
- Acceptance criteria (verifiable):
  - [ ] Row 1 (feature commit, no overrides): rendering the three templates per BD-AC-12 gives `RESTIC_REPOSITORY` host `pi.de.int.wahlberger.dev`, a script containing `restic forget`, `restic check --read-data-subset=10%`, `OnCalendar=*-*-* 04:30:00`, backup path `/opt/podman` and no excludes (BD-FR-124 to BD-FR-127).
  - [ ] Row 2 (`-e restic_backup_rest_server_host=nas.de.int.wahlberger.dev -e restic_backup_forget_enabled=false`): `RESTIC_REPOSITORY=rest:http://cloud:<password>@nas.de.int.wahlberger.dev:8000/cloud/`, no `restic forget` and no `restic prune` string anywhere in the script (including comments), `restic check --read-data-subset=10%` still present (BD-FR-124, BD-FR-125, BD-FR-128).
  - [ ] `git diff master --stat -- pi-de-int-wahlberger-dev` prints nothing; the cloud diff contains no `pi.de.int.wahlberger.dev` line other than the pre-existing default (BD-AC-11 cloud part).
  - [ ] README contains DOC-K1 and DOC-K2 (BD-FR-129, BD-FR-130); cloud lint passes.
- Verification: `cd cloud-wahlberger-dev && yamllint . && ansible-lint && ansible-playbook site.yml --syntax-check`; the BD-AC-12 render command for each template with `-e restic_backup_repo_password=x -e restic_backup_rest_server_password=y` substituted for the vault file when the vault password is not available (record which form was used), then `grep` assertions listed above.
- Gate: host    Risk/notes: the 04:30 change applies to cloud at the next cloud run of `site.yml` even though the NAS server does not exist yet, which is intended (BD-CC-07, the cloud backup to the Pi continues). The shell comment text in the script must not contain the words `restic forget`/`prune` when the switch is off: wrap the whole block, comments included, in the `if`.

#### T-19 — NAS wiring W1: site.yml order and flags, vars, vault example, retire the old role          [ ] todo
- Type: slice
- Requirements: BD-FR-17, BD-FR-18 (flag mechanism), BD-FR-45, BD-FR-77, BD-FR-78, BD-FR-84, BD-FR-85, BD-FR-86, BD-FR-132, BD-FR-134, BD-FR-135, BD-FR-136, BD-FR-157, BD-FR-158 (flag mechanism), BD-FR-02 (site.yml side), BD-FR-83, BD-FR-131 (diff check), BD-D-01, BD-D-13, BD-CC-09 (retirement of `restic-backup.service` wiring), BD-BR-14
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G5
- Depends on: T-05, T-06, T-10, T-12, T-13, T-17
- Files owned (may modify): `site.yml`, `inventories/production/group_vars/all/vars.yml`, `inventories/production/group_vars/all/vault.yml.example`, `inventories/vm/group_vars/all/vars.yml`, `roles/restic_backup/**` (git rm), `tests/render.d/*` only if a fixture variable changes    Must not touch: `vault.yml`, `README.md`, `CLAUDE.md`, `molecule/**`, any role other than `roles/restic_backup/` (deleted)
- Context: First serialized hot-file task. Site order: `backup_disk` after `storage` and before `snapper`; `db_dump` after `paperless_ngx`, `immich`, `tandoor`, `forgejo` (and `homepage`); `btrbk` after `db_dump` and `backup_disk`; `restic_backup_decommission` where `restic_backup` stood; the old `restic_backup` entry and the `roles/restic_backup/` directory are removed (the dump templates were already ported by T-13). Each new entry has `tags: [<role name>]`; `backup_disk`, `btrbk`, `db_dump` carry `when: backup_disk_enabled | bool`; the decommission entry carries `when: restic_backup_decommission_enabled | bool` only. `vars.yml`: `backup_disk_enabled: false` with a comment naming runbook step 3; `restic_backup_decommission_enabled: false` with a comment naming step 5 and stating the old job is removed from step 5; `backup_disk_uuid` placeholder; `backup_disk_freshness_checks` for production (`/mnt/backup/btrbk/data`, `/mnt/backup/btrbk/containers`, `/mnt/data/restic-repos/cloud/snapshots`, each 26); `disk_space_paths` gains `/mnt/backup/btrbk`; all `restic_backup_*` password variables and the old comments removed (the decommission flag is the only `restic_backup_*` line); `vault.yml.example` keeps `vault_restic_backup_repo_password` and `vault_restic_backup_rest_server_password` with comments saying they are kept only to restore from the Pi's frozen `nas` repository. The notify wiring comments in `site.yml` that mention `restic_backup` are rewritten (BD-CC-09).
- Acceptance criteria (verifiable):
  - [ ] `ansible-playbook site.yml --list-tasks` and `--tags <role> --list-tasks` for `backup_disk`, `btrbk`, `db_dump`, `restic_backup_decommission` show the order `storage` < `backup_disk` < `snapper`; `paperless_ngx`, `immich`, `tandoor`, `forgejo` < `db_dump` < `btrbk`; `backup_disk` < `btrbk`; and each `--tags` listing contains that role's tasks (BD-AC-05 for the four roles; `restic_server` rows are completed in T-20).
  - [ ] `git ls-files roles/restic_backup` and `grep -nE 'role:\s*restic_backup\b' site.yml` print nothing (BD-AC-10); `grep -n 'backup_disk_init' site.yml` prints nothing (BD-FR-02).
  - [ ] `vars.yml` sets `backup_disk_enabled: false` with the step-3 comment and `restic_backup_decommission_enabled: false` with the step-5 comment; `disk_space_paths` lists `/`, `/mnt/data`, `/mnt/containers`, `/mnt/backup/btrbk`; `grep -nE '^\s*restic_backup_' vars.yml | grep -v restic_backup_decommission_enabled` prints nothing (BD-AC-09 part, BD-FR-17, BD-FR-45, BD-FR-84, BD-FR-157; see the spec-defect note).
  - [ ] `vault.yml.example` still has both BD-FR-85 placeholders, each with a restore-only comment (BD-FR-86); the encrypted `vault.yml` is untouched (`git diff --stat -- inventories/production/group_vars/all/vault.yml` empty).
  - [ ] With `backup_disk_enabled: false` and both flags false, `ansible-playbook site.yml --list-tasks` still parses and a `--check --diff` is NOT run (no live host); the `when:` lines exist on exactly the roles listed (grep).
  - [ ] `git diff master --stat -- pi-de-int-wahlberger-dev` prints nothing; no added line outside `*.md` contains `pi.de.int.wahlberger.dev` (BD-AC-11 NAS part).
- Verification: `cd nas-de-int-wahlberger-dev && yamllint . && ansible-lint && ansible-playbook site.yml --syntax-check && ansible-playbook backup_disk_init.yml --syntax-check && ansible-playbook site.yml --list-tasks | grep -n -E 'backup_disk|btrbk|db_dump|restic'` plus the greps above.
- Gate: host    Risk/notes: syntax-check requires the vault password (`ansible.cfg` -> 1Password); if unavailable, use `ANSIBLE_VAULT_PASSWORD_FILE` with a dummy file as CI does. Deleting `roles/restic_backup/` also deletes the old README that documented the Pi job. Runtime effect on production is nil while the flags are false except the (harmless) rich-rule list set in T-20 and the removal of the old timer is deliberately deferred to step 5, so the old NAS to Pi job keeps running.

#### T-20 — NAS wiring W2: restic_server, firewall rules, vault keys, owner action          [ ] todo
- Type: slice
- Requirements: BD-FR-18 (restic_server), BD-FR-109, BD-FR-110, BD-FR-133, BD-FR-136 (restic_server), BD-FR-137, BD-FR-138, BD-FR-139, BD-FR-140, BD-FR-141, BD-BR-09, BD-D-06, BD-A-13, BD-CC-06, BD-FR-132 to BD-FR-135 (final order check)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G6
- Depends on: T-19, T-16
- Files owned (may modify): `site.yml`, `inventories/production/group_vars/all/vars.yml`, `inventories/production/group_vars/all/vault.yml.example`, `inventories/vm/group_vars/all/vars.yml`    Must not touch: `vault.yml` (owner), `README.md`, `CLAUDE.md`, any role
- Context: Second serialized hot-file task. `site.yml`: `restic_server` after `firewall`, `podman`, `storage` (and after `caddy` if the T-04 decision makes that relevant), `tags: [restic_server]`, `when: backup_disk_enabled | bool`. `vars.yml`: `restic_server_allowed_sources: ["10.10.0.0/16", "10.243.0.0/16"]` with a comment naming home LAN and ZeroTier and that the rich-rule port must equal `restic_server_port`; `firewall_rich_rules` derived from it, one `rule family="ipv4" source address="<CIDR>" port port="{{ restic_server_port }}" protocol="tcp" accept` per entry, ungated (BD-D-06); `restic_server_clients` as the single `cloud` entry using `vault_restic_server_cloud_htpasswd_password | default('')`; `restic_server_maintenance_repo_password` from `vault_restic_server_cloud_repo_password | default('')`; `8000/tcp` is not added to `firewall_allowed_ports`. `vault.yml.example`: placeholders for both new keys, each commented with the cloud-wahlberger-dev key whose value it must equal. **Owner action (not an agent task):** add the two keys to the encrypted `vault.yml` (htpasswd value = the Pi's current `vault_restic_server_cloud_htpasswd_password`, repo password = cloud's `vault_restic_backup_repo_password`; BD-BR-09, BD-A-13) with `ansible-vault edit`.
- Acceptance criteria (verifiable):
  - [ ] `ansible-playbook site.yml --list-tasks` shows `firewall`, `podman`, `storage` before `restic_server`, and `--tags restic_server --list-tasks` lists its tasks (BD-AC-05 complete).
  - [ ] `vars.yml` evaluates (via `ansible localhost -m debug -a var=firewall_rich_rules -e @vars.yml` or `ansible-inventory --host`) to exactly two rules, for `10.10.0.0/16` and `10.243.0.0/16`, each with `port port="8000" protocol="tcp" accept`; `firewall_allowed_ports` has no `8000/tcp` (BD-FR-109, BD-FR-110).
  - [ ] `restic_server_clients` and `restic_server_maintenance_repo_password` match BD-FR-138/139 text exactly; `vault.yml.example` has the two new placeholders with the BD-FR-140 comments (BD-AC-09).
  - [ ] Decrypted-value checks of BD-AC-09 (both BD-BR-09 equalities, the four keys present) are marked `pending-owner` until the owner has edited `vault.yml`; the task is not closed with them unverified (status log records who checked and when).
  - [ ] With all flags false, the `when:` expressions on the four backup roles and the decommission role are present exactly once each (grep).
- Verification: `cd nas-de-int-wahlberger-dev && yamllint . && ansible-lint && ansible-playbook site.yml --syntax-check && ansible-playbook site.yml --list-tasks | grep -n -E 'restic_server|firewall|podman|storage'`; `ansible-vault view inventories/production/group_vars/all/vault.yml | grep -c -E '^vault_restic_(backup_repo|backup_rest_server|server_cloud_htpasswd|server_cloud_repo)'` (expected 4, owner/qa with vault access).
- Gate: host    Risk/notes: the rich rules apply from the first run after merge even though nothing listens on 8000 yet (BD-D-06): harmless but visible in `firewall-cmd`; the test of "no listener added before step 5" is BD-AC-59/85.

#### T-21 — Molecule converge comments (BD-FR-150) and decommission converge (BD-FR-151)          [ ] todo
- Type: enabling
- Requirements: BD-FR-150, BD-FR-151, BD-NFR-04, BD-NFR-01, BD-AC-03
- Agent: ansible-doctor    Priority: P2    Size: S    Parallel group: G6
- Depends on: T-19, T-16
- Files owned (may modify): `molecule/default/converge.yml`, `molecule/default/molecule.yml` (only if needed for the new role), `molecule/default/Dockerfile.j2` (only if needed)    Must not touch: roles
- Context: The container scenario cannot converge `backup_disk`, `btrbk`, `db_dump`, `restic_server` (real disks, Podman, firewalld). Each gets a comment in `converge.yml` stating why. `restic_backup_decommission` is converged (Could) because it needs only systemd. `notify_failure` and `disk_space` are already converged and must still pass.
- Acceptance criteria (verifiable):
  - [ ] `converge.yml` contains a comment naming the reason for each of `backup_disk`, `btrbk`, `db_dump`, `restic_server` (BD-FR-150).
  - [ ] `molecule test` exits 0 with no idempotence change and no deprecation warning, including `restic_backup_decommission` converged twice (BD-FR-151, BD-NFR-04, BD-AC-03).
  - [ ] No `noqa`, `skip_list`, `warn_list` added (BD-NFR-03).
- Verification: `cd nas-de-int-wahlberger-dev && molecule test` (docker), `grep -n -B1 -E 'backup_disk|btrbk|db_dump|restic_server' molecule/default/converge.yml`.
- Gate: host (container)    Risk/notes: if converging the decommission role breaks the molecule image (no timers present is the normal state), keep it as a documented skip and downgrade BD-FR-151 (Could) with a note in the status log.

#### T-22 — Stale restic_backup references and Tandoor rotation doc (DOC-T)          [ ] todo
- Type: docs
- Requirements: BD-FR-152, BD-FR-153, BD-CC-03, BD-CC-04, BD-AC-14, BD-AC-13 row DOC-T
- Agent: docs-writer    Priority: P1    Size: S    Parallel group: G6
- Depends on: T-19
- Files owned (may modify): `roles/tandoor/README.md`, `roles/immich/README.md`, `roles/forgejo/README.md`, `roles/forgejo/templates/forgejo.container.j2` (comment only), `roles/notify_failure/README.md`, `roles/notify_failure/templates/notify-failure-immediate@.service.j2` (comment only), `roles/reboot_notify/README.md`    Must not touch: `roles/tandoor/defaults/**` (has unrelated uncommitted changes), any other file, `CLAUDE.md`, `README.md`
- Context: After the old job is retired, remaining docs must not describe `restic_backup` or `restic-backup.service` as deployed on the NAS. Update Tandoor's rotation instruction to `ansible-playbook site.yml --tags tandoor,db_dump` (no `--tags tandoor,restic_backup`), repoint Immich/Forgejo backup sections to `db_dump` + btrbk (dumps in `/mnt/containers/db-dumps`, crash-consistent live data, BD-CC-04/05), `notify_failure` examples to `btrbk.service`/`db-dump.service`, `reboot_notify` pattern reference. The two `.j2` comment edits use Jinja comments; this changes the rendered Quadlet once and causes one Forgejo restart on the next real apply, which the forgejo README notes.
- Acceptance criteria (verifiable):
  - [ ] `roles/tandoor/README.md` contains `--tags tandoor,db_dump` and does not contain `--tags tandoor,restic_backup` (DOC-T).
  - [ ] `grep -rn -i 'restic_backup\|restic-backup' nas-de-int-wahlberger-dev --exclude-dir=reqs --exclude=PLAN.md --exclude=PLAN-backup.md` shows only matches in `roles/restic_backup_decommission/`, the `site.yml`/`vars.yml` flag lines and their comments, text about the Pi's frozen `nas` repository or the BD-FR-85 keys, or text describing the job as removed (BD-AC-14; CLAUDE.md and README.md are cleaned by T-23/T-24).
  - [ ] The README texts for immich/forgejo state the new dump location and that live Postgres/SQLite files are backed up crash-consistently (BD-CC-05).
  - [ ] `git diff -- roles/tandoor/defaults roles/mealie_decommission` shows no change made by this task.
- Verification: `cd nas-de-int-wahlberger-dev && grep -rn -i 'restic_backup\|restic-backup' . --exclude-dir=reqs --exclude-dir=.ansible --exclude-dir=.ansible_cache --exclude=PLAN.md --exclude=PLAN-backup.md`; `yamllint . && ansible-lint`.
- Gate: host    Risk/notes: the one-time Forgejo restart (see Assumptions) is accepted.

#### T-23 — NAS README.md "Backups": cut-over runbook, operations and restore          [ ] todo
- Type: docs
- Requirements: BD-FR-147, BD-FR-149, BD-FR-152 (README part), BD-BR-01, BD-BR-14, BD-BR-10 (pointer), DOC-N1 to DOC-N7, DOC-O1 to DOC-O8, DOC-O10, DOC-O11, BD-A-09, BD-A-16, BD-A-17
- Agent: docs-writer    Priority: P1    Size: M    Parallel group: G7
- Depends on: T-20, T-10, T-16, T-18
- Files owned (may modify): `README.md`    Must not touch: `CLAUDE.md`, roles
- Context: One "Backups" section holding the runbook steps 0 to 7 in order with the exact command of each step (spec Primary flow), the step-1 checks (size within 1 %, first and last MiB zero via `cmp -n 1048576 /dev/zero`, free space on `/mnt/data` at least 3x the Pi's cloud repository, the 50 % rule), the migration commands of step 6, the "do not continue unless" gates (BD-BR-01, BD-BR-14, `osc signkey filesystems` fingerprint cross-check), rollback (DOC-N5), the cut-over flags and "the Pi stays unchanged" (DOC-N6), and the operations/restore subsection: DOC-O1 (one file from `/mnt/backup/btrbk/<source>/<snapshot>/`), O2 (whole subvolume via btrfs send/receive), O3 (database from `/mnt/containers/db-dumps/`), O4 (`restic restore` on cloud against the NAS), O5 (Pi's frozen `nas` repository with the two kept keys), O6, O7 (restore the cloud repository with `cp -a`/`rsync -a` from a snapper `data` snapshot or a btrbk copy, then `restic check`), O8, O10, O11. Marks which steps' smoke rows (BD-AC-80) to check. Also removes README mentions of the old NAS restic job.
- Acceptance criteria (verifiable):
  - [ ] Each DOC-N1 to N7 and DOC-O1 to O8, O10, O11 item (BD-AC-13) is present; steps 0 to 7 appear in order with an exact command each (grep for the step headings and the literal commands, including the `rsync -a --numeric-ids pi:/mnt/data/restic-repos/cloud/ nas:/mnt/data/restic-repos/cloud/` line and `chown -R restic-server:`).
  - [ ] The documented commands, flag names, paths and unit names equal those in the roles (spot check by grep against `defaults/main.yml` of each role).
  - [ ] README no longer says `restic_backup` runs on the NAS (BD-AC-14 for this file).
- Verification: `grep -n -E 'osc signkey filesystems|cmp -n 1048576|chown -R restic-server|--skip-tags backup_disk,btrbk|DOC' README.md` plus a reviewer walk-through of steps 0-7.
- Gate: host    Risk/notes: the runbook is not executed this cycle; commands are verified against the VM in T-27 to T-30 and fixed through this task if they differ.

#### T-24 — NAS CLAUDE.md: stack rows, data and secrets, commands (DOC-C)          [ ] todo
- Type: docs
- Requirements: BD-FR-146, BD-FR-152 (CLAUDE.md part), BD-AC-13 rows DOC-C1 to DOC-C7, BD-CC-09
- Agent: docs-writer    Priority: P1    Size: S    Parallel group: G7
- Depends on: T-20
- Files owned (may modify): `CLAUDE.md`    Must not touch: `README.md`, roles
- Context: Updates the Stack table (rows for `backup_disk`, `btrbk`, `db_dump`, `restic_server`, `restic_backup_decommission`; `restic_backup` row removed; `notify_failure` row naming `btrbk.service`, `db-dump.service`, `restic-server.service`, `restic-server-maintenance.service`, `backup-disk-health.service` and the smartd hook), "Data & secrets" (the backup disk at `/mnt/backup/btrbk`, restic repositories at `/mnt/data/restic-repos`, "Only `backup_disk_init.yml` formats the backup disk", the two new vault keys and the two kept restore-only keys with their reason), "Entry point & commands" (`tests/render-check.sh` and the `-i inventories/vm` command line), and the `forgejo` row's `restic_backup` mention.
- Acceptance criteria (verifiable):
  - [ ] DOC-C1 to DOC-C7 are each present (grep per item); no Stack row describes `restic_backup` as deployed (DOC-C2).
  - [ ] BD-AC-14 grep over `CLAUDE.md` shows only allowed kinds of matches.
- Verification: `grep -n -E 'backup_disk|btrbk|db_dump|restic_server|restic_backup_decommission|render-check|inventories/vm|Only .backup_disk_init.yml' CLAUDE.md`.
- Gate: host    Risk/notes: none.

#### T-25 — Static gate script and CI wiring          [ ] todo
- Type: enabling
- Requirements: BD-NFR-02, BD-NFR-03, BD-AC-01, BD-AC-02, BD-AC-04, BD-AC-05, BD-AC-06, BD-AC-07, BD-AC-09 (non-vault part), BD-AC-10, BD-AC-11, BD-AC-14, BD-AC-15, BD-AC-16, BD-FR-02, BD-FR-83, BD-FR-131, BD-FR-64
- Agent: ci-pipeline-engineer    Priority: P1    Size: M    Parallel group: G8
- Depends on: T-21, T-22, T-23, T-24
- Files owned (may modify): `tests/static-checks.sh`, `.github/workflows/ci.yml`    Must not touch: roles, `site.yml`, docs
- Context: Scripts every [S] scenario that is a grep/diff so the final gate is one command: AC-02 (no lint suppression in the diff against master excluding reqs), AC-04 (a to d), AC-05 (ordering from `--list-tasks`), AC-06 (defaults vs argument_specs, `main`/`init` entry points, `firewall_rich_rules`), AC-08 (Renovate regex), AC-09 (non-vault part), AC-10, AC-11, AC-14, AC-15, AC-16 (no production secret value in `inventories/vm/`, skip with a notice if the vault password is unavailable), plus the lint triplet for both directories and the extra `backup_disk_init.yml --syntax-check` that CI does not run today. CI: adds a job that runs `tests/render-check.sh` and `tests/static-checks.sh` in the NAS directory (ubuntu runner has docker; vault password dummy as in the existing job) without touching the generic matrix job semantics.
- Acceptance criteria (verifiable):
  - [ ] `tests/static-checks.sh` exits 0 on the feature branch tip, prints one PASS/FAIL line per BD-AC id, and exits non-zero when a seeded violation is introduced temporarily (for example a `# noqa` line, a `chattr +C` in a role, a stray `restic_backup` role entry), each seeded case demonstrated and reverted (not committed).
  - [ ] The CI workflow file is valid (`yamllint`, `actionlint` if available) and the new job references both scripts; the existing `validate` matrix job is unchanged.
  - [ ] The BD-AC-09 decrypted-vault checks print `SKIPPED (no vault access)` rather than PASS when the vault cannot be decrypted.
- Verification: `cd nas-de-int-wahlberger-dev && tests/static-checks.sh && tests/render-check.sh && molecule test`; `yamllint .github/workflows/ci.yml`.
- Gate: host    Risk/notes: the CI job cannot be run locally end to end; `act` is not assumed. Scripted checks must not weaken the spec's commands: copy them verbatim where possible.

#### T-26 — Security review of the feature          [ ] todo
- Type: security
- Requirements: BD-FR-03, BD-FR-04, BD-FR-05, BD-FR-06, BD-FR-90, BD-FR-92, BD-FR-98, BD-FR-99, BD-FR-107, BD-FR-111, BD-FR-113, BD-FR-114, BD-FR-160, BD-BR-03, BD-BR-06, BD-BR-07, BD-BR-10, BD-A-21, BD-D-04, BD-D-06, BD-D-14 (read-only audit)
- Agent: security-auditor    Priority: P1    Size: S    Parallel group: G7
- Depends on: T-20
- Files owned (may modify): none (findings are returned as a report; fixes become new or reopened tasks)    Must not touch: all files
- Context: Feature touches destructive disk operations, secrets, network exposure (new listening port, firewall), a third-party signing key and a rest-server that holds a repository password on the NAS. Audit the diff on the feature branch against master.
- Acceptance criteria (verifiable):
  - [ ] Report covers: init playbook refusal completeness (R-01 to R-10 ordering before any write, no force flags, confirm only from extra-var), secrets handling (htpasswd, maintenance password file mode and `no_log`, dump credentials, no secret in unit files or the VM inventory), firewall rule scope and the Podman bypass question, container privileges of `restic-server`, the prune-guard threat model (forged snapshot times, boundary), the OBS key pinning, `smartd` hook injection surface (device path and message in email), and file modes/ownership on `/mnt/containers/db-dumps` and `/mnt/data/restic-repos`.
  - [ ] Every finding has severity, file and line, and a recommended fix; "no findings" is stated explicitly per area when true.
- Verification: reviewer reads the report; Critical/High findings reopen the owning task.
- Gate: host    Risk/notes: none.

#### T-27 — VM validation 1: init, mount and scrub (scenarios BD-AC-20 to BD-AC-24, BD-AC-26, BD-AC-56)          [ ] todo
- Type: hardware-validation
- Requirements: BD-FR-06 to BD-FR-16, BD-FR-20 to BD-FR-24, BD-FR-26, BD-FR-29, BD-FR-30 to BD-FR-32, BD-BR-01 (part), BD-BR-02, BD-BR-03, BD-D-17
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: -
- Depends on: T-25, T-26, T-02 and an owner-provided VM fixture
- Files owned (may modify): none in the repository except failure reports; fixes go through the owning task    Must not touch: all production files; never target nas, cloud or pi
- Context: Executes the [V] scenarios of the disk area on the disposable VM. State: `blocked: no VM`. Run first because later scenarios assume an initialised and mounted backup filesystem.
- Acceptance criteria (verifiable):
  - [ ] BD-AC-20 rows 1 to 17: each row's play fails with its R-ID in the message and the saved fingerprint (wipefs, sfdisk, first and last MiB checksums) is unchanged.
  - [ ] BD-AC-21 `--check` run: `failed=0`, all R checks ran, fingerprint unchanged. BD-AC-22: init of the blank disk meets every bullet (GPT, one partition at sector 2048, btrfs `backups`, only `@btrbk`, printed UUID equals partition 1's UUID, other disks' checksums unchanged). BD-AC-23: second run `changed=0`.
  - [ ] BD-AC-24 rows 1 to 5 fail in `backup_disk` with the listed messages and unchanged fstab; BD-AC-26: mount options, fstab line, no `C` attribute, `700 root:root`; BD-AC-56: scrub mount points and monthly timer.
- Verification: the exact procedures in BD-AC-20 to BD-AC-24, BD-AC-26, BD-AC-56 (copy outputs into the status log).
- Gate: simulator    Risk/notes: the VM is the only place the init playbook may run in this cycle. A fix to the init logic reopens T-07 and restarts this task from BD-AC-20.

#### T-28 — VM validation 2: btrbk and db_dump (BD-AC-29 to BD-AC-37)          [ ] todo
- Type: hardware-validation
- Requirements: BD-FR-47 to BD-FR-63, BD-FR-65 to BD-FR-76, BD-FR-161, BD-BR-11, BD-BR-15, BD-A-01, BD-A-07, BD-A-08, BD-NFR-10 (btrbk/db-dump alert), BD-NFR-11
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: -
- Depends on: T-27
- Files owned (may modify): none (reports); fixes through T-11, T-12, T-13    Must not touch: production files
- Context: Runs on the VM after T-27 and after the cloud (VM client) repository has been initialised on the VM rest-server or a plain directory, as BD-AC-30 requires.
- Acceptance criteria (verifiable):
  - [ ] BD-AC-29 rows 1 and 2, BD-AC-30 (first run replicates both sources with `Received UUID`, no `.snapshots` content, `restic-repos/cloud/config` present, fresh dump files), BD-AC-31 (incremental with non-empty parent), BD-AC-32 (read-only target: unit fails and alert within 5 min, next run succeeds), BD-AC-33 (no concurrent btrbk), BD-AC-34 (interrupted transfer completed), BD-AC-35 rows 1 to 4, BD-AC-36 (failed dump keeps previous file, btrbk succeeds), BD-AC-37 (timeout within 120 s) pass with the observations written to the log.
  - [ ] Any scenario that fails reopens the owning task; none is marked passed on inference.
- Verification: the procedures in the listed scenarios.
- Gate: simulator    Risk/notes: BD-AC-33/34 need a 5 GiB random file; allow disk space on the VM.

#### T-29 — VM validation 3: restic-server, firewall, maintenance (BD-AC-39 to BD-AC-52, BD-AC-54)          [ ] todo
- Type: hardware-validation
- Requirements: BD-FR-87 to BD-FR-121, BD-FR-160, BD-BR-06, BD-BR-07, BD-BR-08, BD-A-03, BD-A-05, BD-A-06, BD-A-10, BD-A-11, BD-A-21, BD-NFR-09 (part)
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: -
- Depends on: T-28
- Files owned (may modify): none (reports); fixes through T-14, T-15, T-16, T-05    Must not touch: production files
- Context: Runs on the VM with both flags true. SELinux enforcing, the `ac45-allowed` Podman network present.
- Acceptance criteria (verifiable):
  - [ ] BD-AC-39 (flags, UID not 0, passwd entry, `:Z`), BD-AC-40 (modes, labels, passlib, no secrets in unit files, samba label unchanged), BD-AC-41 (three override cases), BD-AC-42 (401/200/401 or 403), BD-AC-43 (rotation within 60 s), BD-AC-44 (size limit), BD-AC-45 (rich rules and all three client paths, `000` from the default Podman network), BD-AC-46 (append-only), BD-AC-47 (both forged-time rows), BD-AC-48 (retention and check, files owned by the service account), BD-AC-49 (lock wait), BD-AC-50, BD-AC-51, BD-AC-52, BD-AC-54 (undo of a wrong prune) pass.
  - [ ] The A-05 outcome is compared with the T-04 decision; a mismatch reopens T-04 and T-14.
- Verification: the procedures in the listed scenarios.
- Gate: simulator    Risk/notes: BD-AC-45 is the only proof of BD-FR-111; if it fails the network mode changes and BD-AC-39/45 are re-run.

#### T-30 — VM validation 4: flags, guards, units, idempotency, reboot (BD-AC-25, 27, 28, 38, 55, 57 to 60)          [ ] todo
- Type: hardware-validation
- Requirements: BD-FR-18, BD-FR-25, BD-FR-27, BD-FR-28, BD-FR-33, BD-FR-34 to BD-FR-36, BD-FR-46, BD-FR-79 to BD-FR-82, BD-FR-158, BD-FR-159, BD-BR-04, BD-BR-05, BD-BR-12, BD-NFR-01, BD-NFR-05, BD-NFR-06, BD-NFR-07, BD-NFR-08, BD-NFR-09, BD-NFR-10, BD-A-19, BD-A-20, BD-D-17
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: -
- Depends on: T-29
- Files owned (may modify): none (reports); fixes through the owning tasks    Must not touch: production files
- Context: Cross-cutting scenarios that need the full stack up. BD-AC-25 and BD-AC-38 require the dummy `restic-backup` units and may be run first on a fresh state before T-28; if the VM is reset for them, the procedure is recorded.
- Acceptance criteria (verifiable):
  - [ ] BD-AC-25 (flags false: every task of the five roles ok/skipped, dummy units and paths still present), BD-AC-38 (flag true removes dummy units and paths, second run all ok/skipped), BD-AC-27 rows 1 to 6 (mount guards fail before change naming the path; row 6 `failed=0`), BD-AC-28 (detached backup disk: boots to running/degraded, rest-server keeps serving, nothing written below `/mnt/backup`, no `OnFailure` for btrbk, health check fails and alert raised within 5 min, `disk_space` logs `not a mount point`), BD-AC-55 rows 1 to 4, BD-AC-57 (every NAS row of BD-BR-05 and every `RequiresMountsFor`), BD-AC-58 (`changed=0` on the second `site.yml`), BD-AC-59 (only port 8000 added), BD-AC-60 (rest-server answers within 300 s of reboot, backup mount present) pass.
  - [ ] After all four VM tasks pass, the log records "BD-BR-01 gate satisfied for commit <sha>" with the commit hash tested.
- Verification: the procedures in the listed scenarios.
- Gate: simulator    Risk/notes: recording the tested commit hash matters: any later change to roles reopens the affected VM tasks (BD-D-17).

#### T-31 — Production smoke checks and migration validation (owner-run, not executed this cycle)          [ ] todo
- Type: hardware-validation
- Requirements: BD-A-04, BD-A-09, BD-A-16, BD-A-17, BD-FR-17, BD-FR-34 to BD-FR-45, BD-FR-109, BD-FR-128, BD-NFR-01, BD-NFR-05, BD-NFR-06, BD-NFR-07, BD-NFR-09, BD-NFR-11, BD-NFR-12, BD-BR-01, BD-BR-14, BD-AC-80 to BD-AC-87 and BD-AC-83
- Agent: ansible-doctor (assists the owner; runs nothing against nas/cloud/pi without explicit authorisation)    Priority: P2    Size: M    Parallel group: -
- Depends on: T-30 and an explicit, separate owner authorisation to run on production
- Files owned (may modify): none    Must not touch: everything until authorised
- Context: Follows the README runbook (T-23): [H] smoke rows of BD-AC-80 after each step, BD-AC-81 (migration, first cloud backup over ZeroTier, first maintenance run), BD-AC-82 (smartd test email), BD-AC-83 (restore one file), BD-AC-84 (second run `changed=0` on NAS and cloud), BD-AC-85 (only port 8000 added), BD-AC-86 (first seven nightly runs within 90 min / 60 min), BD-AC-87 (first rebootmgr reboot). [H] checks are read-only inspections and normal runs; no fault injection.
- Acceptance criteria (verifiable):
  - [ ] All 14 BD-AC-80 rows pass at their step; BD-AC-81, BD-AC-82, BD-AC-83, BD-AC-84, BD-AC-85, BD-AC-86 and BD-AC-87 pass as specified (copy each observation into the log).
  - [ ] The step-1 preconditions (size within 1 %, zero first and last MiB, free-space and 50 % rules) and the step-4 fingerprint cross-check were recorded before the corresponding steps ran.
- Verification: the procedures in BD-AC-80 to BD-AC-87.
- Gate: hardware (production)    Risk/notes: out of scope for agents in this cycle (BD-C-03). The Pi stays unchanged (BD-BR-13).

### Traceability

Methods: S = static task check, R = tests/render-check.sh, P = pytest, C = container run, V = VM scenario (T-27..T-30), H = production (T-31). "Impl" = implementing task. Where several tasks are listed, the first is the main owner.

| Requirement | Tasks | Verified by (test/procedure) |
|---|---|---|
| BD-FR-01 to BD-FR-05 | T-07 (BD-FR-02 also T-19) | S: BD-AC-04 greps, T-25 |
| BD-FR-06 to BD-FR-16 | T-07, T-27 | V: BD-AC-20 (17 rows), BD-AC-21 to BD-AC-23 |
| BD-FR-17, BD-FR-157 | T-19 | S: BD-AC-09 |
| BD-FR-18, BD-FR-158 | T-19, T-20, T-17 | V: BD-AC-25, BD-AC-38 (T-30) |
| BD-FR-20 to BD-FR-22, BD-FR-26 | T-08 | V: BD-AC-24 (T-27) |
| BD-FR-23, BD-FR-24, BD-FR-29 | T-08 | R: BD-AC-07; V: BD-AC-26 (T-27); H: BD-AC-80 row 1 |
| BD-FR-25 | T-12, T-13, T-14, T-16 (backup_disk side via BD-FR-26 in T-08) | V: BD-AC-27 rows 1-6 (T-30) |
| BD-FR-27, BD-FR-33 | T-10, T-12, T-13, T-14, T-16 | R: BD-AC-07; V: BD-AC-57; H: BD-AC-80 row 6 |
| BD-FR-28 | T-08, T-10, T-12 | V: BD-AC-28 (T-30) |
| BD-FR-30 to BD-FR-32 | T-09 | V: BD-AC-56 (T-27); H: BD-AC-80 row 10 |
| BD-FR-34 to BD-FR-36, BD-FR-159 | T-10 | V: BD-AC-28, BD-AC-55 (T-30); H: BD-AC-80 row 13 |
| BD-FR-37 to BD-FR-42 | T-09 | H: BD-AC-80 row 11, BD-AC-82 (T-31) |
| BD-FR-43, BD-FR-44 | T-09 | R: BD-AC-07 (spindown render) |
| BD-FR-45 | T-19 | S: BD-AC-09 |
| BD-FR-46 | T-06 | V: BD-AC-28 (T-30); C: molecule |
| BD-FR-47 to BD-FR-50 | T-11 | C container run; V: BD-AC-29 (T-28); H: BD-AC-80 row 5 |
| BD-FR-51 to BD-FR-56, BD-FR-161 | T-12 (T-03 decision) | R: BD-AC-07; V: BD-AC-30 (T-28); H: BD-AC-80 rows 2-4, 14 |
| BD-FR-57, BD-FR-58 | T-12 | R: BD-AC-07 |
| BD-FR-59, BD-FR-55 | T-12 | V: BD-AC-31 |
| BD-FR-60 | T-12 | V: BD-AC-32 |
| BD-FR-61 | T-12 | V: BD-AC-33 |
| BD-FR-62, BD-FR-63 | T-12 | V: BD-AC-34 |
| BD-FR-64 | T-12 (and all) | S: BD-AC-15, T-25; H: BD-AC-80 row 12 |
| BD-FR-65 to BD-FR-76 | T-13 (BD-FR-65/66 ordering with T-12; BD-FR-75 T-12) | C shim run; V: BD-AC-30, BD-AC-35 to BD-AC-37 (T-28) |
| BD-FR-77, BD-FR-78 | T-19 | S: BD-AC-10 |
| BD-FR-79 to BD-FR-82 | T-17 | C container run; V: BD-AC-38 (T-30) |
| BD-FR-83, BD-FR-131 | T-17, T-18, T-19, T-25 | S: BD-AC-11 |
| BD-FR-84 to BD-FR-86 | T-19 | S: BD-AC-09 |
| BD-FR-87 to BD-FR-93, BD-FR-96 | T-14 | R/S: BD-AC-39 static; V: BD-AC-39 (T-29); H: BD-AC-80 row 8 |
| BD-FR-88 | T-14 | S: BD-AC-08 |
| BD-FR-94, BD-FR-95, BD-FR-97 to BD-FR-100, BD-FR-160 | T-14 | V: BD-AC-40 (T-29); H: BD-AC-80 row 9 |
| BD-FR-101 to BD-FR-103 | T-14 | V: BD-AC-41 |
| BD-FR-104, BD-FR-105 | T-14 | V: BD-AC-43, BD-AC-42 |
| BD-FR-106, BD-FR-112, BD-FR-117, BD-FR-118 | T-16, T-15 | P: unit tests; V: BD-AC-48; H: BD-AC-81 |
| BD-FR-107 | T-14, T-16 | R: grep; V: BD-AC-40, BD-AC-52 |
| BD-FR-108 | T-05 | S; V: BD-AC-45 |
| BD-FR-109, BD-FR-141 | T-20 | S: BD-AC-09; H: BD-AC-80 row 7 |
| BD-FR-110 | T-14, T-20 | S; V: BD-AC-45 |
| BD-FR-111 | T-04, T-14 | V: BD-AC-45 (T-29); H: BD-AC-81 |
| BD-FR-113 | T-16 | R: grep; V: BD-AC-52 |
| BD-FR-114 to BD-FR-116 | T-15, T-16 | P: unit tests; V: BD-AC-47, BD-AC-54 |
| BD-FR-119, BD-FR-120, BD-FR-121 | T-15 | P; V: BD-AC-50, BD-AC-49, BD-AC-51 |
| BD-FR-124 to BD-FR-128 | T-18 | S: BD-AC-12 rows 1-2; H: BD-AC-81 |
| BD-FR-129, BD-FR-130 | T-18 | S: BD-AC-13 DOC-K1/K2 |
| BD-FR-132 to BD-FR-136 | T-19, T-20 | S: BD-AC-05 |
| BD-FR-137 to BD-FR-140 | T-20 (owner action for vault.yml) | S: BD-AC-09 (decrypted part pending-owner) |
| BD-FR-142 to BD-FR-144 | T-05, T-07, T-08..T-17 (each new role) | S: BD-AC-06, T-25 |
| BD-FR-145 | T-07 to T-17 (each role README) | S: BD-AC-13 DOC-R1 to R3 |
| BD-FR-146 | T-24 | S: BD-AC-13 DOC-C1 to C7 |
| BD-FR-147 | T-23 | S: BD-AC-13 DOC-N1 to N7 |
| BD-FR-148 | T-07 (B1 to B4), T-08 (B5) | S: BD-AC-13 DOC-B1 to B5 |
| BD-FR-149 | T-23, T-12, T-14, T-16 (role READMEs) | S: BD-AC-13 DOC-O1 to O12; V/H: BD-AC-54, BD-AC-83 |
| BD-FR-150, BD-FR-151 | T-21 | C: BD-AC-03 (molecule) |
| BD-FR-152, BD-FR-153 | T-22, T-23, T-24 | S: BD-AC-14, BD-AC-13 DOC-T |
| BD-FR-154 | T-01 (+ each role registers templates) | R: BD-AC-07 |
| BD-FR-155, BD-FR-156 | T-01, T-02 | S: BD-AC-16, BD-AC-13 DOC-V |
| BD-FR-19, BD-FR-122, BD-FR-123 | deleted in the spec | n/a |
| BD-BR-01 | T-23, T-30 (gate record) | S: BD-AC-13 DOC-N4; H |
| BD-BR-02, BD-BR-03 | T-07, T-08 | V: BD-AC-20, BD-AC-22, BD-AC-23 |
| BD-BR-04, BD-BR-05 | T-10, T-12, T-13, T-14, T-16, T-18 (cloud timer) | R: BD-AC-07; V: BD-AC-57, BD-AC-27 |
| BD-BR-06 | T-14 | V: BD-AC-46 |
| BD-BR-07, BD-BR-08 | T-15, T-16 | P; V: BD-AC-47, BD-AC-48, BD-AC-54 |
| BD-BR-09 | T-20 (owner action) | S: BD-AC-09 decrypted part |
| BD-BR-10 | T-14 (DOC-O9) | S: BD-AC-13 DOC-O9; audit T-26 |
| BD-BR-11 | T-13, T-12 | V: BD-AC-36 |
| BD-BR-12 | T-08, T-10 | V: BD-AC-28 |
| BD-BR-13 | T-18, T-19, T-25 | S: BD-AC-11 |
| BD-BR-14 | T-23, T-19 | S: BD-AC-13 DOC-N4; H: BD-AC-81 |
| BD-BR-15 | T-12 | R: BD-AC-07 |
| BD-NFR-01 | all tasks (DoD) | V: BD-AC-58; H: BD-AC-84 |
| BD-NFR-02, BD-NFR-03 | all tasks (DoD), T-25 | S: BD-AC-01, BD-AC-02 |
| BD-NFR-04 | T-06, T-21 | C: BD-AC-03 |
| BD-NFR-05, BD-NFR-06 | T-10, T-18 | V: BD-AC-55, BD-AC-57 |
| BD-NFR-07 | T-14, T-20 | V: BD-AC-59; H: BD-AC-85 |
| BD-NFR-08 | T-08, T-10, T-14 | V: BD-AC-28 |
| BD-NFR-09 | T-14 | V: BD-AC-60; H: BD-AC-87 |
| BD-NFR-10 | T-10, T-12, T-13, T-16 | V: BD-AC-28, BD-AC-32; H: BD-AC-82 |
| BD-NFR-11, BD-NFR-12 | T-12, T-13, T-18 (design) | H: BD-AC-86 |

Scenario coverage (64 scenarios): BD-AC-01, 02 -> T-25; 03 -> T-21; 04 -> T-07/T-25; 05 -> T-19/T-20; 06 -> T-25 (+ each role); 07 -> T-01 + role tasks; 08 -> T-14; 09 -> T-19/T-20 (vault part owner); 10 -> T-19; 11 -> T-18/T-19/T-25; 12 -> T-18; 13 -> T-02, T-07, T-08, T-14, T-18, T-22, T-23, T-24; 14 -> T-22/T-25; 15 -> T-12/T-25; 16 -> T-01/T-25; 20 to 24, 26, 56 -> T-27; 25, 27, 28, 38, 55, 57 to 60 -> T-30; 29 to 37 -> T-28; 39 to 52, 54 -> T-29; 80 to 87 -> T-31.

### Task status log   (orchestrator updates checkboxes; never delete history)
- 2026-10-09: plan created (planner). 31 tasks, all `[ ] todo`. T-27 to T-30 `blocked: no VM`; T-31 `blocked: needs production authorisation (BD-C-03)`; vault.yml keys in T-20 `pending-owner`.
- 2026-10-09: T-08 implemented (uncommitted): probe mount uses `ro,rescue=nologreplay,subvol=` like init.yml; render-check and static-checks pass.
- 2026-10-09: T-09 implemented (uncommitted): scrub lineinfile uses `create: true` so `--check` works on a fresh host; smartd render asserts tightened.
- 2026-10-09: T-12 implemented (uncommitted): samba guard is a prefix test; target_preserve default and 7d override asserted in separate render items.
- 2026-10-09: T-14 implemented (uncommitted): htpasswd needs python3<minor>-bcrypt next to passlib (both verified with `rpm -q`); Quadlet uses `notify-failure-immediate`.
- 2026-10-09: T-16 implemented (uncommitted): maintenance unit restarts restic-server via `ExecStartPost=+systemctl try-restart` after a successful run (resets the `--max-size` counter).
- 2026-10-09: T-25 implemented (uncommitted): static-checks.sh quotes tool commands (arrays) and AC-14 allow-list names each allowed kind.
