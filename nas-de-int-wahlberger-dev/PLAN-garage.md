## Plan: Garage S3 store on the NAS (service only; layout, buckets, keys and retention are user-owned)          spec: nas-de-int-wahlberger-dev/reqs/garage-sstate.md (v1.1, ready)   planned: 2026-10-18   re-planned for v1.1 (GS-CC-40): 2026-10-18   status: in progress

Separate from `PLAN.md` (Tandoor) and `PLAN-backup.md` (backup); this plan never edits them. Paths are relative to `nas-de-int-wahlberger-dev/` ("NAS dir"). IDs `GS-*` are the spec's. The spec's Given/When/Then text of each cited `GS-AC-nn` is normative: where a criterion below is shortened, the spec wins. Task ids are stable; dropped tasks keep their id.

Scope after v1.1 (GS-CC-40): Ansible sets up only the Garage service: the two subvolumes, `garage.toml`, the secret files, the Quadlet, the readiness wait, the Caddy routes, the btrbk backup and the restore procedure. The role runs one Garage command, `garage status`. Node layout, buckets, keys, grants, quotas, website flags and lifecycle rules are done by the user with the CLI from the role README (GS-FR-138, GS-FR-139, GS-FR-140). A fresh store therefore runs with "NO ROLE ASSIGNED" and stores nothing until the user applies the layout (GS-BR-16).

### Assumptions / open risks

Where each step can be verified (used in every task as `Where:`)
- **LOCAL** = on Erik's Mac, no NAS and no VM: `yamllint`, `ansible-lint`, `--syntax-check`, `tests/render-check.sh` (docker/podman), pytest or `ansible-playbook` against localhost for pure-assert logic, a throwaway Garage or Caddy container.
- **VM** = the qemu fixture `tests/vm/` (`up.sh`, `snapshot.sh clean`, `reset.sh clean`; two btrfs disks for `/mnt/data` and `/mnt/containers`, `/var` already a subvolume `@/var`, snapper configs `data`/`containers`, Podman, firewalld). Disposable, fake secrets only, never the NAS (BD-C-03).
- **NAS** = production `nas.de.int.wahlberger.dev`. **Needs Erik's explicit approval (A-gates below). The planner and the implementers do not run anything against the NAS.** "VM-only" is never reported as NAS-verified.

Approval gates (Erik) - unchanged by v1.1
- **A0** (design, no NAS): narrowing the `BD-AC-04` guard in `tests/static-checks.sh` for `roles/garage/tasks/storage.yml` only. Implemented in the working tree by T-01.
- **A1** (Vault, no NAS): T-15 adds the two `vault_garage_*` values to the encrypted `vault.yml` (1Password unlock).
- **A2** (NAS, read-only): T-23 runs `df -B1` on the NAS for the GS-AC-47 capacity analysis.
- **A3** (NAS, change): T-24 production `--check --diff` then apply.
- **A4** (NAS, change/disruption): T-25 production validation, including Erik running the README layout and bucket steps, stopping `garage.service` for GS-AC-34 and a 1 GiB upload.
- **A5** (NAS, read-only): T-26 day-30 and day-120 measurements.
- **M1/M2/M3** merge gates before enabling: M1 = T-04 (btrbk role) merged, M2 = T-06 (caddy role) merged, M3 = T-05 (backup-btrbk-and-db-dump.md update) merged (GS-FR-115, 116, 117). Commits, pushes and merges happen only when Erik asks.
- **GS-P-01** (ZeroTier flow rule for `10.243.73.1` to `:443`) and consumer config (meta-sluss, netcup runner) are Erik's external preconditions / out of scope; they do not block the LAN-side apply.

Risks and decisions
- **Static-check conflict (A0).** `tests/static-checks.sh` `ac04` greps every role for `subvolume (create|delete)` and `chattr +C`; the carve-out for `roles/garage/tasks/storage.yml` is in place. Avoid filenames `init*.yml` and templated `include_*`/`import_*` in `roles/garage`. v1.1 adds a new static guard (GS-AC-74): no state-changing Garage command in `roles/garage/tasks/` and `templates/`.
- **Untracked baseline.** `reqs/garage-sstate.md` is untracked and `reqs/index.md`, `reqs/backup-*.md`, `roles/backup_disk/**` carry unrelated uncommitted edits, as do the done tasks' files. Git worktrees branch from commits and would not contain them. Before parallel worktrees, Erik commits the current tree or the orchestrator runs agents in the main checkout. No task here may touch `roles/backup_disk/**`, `roles/tandoor/**`, `PLAN.md`, `PLAN-backup.md`.
- **Role file ownership.** Stage files in `roles/garage/tasks/`: `preflight.yml` (T-07), `storage.yml` (T-08), `secrets.yml` (T-09), `deploy.yml` (T-10). The v1.1 trim removes `bootstrap.yml` and `lifecycle.yml` and their imports from `tasks/main.yml` (T-01 rework). `defaults/main.yml`, `meta/argument_specs.yml` and `tasks/main.yml` are owned by T-01; no other task edits them.
- **Runtime facts across stage files.** `garage_uid`/`garage_gid` are set (via `getent`) in `storage.yml` and consumed by the Quadlet and `secrets.yml`.
- **Unverified items to settle on the VM:** GS-A-29 (`Environment=GARAGE_CONFIG_FILE` is read; GS-AC-35), GS-A-30 (Quadlet generator `-dryrun` in the render-check container; fallback GS-AC-37), GS-A-24 (SELinux, `ro` mount without relabel; GS-AC-22), GS-A-25/27 (node key and live-LMDB restore; GS-AC-55). A failure goes to `requirements-engineer`, not worked around (the spec names the amendment each time).
- **The README is both deliverable and test input.** The test setup (T-13) and the README steps (T-21) must contain the same commands; T-21 verifies this with a diff, T-17 runs them.
- **Pure-assert logic is tested locally first** (GS-AC-25 via pytest-driven localhost playbooks); the spec marks the scenarios [V], so T-16 re-runs them on the VM before they count as verified.
- **No teardown in spec.** Setting `garage_enabled: false` after enabling stops managing Garage but does not remove it.
- Production `vars.yml` evaluation without the vault password works lazily because of the `| default('')` indirections (`ansible localhost -e @inventories/production/group_vars/all/vars.yml -m ansible.builtin.debug -a var=...`).
- Maximum parallelism: no constraint given. Suggested at most 4 worktrees at a time.

### Definition of Done (all tasks)
- Code formatted and linted: from the NAS dir `yamllint .` and `ansible-lint` (production profile) exit 0; `ansible-playbook site.yml --syntax-check` exits 0; `tests/render-check.sh` stays green; `tests/static-checks.sh` passes. Unwired or partial roles are checked with `tests/syntax-check-role.sh <role>`.
- Task acceptance criteria verified by qa-verifier at the `Where:` level stated; unit tests for new logic to the test-quality tier; no skipped or weakened tests; no new warnings; no rule suppressions of any kind; docs/config updated; no secrets committed; no production vault value anywhere in `inventories/vm/`.
- Role conventions: FQCN, ansible-core 2.16 module names, idempotent built-ins, role-prefixed variables, `meta/argument_specs.yml` declares every input, README, no `meta/main.yml` dependencies, `no_log: true` on every secret-bearing task except the approved assert-only exception of GS-FR-21 / GS-CC-39.
- A scenario is reported verified only at the level actually run (LOCAL, VM or NAS).

### Execution order
Walking skeleton: **T-01** (done in the working tree; v1.1 trim open).

Status at re-plan (coordinator report, working tree): done T-02, T-03, T-04, T-05, T-06, T-08; done but needing the v1.1 trim T-01, T-07; dropped T-11, T-12; open T-09, T-10, T-13 to T-26.

Parallel groups (members are file-disjoint; start a group when its dependencies are done):
- **G0 (done):** {T-01 (trim open), T-02, T-03, T-04, T-05, T-06, T-07 (trim open), T-08}. M1/M2/M3 content exists; merging still needs Erik.
- **G1 (start now, all file-disjoint):** {T-01 trim, T-07 trim, T-09, T-10, T-13, T-14, T-15}. Files: T-01 `defaults/main.yml` + `argument_specs.yml` + `tasks/main.yml` + stage stubs + `static-checks.sh`; T-07 `preflight.yml` + its pytest; T-09 `secrets.yml`; T-10 `deploy.yml` + `garage.toml.j2` + handlers + `40-garage.yml`; T-13 `inventories/vm` + `vault.yml.example` + `tests/vm/scenarios/garage-test-setup.sh`; T-14 production `vars.yml` + `42-garage-production.yml` + its pytest; T-15 `vault.yml`.
- **VM sequence (one VM):** T-16 (V1) -> T-17 (V2) -> T-18 (V3) -> T-19 (V4). No step has a long wall-clock wait any more (the 48 h expiration demonstration is gone).
- **G2:** {T-20 security review} after T-09, T-10, T-14; {T-21 docs} after T-19, T-20 (and T-13, T-02).
- **Enable path** (sequential, Erik-gated): T-23 (after T-21) -> T-22 (after M1, M2, M3, T-15, T-18, T-19, T-21, T-23) -> T-24 (A3) -> T-25 (A4) -> T-26 (A5, day 30 and day 120).

Critical path: T-09 -> T-10 -> T-16 -> T-17 -> T-18 -> T-19 -> T-21 -> T-23 -> T-22 -> T-24 -> T-25 -> T-26 (120 days). Spikes: T-02, T-03 (done). Hardware (NAS) tasks: T-23, T-24, T-25, T-26 (not executed by the planner; Erik-approved).

### Tasks

#### T-01 — Walking skeleton: `garage` role scaffold, Quadlet, `site.yml` wiring, role-order check          [~] done, v1.1 trim open
- Type: skeleton
- Requirements: GS-FR-10, GS-FR-13, GS-FR-16, GS-FR-17, GS-FR-18, GS-FR-19, GS-FR-22, GS-FR-60, GS-FR-62 (container part), GS-FR-63, GS-FR-64, GS-FR-67, GS-FR-73, GS-FR-80, GS-FR-81, GS-FR-82, GS-FR-121, GS-FR-122, GS-FR-136 (Quadlet line), GS-FR-138 (static guard), GS-BR-10, GS-E-20, GS-CC-36, GS-CC-38
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G0 (done), trim in G1
- Depends on: none
- Files owned (may modify): `roles/garage/defaults/main.yml`, `roles/garage/meta/main.yml`, `roles/garage/meta/argument_specs.yml`, `roles/garage/tasks/main.yml`, `roles/garage/tasks/{preflight,storage,secrets,deploy}.yml` (stubs only; bodies belong to T-07..T-10), `roles/garage/templates/garage.container.j2`, `roles/garage/README.md` (stub), `site.yml`, `tests/static-checks.sh`, `tests/render.d/40-garage.yml` (until T-10 takes it over), `tests/unit/test_garage_preflight.py`    Must not touch: other roles, `molecule/default/converge.yml`, production `vars.yml`, `CLAUDE.md`, `reqs/**`
- Status: delivered in the working tree (role scaffold, Quadlet with `Environment=GARAGE_CONFIG_FILE=...`, `site.yml` entry after `caddy`, `static-checks.sh` role-order check and the A0 carve-out for `storage.yml`). qa-verifier result not recorded here.
- **Amendment v1.1 (rework open):**
  - Remove the inputs `garage_layout_zone`, `garage_layout_capacity`, `garage_buckets`, `garage_keys` from `defaults/main.yml`, `meta/argument_specs.yml` and the "NOT defaulted on purpose" comment; `garage_s3_domain` is `required: false` with default `''` (GS-CC-38); `garage_rpc_secret`/`garage_admin_token` keep the `vault_garage_*` indirection. No `garage_s3_client_image`.
  - Remove `tasks/bootstrap.yml` and `tasks/lifecycle.yml` and their two `import_tasks` entries in `tasks/main.yml`; the stage order is preflight, storage, secrets, deploy.
  - Add the GS-AC-74 guard to `tests/static-checks.sh`: no file in `roles/garage/tasks/` or `roles/garage/templates/` contains `layout assign`, `layout apply`, `bucket create`, `bucket allow`, `bucket deny`, `bucket website`, `set-quotas`, `key create`, `key import` or a lifecycle API call, and the only `/garage` subcommand in the tasks is `status`.
  - Confirm the render-check asserts of the Quadlet half of GS-AC-38, including `^Environment=GARAGE_CONFIG_FILE=<garage_config_dir>/garage\.toml$`; the generator half (`/usr/libexec/podman/quadlet -dryrun`, GS-CC-36) is added to `40-garage.yml` or, if the generator cannot run in the render-check container, recorded as moved to GS-AC-37 on the VM (T-16).
- Acceptance criteria (verifiable; the amended set):
  - [ ] GS-AC-38 container half: `tests/render-check.sh` renders `40-garage.yml` and `garage.container` matches every Quadlet line (exactly one `Network=`, `User=<fixture uid>`, four `Volume=` lines with `:Z` on the data paths and `ro` on `garage.toml` and `<garage_secrets_dir>`, the `Environment=GARAGE_CONFIG_FILE` line, none of the forbidden lines).
  - [ ] GS-AC-43 (LOCAL half): `garage_enabled: true` and `backup_disk_enabled: false` fails before any change naming both flags (pytest, localhost).
  - [ ] GS-AC-39: `tests/static-checks.sh` role-order check reports `garage` with tag `garage` and `when: garage_enabled | bool`, after `caddy` and before `btrbk`.
  - [ ] GS-AC-42: every `garage_*` variable of the v1.1 Inputs table is declared in `meta/argument_specs.yml`, no removed variable (`garage_buckets`, `garage_keys`, `garage_layout_*`, `garage_s3_client_image`) appears in `roles/garage/` (`grep -rn` prints nothing), and `ansible-lint` passes. `grep -c garage molecule/default/converge.yml` prints 0 (GS-AC-41 first half).
  - [ ] GS-AC-44: the `garage_image` line matches the Renovate custom-manager regex with depName `docker.io/dxflrs/garage` and currentValue `v2.4.1`.
  - [ ] GS-AC-74: the new static guard passes on the trimmed role and fails on a deliberately added `bucket create` line (negative test, not committed). `tests/static-checks.sh` ac04 still fails on a `btrfs subvolume create` added in another role file.
- Verification: `cd nas-de-int-wahlberger-dev && yamllint . && ansible-lint && ansible-playbook site.yml --syntax-check && tests/syntax-check-role.sh garage && tests/render-check.sh && tests/static-checks.sh && pytest tests/unit/test_garage_preflight.py -q`
- Where: LOCAL.  Gate: host    Risk/notes: NAS not touched. `test_garage_preflight.py` is shared with the T-07 rework: T-01 only touches the GS-FR-67 case.

#### T-02 — Spike: Garage v2.4.1 configuration keys, CLI syntax and image tags          [x] done
- Type: spike
- Requirements: GS-A-01, GS-A-02, GS-A-03 (partly), GS-A-09, GS-A-10; evidence for GS-FR-11, GS-FR-84, GS-FR-139, GS-FR-140 (README) and for the former lifecycle/quota assumptions (now Out of Scope, GS-CC-40)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G0
- Depends on: none
- Files owned (may modify): `tests/spikes/garage-v2.4.1-cli-config.md`    Must not touch: all roles and templates
- Status: delivered (`tests/spikes/garage-v2.4.1-cli-config.md`). Still valid under v1.1: the layout/bucket/key/quota/lifecycle findings are the evidence the README steps (T-21) and the test setup (T-13) are written from. The `garage_s3_client_image` tag finding is no longer used. A v1.1 reader check (not a rework): the note's CLI syntax is the single source for T-13 and T-21.
- Acceptance criteria (as planned, met): config keys, CLI syntax and exit codes, key ID/secret formats, `garage status` with "NO ROLE ASSIGNED" before a layout, image user recorded.
- Verification: reviewer reruns two or three recorded commands.
- Where: LOCAL (containers). Gate: host    Risk/notes: none open.

#### T-03 — Spike: Caddy O-6 route fragment against a real Garage          [x] done
- Type: spike
- Requirements: GS-A-04, GS-A-15, GS-A-16, GS-A-23; GS-CC-35 (root_domain required)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G0
- Depends on: none
- Files owned (may modify): `tests/spikes/garage-caddy-routing.md`    Must not touch: `roles/caddy/**`, `roles/garage/**`
- Status: delivered (`tests/spikes/garage-caddy-routing.md`); the spec took its result in 0.8 (O-6 ships unchanged; `[s3_web] root_domain = "<garage_s3_domain>"` is required, which T-10 renders). Still valid under v1.1.
- Acceptance criteria (as planned, met): GS-AC-52 table, GS-AC-30, GS-AC-31, GS-AC-10 literal and percent-encoded key, GS-A-16 (a) to (f).
- Verification: reviewer reruns three table rows.
- Where: LOCAL (docker). Gate: host    Risk/notes: used upstream `caddy:2`; T-17 repeats the key rows with the real image on the VM, with data from the test setup instead of role-managed keys.

#### T-04 — `btrbk` role: per-source `mount_path`, `snapshot_dir` and their guards          [x] done
- Type: slice
- Requirements: GS-FR-75, GS-FR-76, GS-FR-90, GS-FR-91, GS-FR-92, GS-FR-127, GS-BR-04, GS-E-15, GS-E-22, GS-A-17, GS-A-18, GS-CC-20
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G0
- Depends on: none
- Files owned (may modify): `roles/btrbk/templates/btrbk.conf.j2`, `roles/btrbk/tasks/main.yml`, `roles/btrbk/tasks/config.yml`, `roles/btrbk/tasks/validate.yml`, `roles/btrbk/meta/argument_specs.yml`, `roles/btrbk/README.md`, `tests/render.d/23-btrbk-garage.yml`, `tests/unit/test_btrbk_sources.py`    Must not touch: `roles/btrbk/defaults/main.yml` (byte-identical to `master`), `tests/render.d/20-btrbk.yml`, `site.yml`, `reqs/**`
- Status: delivered in the working tree; unaffected by v1.1 (backup of the two Garage subvolumes is unchanged). Merge gate **M1** is Erik's.
- Acceptance criteria (as planned, met at LOCAL level): GS-AC-54 render and `btrbk config print`; GS-AC-53 string-level cases; GS-AC-21 structure; `git diff master -- roles/btrbk/defaults/main.yml` empty; A-17 `btrbk dryrun` ordering. Mount/subvolume behaviour is confirmed on the VM in T-18.
- Verification: `tests/render-check.sh && pytest tests/unit/test_btrbk_sources.py -q && ansible-lint roles/btrbk`
- Where: LOCAL; VM confirmation in T-18. Gate: host    Risk/notes: nothing applied to the NAS.

#### T-05 — Update `reqs/backup-btrbk-and-db-dump.md` for the new btrbk keys (GS-FR-110)          [x] done
- Type: docs
- Requirements: GS-FR-110, GS-FR-117, GS-AC-66, GS-CC-11
- Agent: requirements-engineer    Priority: P0    Size: S    Parallel group: G0
- Depends on: none
- Files owned (may modify): `reqs/backup-btrbk-and-db-dump.md`, the single row of `reqs/index.md` for that file    Must not touch: `reqs/garage-sstate.md`, other index rows
- Status: delivered in the working tree (`reqs/backup-btrbk-and-db-dump.md`, `reqs/index.md` modified); unaffected by v1.1. Merge gate **M3** is Erik's. GS-AC-66 third bullet ("merged before the enable change") is checked in T-22.
- Verification: `git diff -- reqs/backup-btrbk-and-db-dump.md reqs/index.md`; `grep -n 'mount_path\|snapshot_dir' reqs/backup-btrbk-and-db-dump.md`
- Where: LOCAL (inspection). Gate: host    Risk/notes: `reqs/index.md` also carries unrelated uncommitted edits; commit selectively.

#### T-06 — `caddy` role: optional `caddy_sites[].body`, validation          [x] done
- Type: slice
- Requirements: GS-FR-95, GS-FR-96, GS-FR-97, GS-FR-130, GS-E-23, GS-CC-15, GS-CC-25
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G0
- Depends on: none
- Files owned (may modify): `roles/caddy/templates/Caddyfile.j2`, `roles/caddy/tasks/main.yml`, `roles/caddy/meta/argument_specs.yml`, `roles/caddy/README.md`, `tests/render.d/41-caddy-body.yml`, `tests/unit/test_caddy_body.py`    Must not touch: `roles/caddy/defaults/main.yml`, `roles/caddy/files/**`, production `vars.yml`
- Status: delivered in the working tree; unaffected by v1.1 (the S3 host still has the web route and the API route). Merge gate **M2** is Erik's.
- Acceptance criteria (as planned, met at LOCAL level): GS-AC-57 (byte-identical without `body`, `body` block equals `<host> { <body> }`), GS-AC-58 string-level cases, `caddy adapt` exit 0, argument spec optional `body`/`upstream`. The deployed-file behaviour on refusal is confirmed on the VM in T-17.
- Verification: `tests/render-check.sh && pytest tests/unit/test_caddy_body.py -q && ansible-lint roles/caddy`
- Where: LOCAL; VM confirmation in T-17. Gate: host    Risk/notes: nothing applied to the NAS.

#### T-07 — `garage` role: input validation before any change          [~] done, v1.1 trim open
- Type: slice
- Requirements: GS-FR-135, GS-FR-12 (non-empty/format checks), GS-FR-21 (assert exception, GS-CC-39), GS-E-04, GS-FR-67 (shared with T-01)
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G0 (done), trim in G1
- Depends on: T-01
- Files owned (may modify): `roles/garage/tasks/preflight.yml`, `tests/unit/test_garage_preflight.py`    Must not touch: other stage files, `defaults/main.yml`
- Status: delivered (assert-only checks with `quiet: true`, no secret echoed). The working-tree `preflight.yml` still contains the v1.0 checks for `garage_buckets`, `garage_keys`, the `bucket-admin` owner grant, `garage_layout_capacity`/zone.
- **Amendment v1.1 (rework open):** delete the tasks "Validate garage_buckets", "Validate garage_keys", "Require a bucket-admin owner grant ..." and the capacity/zone/expire checks and their pytest cases (GS-FR-125 and GS-E-28 no longer exist). Keep: the backup-disk gate (GS-FR-67), secret formats (RPC secret `^[0-9a-f]{64}$`, admin token >= 32 characters), `garage_s3_domain` empty or outside `.{{ cloudflare_dns_zone }}` (GS-FR-135), `garage_meta_path` not below `garage_meta_mount_path`, and the path checks of the Inputs table.
- Acceptance criteria (verifiable; the amended set):
  - [ ] For each row of GS-AC-25 (`vault_garage_rpc_secret` empty; 63 hex; `vault_garage_admin_token` 31 characters; `garage_s3_domain` `s3.example.org`; `garage_s3_domain` empty; `garage_meta_path` `/mnt/data/garage-meta`), when the preflight runs (pytest, localhost), then it fails naming the input and the message contains no secret value.
  - [ ] The same six rows at `-vvv`: the whole output, including the assert result's `assertion` field, contains no fixture secret value (GS-FR-21 exception, GS-CC-39).
  - [ ] Given a valid fixture input set, the preflight passes with no `changed` task.
  - [ ] `grep -rn 'garage_buckets\|garage_keys\|garage_layout\|bucket-admin\|expire_after_days' roles/garage/tasks tests/unit/test_garage_preflight.py` prints nothing.
- Verification: `pytest tests/unit/test_garage_preflight.py -q && ansible-lint roles/garage`
- Where: LOCAL; the same rows are re-run on the VM in T-16 (GS-AC-25 is marked [V]). Gate: host    Risk/notes: NAS not touched.

#### T-08 — `garage` role: btrfs checks, two subvolumes, ownership, No_COW, service account          [x] done
- Type: slice
- Requirements: GS-FR-01, GS-FR-02, GS-FR-03, GS-FR-04, GS-FR-05, GS-FR-06, GS-FR-09, GS-FR-83, GS-FR-106, GS-FR-107, GS-BR-02, GS-E-01, GS-E-02, GS-E-03, GS-CC-06, GS-CC-17
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G0
- Depends on: T-01 (A0 satisfied)
- Files owned (may modify): `roles/garage/tasks/storage.yml`    Must not touch: `defaults/main.yml`, `tasks/main.yml`, other stage files
- Status: delivered in the working tree (`storage.yml`); unaffected by v1.1. Behaviour is proven by the VM scenarios in T-16; LOCAL lint and static checks pass through the A0 carve-out.
- Acceptance criteria (as planned): GS-AC-01, 02, 03 (data/meta rows), 14 (both rows), 15, 16 (both rows), 17, 18, 19 on the VM (T-16).
- Verification: LOCAL `ansible-lint roles/garage && tests/syntax-check-role.sh garage && tests/static-checks.sh`; VM scenarios in T-16.
- Where: LOCAL for lint/static; VM for the scenarios. Gate: simulator    Risk/notes: authored, not claimed verified until T-16.

#### T-09 — `garage` role: secret files outside every snapshot, run-time guard          [ ] todo
- Type: slice
- Requirements: GS-FR-20, GS-FR-21 (secret files), GS-FR-132, GS-FR-133, GS-FR-134, GS-BR-14, GS-NFR-09, GS-E-32, GS-CC-31, GS-CC-33
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G1
- Depends on: T-01 (done), T-08 (done)
- Files owned (may modify): `roles/garage/tasks/secrets.yml`    Must not touch: other stage files, `defaults/main.yml`
- Context: Security-relevant, so early. Before any change, checks that `garage_secrets_dir` (or its nearest existing parent) is covered by no `btrbk_sources` path and no `snapper list-configs` subvolume by comparing `btrfs inspect-internal rootid` (GS-FR-134). Then creates `garage_secrets_dir` `root:garage 0750` and `rpc_secret`/`admin_token` `garage:garage 0400` with `no_log: true`. v1.1: these two files are the only secret files on the host (GS-FR-133); there is no S3-key or lifecycle credential any more.
- Acceptance criteria (verifiable):
  - [ ] GS-AC-03 row `/var/lib/garage/secrets` `750 root:garage`; GS-AC-22 (`400 garage:garage` on both files, `find /mnt/containers/garage /mnt/data/garage \( -name rpc_secret -o -name admin_token \)` prints nothing, `garage.service` active).
  - [ ] GS-AC-68 both rows (`/mnt/containers/garage/secrets`, `/mnt/data/garage-secrets`): fails before any change naming the path and the covering config/source, path absent afterwards.
  - [ ] GS-AC-67: `findmnt -no FSROOT -T /var/lib/garage/secrets` prints `/@/var`, its root ID differs from every btrbk source and snapper config, and no file named `rpc_secret`/`admin_token` exists in any snapshot dir or `/mnt/backup/btrbk`.
  - [ ] GS-AC-24 second bullet at LOCAL level: no task renders a secret value into a repository file; every secret-bearing task has `no_log: true` (`grep` review).
- Verification: LOCAL `ansible-lint roles/garage && tests/static-checks.sh`; scenarios on the VM in T-16.
- Where: LOCAL for lint/inspection; VM for the scenarios. Gate: simulator    Risk/notes: reviewed by `security-auditor` in T-20. NAS not touched.

#### T-10 — `garage` role: `garage.toml`, container deployment, readiness wait          [ ] todo
- Type: slice
- Requirements: GS-FR-07, GS-FR-08, GS-FR-11, GS-FR-17, GS-FR-23, GS-FR-29, GS-FR-38, GS-FR-62 (full), GS-FR-85, GS-FR-108, GS-FR-109, GS-FR-111, GS-FR-136, GS-FR-138, GS-NFR-05, GS-E-05, GS-E-19, GS-CC-04, GS-CC-05, GS-CC-35, GS-CC-36
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G1
- Depends on: T-01 (done), T-02 (done), T-03 (done)
- Files owned (may modify): `roles/garage/tasks/deploy.yml`, `roles/garage/templates/garage.toml.j2`, `roles/garage/handlers/main.yml`, `tests/render.d/40-garage.yml`    Must not touch: `tasks/main.yml`, other stage files
- Context: v1.1 narrows this to deployment and a liveness check. Renders `garage.toml` (O-1: `replication_factor 1`, `metadata_dir`/`data_dir`, `rpc_bind_addr`/`rpc_public_addr` `127.0.0.1:3901`, `rpc_secret_file`/`admin_token_file` below `garage_secrets_dir`, S3 on `0.0.0.0:3900`, s3_web `0.0.0.0:3902` with `root_domain = "<garage_s3_domain>"` (no leading dot, required by Garage v2.4.1, GS-CC-35), admin `127.0.0.1:3903`; no `[s3_api] root_domain`, no `metadata_snapshots_dir`/`metadata_auto_snapshot_interval`, no `[k2v_api]`, no inline secrets). Deploys the Quadlet via the `container` role, restarts on change and waits for `podman exec garage /garage status` (poll 2 s, `garage_ready_timeout_sec`); this passes without a layout ("NO ROLE ASSIGNED"). It is the role's only Garage CLI call (GS-FR-138). Skipped in check mode when `garage.service` is not running yet (GS-FR-85).
- Acceptance criteria (verifiable):
  - [ ] GS-AC-38 `garage.toml` half: every listed line present (including exactly one `root_domain = "s3.example.test"` under `[s3_web]` and none under `[s3_api]`), none of the forbidden ones; the Quadlet generator half (`/usr/libexec/podman/quadlet -dryrun` then `systemd-analyze verify` of the generated `garage.service`, GS-CC-36) passes in the render-check container or is recorded as moved to GS-AC-37 (LOCAL, `tests/render-check.sh`).
  - [ ] GS-AC-24: neither rendered file contains a fixture secret value; `garage.toml` has `rpc_secret_file` and `admin_token_file` and no line matching `^\s*(rpc_secret|admin_token)\s*=` (LOCAL).
  - [ ] GS-AC-74 (LOCAL): `tests/static-checks.sh` guard passes: the only `/garage` subcommand in `roles/garage/tasks/` is `status`, and `deploy.yml` contains no layout, bucket, key, quota, website or lifecycle command.
  - [ ] GS-AC-11 (ports 3900 to 3903 unreachable from the VM network, `ss` in the host namespace empty, from `caddy.network` 3900/3902 reachable and 3901/3903 not), GS-AC-35 (status within 60 s of restart, proving the config is read from `<garage_config_dir>/garage.toml`, GS-A-29), GS-AC-36, GS-AC-37, GS-AC-46 (check mode: readiness wait skipped), GS-AC-72 (timeout 10 s with an image lacking `/garage`: fails at the readiness wait naming `garage_ready_timeout_sec`, readiness wait is the failed task) (VM, authored here, run in T-16).
- Verification: LOCAL `tests/render-check.sh && ansible-lint roles/garage && tests/syntax-check-role.sh garage && tests/static-checks.sh`.
- Where: LOCAL (render, static); VM for the rest. Gate: simulator    Risk/notes: GS-A-29 (`GARAGE_CONFIG_FILE`), GS-A-24 (SELinux `ro` mount) and GS-A-30 can only be settled on the VM; a failure goes to `requirements-engineer` (amends GS-FR-136 / GS-FR-121 / GS-AC-38). NAS not touched.

#### T-11 — (dropped in v1.1) layout, buckets, quotas, website flag, key import, grants; local Garage harness          [-] dropped
- Reason: GS-CC-40 removes GS-FR-14, 15, 24, 25, 26, 27, 28, 33 and GS-BR-06, GS-BR-07, GS-E-06 to GS-E-10, GS-E-14, GS-AC-06, 08, 09, 26 to 29. The role no longer runs these.
- The local Garage harness (`tests/garage-local/**`) is not needed: the only role task that talks to Garage is `garage status` (T-10, proven on the VM), and the commands of the user steps are rehearsed by the VM test setup (T-13, T-17). If T-13's author wants a quick local rehearsal of the test-setup script against a throwaway Garage container (as spike T-02 did), that is done inside T-13 without a harness directory.
- Files owned: none. Nothing from the earlier plan is carried over; no file named `bootstrap.yml` is to remain (see T-01 amendment).

#### T-12 — (dropped in v1.1) sstate expiry through S3 lifecycle with the `bucket-admin` key          [-] dropped
- Reason: GS-CC-40 removes GS-FR-100 to GS-FR-105, 123 to 125, 131, GS-BR-12, GS-BR-13, GS-NFR-01, GS-NFR-07, GS-NFR-08, GS-E-28 to GS-E-31 and GS-AC-60 to GS-AC-64. Retention is user-owned; the lifecycle commands become README text (T-21, GS-FR-140). `garage_s3_client_image`, the `bucket-admin` key and the lifecycle one-shot container do not exist any more.
- Files owned: none.

#### T-13 — VM fixture inputs for Garage, `vault.yml.example`, and the test-setup step          [ ] todo
- Type: enabling
- Requirements: GS-FR-65, GS-FR-66, GS-FR-68, GS-AC-70 (static part), GS-AC-24 (fixture values)
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-01 (done), T-02 (done; CLI syntax)
- Files owned (may modify): `inventories/vm/group_vars/all/vars.yml`, `inventories/vm/README.md`, `inventories/production/group_vars/all/vault.yml.example`, `tests/vm/scenarios/garage-test-setup.sh`    Must not touch: `inventories/production/group_vars/all/vault.yml`, production `vars.yml`
- Context: Enables every [V] scenario. Fixture: `garage_enabled: true`, `garage_s3_domain: s3.example.test`, fake `vault_garage_rpc_secret` (a fixed 64-hex string listed in `inventories/vm/README.md`) and fake `vault_garage_admin_token` (contains the marker `fixture-garage-not-a-secret`). Nothing else: no buckets, keys, grants, layout capacity (v1.1). `vault.yml.example` lists exactly `vault_garage_rpc_secret` and `vault_garage_admin_token` with a generation command each. The test setup `tests/vm/scenarios/garage-test-setup.sh` is the step that stands in for the user: README layout steps (node ID from `garage status`, `layout assign`, `layout apply --version 1`, verify), buckets `sstate` (website access) and `private-test` (no website access), key `test-rw` with read and write on both, object `selftest/up` and the realistic sstate key K content, using only the Garage CLI and an S3 client (path-style, region `garage`) through `podman exec garage /garage` and a client container on `caddy.network`. It is idempotent enough to re-run after `reset.sh clean`. Its commands are the source the README steps (T-21) are checked against.
- Acceptance criteria (verifiable):
  - [ ] `ansible -i inventories/vm nas -m ansible.builtin.debug -a var=garage_rpc_secret` and `... var=garage_admin_token` show the fixture values; the admin token contains `fixture-garage-not-a-secret` (GS-FR-65).
  - [ ] GS-AC-70 static part: `grep -rn 'bucket\|garage_keys\|grant' inventories/vm/` finds no bucket, key or grant definition, and no role variable defines one.
  - [ ] GS-AC-50 second bullet: `vault.yml.example` lists `vault_garage_rpc_secret` and `vault_garage_admin_token` with a generation command and no other `vault_garage_*` variable.
  - [ ] `shellcheck tests/vm/scenarios/garage-test-setup.sh` (or `bash -n` when shellcheck is absent) passes, and the script contains no `garage_buckets`/role-variable reference (GS-FR-68 "never role variables"). Its execution is part of T-17.
  - [ ] No value of the decrypted production `vault.yml` appears in `inventories/vm/` (`grep -rF` per value, only with the vault password; otherwise mark pending-owner).
- Verification: the `ansible -i inventories/vm ...` commands above; `yamllint .`; `bash -n tests/vm/scenarios/garage-test-setup.sh`.
- Where: LOCAL (authoring); the script runs on the VM in T-16/T-17. Gate: host    Risk/notes: NAS not touched.

#### T-14 — Production `vars.yml`: Garage wiring behind `garage_enabled: false`          [ ] todo
- Type: slice
- Requirements: GS-FR-12 (indirections), GS-FR-32, GS-FR-35, GS-FR-41, GS-FR-45, GS-FR-50, GS-FR-51, GS-FR-61 (default false), GS-FR-70, GS-FR-74, GS-FR-78, GS-FR-79, GS-FR-93, GS-FR-94, GS-FR-112, GS-FR-113, GS-FR-114, GS-FR-126, GS-FR-127, GS-FR-128, GS-FR-129, GS-NFR-03, GS-CC-30
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G1
- Depends on: T-01 (done), T-03 (done), T-04 (done), T-06 (done)
- Files owned (may modify): `inventories/production/group_vars/all/vars.yml`, `tests/render.d/42-garage-production.yml`, `tests/unit/test_garage_production_vars.py`    Must not touch: `vault.yml`, role defaults, `roles/btrbk/defaults/main.yml`, firewall variables
- Context: Adds `garage_enabled: false`, `garage_s3_domain: s3.de.int.wahlberger.dev`, the two `garage_rpc_secret`/`garage_admin_token` indirections `{{ vault_garage_* | default('') }}`, and the three conditional compositions: `btrbk_sources` (restated `data`, `containers` equal to the role defaults, then `garage-meta` then `garage` when `garage_enabled | bool`), `backup_disk_freshness_checks` (four existing + two Garage entries of 26 h), `caddy_sites` (existing entries + the O-6 entry with `body`). v1.1: **no** `garage_buckets`, `garage_keys`, `garage_layout_capacity` or `garage_layout_zone` in production vars. Stays `false`: nothing changes on the NAS until T-22/T-24.
- Acceptance criteria (verifiable):
  - [ ] GS-AC-59 both rows evaluated with `ansible localhost -e @vars.yml` for `garage_enabled` true and false: true gives `garage-meta` before `garage` with the GS-FR-78 / GS-FR-70 keys, both freshness entries, one S3-host `caddy_sites` entry; false gives none of them and the remaining entries equal `master`; `data`/`containers` equal `roles/btrbk/defaults/main.yml`, which is byte-identical to `master` (GS-FR-127).
  - [ ] GS-AC-48: rendering `Caddyfile.j2` with production `caddy_sites` and `garage_enabled: true` yields exactly one site `s3.de.int.wahlberger.dev`, none ending in `.s3.de.int.wahlberger.dev`, a block equal to O-6 (whitespace aside) and no `request_body`; GS-AC-57 second bullet (other blocks byte-identical to `master`).
  - [ ] GS-AC-54 with the production list: `btrbk config print` passes (same asserts as T-04).
  - [ ] GS-AC-49: `firewall_allowed_services`, `firewall_allowed_ports`, `firewall_rich_rules` byte-identical to `master`; GS-AC-45 first bullet (S); `disk_space_paths` still lists `/mnt/data`, `/mnt/containers`, `/mnt/backup/btrbk` with threshold 85 (GS-NFR-03).
  - [ ] `grep -n 'garage_buckets\|garage_keys\|garage_layout' inventories/production/group_vars/all/vars.yml` prints nothing.
  - [ ] With `garage_enabled: false`, `ansible-playbook site.yml --syntax-check` passes; every `community.general.cloudflare_dns` task in the repo has `proxied: false` (GS-FR-45) and no DNS record contains a bucket name (GS-FR-114, inspection).
- Verification: `pytest tests/unit/test_garage_production_vars.py -q && tests/render-check.sh && ansible-playbook site.yml --syntax-check && git diff master -- roles/btrbk/defaults/main.yml`
- Where: LOCAL. Gate: host    Risk/notes: production file but `garage_enabled: false`; nothing is applied. Do not run `ansible-playbook` against the NAS.

#### T-15 — Add the two `vault_garage_*` values to the encrypted production vault          [ ] todo
- Type: enabling
- Requirements: GS-P-03, GS-FR-12, GS-AC-69 (vault bullet), GS-E-04 (formats)
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-13 (names, example)
- Files owned (may modify): `inventories/production/group_vars/all/vault.yml`    Must not touch: everything else
- Context: Needs **A1**: Erik unlocks 1Password so `.vault_pass.sh` works. Generates `vault_garage_rpc_secret` (`openssl rand -hex 32`) and `vault_garage_admin_token` (`openssl rand -base64 32`) and writes them with `ansible-vault` into the existing `vault.yml` (no new 1Password item). S3 keys are user-owned and are not in Vault (GS-P-03). Values never printed, never in the transcript.
- Acceptance criteria (verifiable):
  - [ ] Both variables are defined and non-empty, checked without printing values (`ansible localhost -e @vault.yml -m ansible.builtin.assert -a "that=<var> | length > 0"` per variable, output shows only pass/fail); no other `vault_garage_*` variable is added.
  - [ ] Formats hold: RPC secret `^[0-9a-f]{64}$`, admin token >= 32 characters (assert, no values printed).
  - [ ] `git diff --stat` shows only an encrypted-blob change in `vault.yml`, which still starts with `$ANSIBLE_VAULT`; no plaintext secret anywhere in the working tree.
- Verification: the assert commands above; `head -c 20 vault.yml`.
- Where: LOCAL (Vault file only, no NAS). Gate: host    Risk/notes: **A1**.

#### T-16 — VM run V1: storage, secrets, service, ports, restarts, no-layout state          [~] 2026-10-18: 33 PASS, 2 FAIL (GS-AC-36 spec GS-FR-16 exec form; GS-AC-46 container role handler in check mode), GS-AC-05 skipped; see tests/vm/results/garage-v1.md
- Type: slice
- Requirements: GS-FR-01..06, 09, 83, 106, 107, 132, 134, 20, 13, 16, 17, 22, 29, 80..82, 108, 109, 111, 60, 61, 67, 85, 135, 136; GS-BR-02, GS-BR-14, GS-BR-16; GS-NFR-05, GS-NFR-09; GS-E-01, E-02, E-05, E-19, E-20, E-21, E-32, E-33
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: VM sequence (1)
- Depends on: T-08 (done), T-09, T-10, T-13 (and T-07 trim for GS-AC-25)
- Files owned (may modify): `tests/vm/scenarios/garage-v1-*.sh`, `tests/vm/results/garage-v1.md`    Must not touch: roles, other tests/vm files
- Context: Authors and runs the scenarios on the qemu fixture (`tests/vm/up.sh`, `snapshot.sh clean`, `reset.sh clean` between destructive cases). The VM is the only target; never the NAS. GS-AC-75 runs first on a fresh store; scenarios that need data (GS-AC-15) run the test setup (T-13) afterwards.
- Acceptance criteria (verifiable): each scenario passes as written in the spec: GS-AC-01, 02, 03, 05 (VM half: `smbclient`/`testparm` unchanged, no share named `garage`), 11, 14 (both rows), 15, 16 (both rows), 17, 18, 19, 22, 25 (all six rows, VM re-run, incl. `-vvv` no fixture secret), 35 (config read from the declared path), 36, 37, 40 (flag false is a no-op), 43, 46, 67, 68 (both rows), 71 (restart after `podman kill`), 72, and **GS-AC-75** (fresh store after the role run: the run succeeded, `podman exec garage /garage status` exits 0 and lists the node with "NO ROLE ASSIGNED", and a signed `PUT` through `http://garage:3900` returns non-2xx before any layout step).
- Verification: `tests/vm/scenarios/garage-v1-*.sh` exits 0 and `tests/vm/results/garage-v1.md` shows all PASS.
- Where: VM. Gate: simulator    Risk/notes: failures go back to the owning task, not patched here. GS-A-29/30 outcomes are recorded.

#### T-17 — VM run V2: test setup, README steps, routing, user-state untouched          [~] 2026-10-18: all scenarios PASS on the VM (GS-AC-70, 07, 10, 30, 31, 52, 58, 73; GS-AC-10 [H] not run), see tests/vm/results/garage-v2.md
- Type: slice
- Requirements: GS-FR-30, 31, 36, 37, 93, 94, 95, 97, 137, 138, 139, 68, 21; GS-BR-09, BR-15; GS-E-13, E-23, E-24, E-25; GS-A-15, A-16, A-23
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: VM sequence (2)
- Depends on: T-16, T-13, T-14, T-06 (done)
- Files owned (may modify): `tests/vm/scenarios/garage-v2-*.sh`, `tests/vm/results/garage-v2.md`    Must not touch: roles
- Context: Runs the test setup (`garage-test-setup.sh`, the stand-in for the user) first, then starts the route test Caddy (`caddy-route-test`, `caddy_image`, Caddyfile `http://:8080 { <body of the S3 host site rendered from production vars> }`) on `caddy.network`; Caddy has no real certificate on the VM. Any change the test setup needs (a README command that does not work as written) is reported to T-13/T-21, not patched here.
- Acceptance criteria (verifiable): GS-AC-70 (VM: `garage bucket list` shows `sstate` and `private-test`, `garage bucket info sstate` shows website access, `garage key info test-rw` shows read+write on both; no file in `inventories/vm/` and no role variable defines a bucket, key or grant); GS-AC-07 (after the README layout steps `garage status` shows a role, `selftest/up` 1 MiB put 200, signed HEAD same size, signed GET same sha256); GS-AC-10 (VM bullets incl. K with literal and percent-encoded `:`/`+`); GS-AC-30; GS-AC-31; GS-AC-52 (all 11 rows with `test-rw`); GS-AC-58 (all 3 rows on the real role, deployed `Caddyfile` unchanged on refusal); **GS-AC-73** (after the user also sets a 10 MiB quota on `private-test` and a lifecycle rule on `sstate`, `ansible-playbook -i inventories/vm site.yml --tags garage` shows `changed=0`, the four saved outputs `layout show`, `bucket info sstate`, `bucket info private-test`, `key info test-rw` are identical and `GetBucketLifecycleConfiguration` still returns the user's rule).
- Verification: `tests/vm/scenarios/garage-v2-*.sh` exits 0; results file all PASS.
- Where: VM. Gate: simulator    Risk/notes: any deviation from the T-03 LOCAL result goes to `requirements-engineer`. The saved user-state of GS-AC-73 is reused by T-18/T-19 (do not reset in between).

#### T-18 — VM run V3: btrbk Garage sources, backup, restore drill, skew          [~] 2026-10-18: all scenarios PASS on the VM (GS-AC-04, 20, 21, 45 [V], 53, 55, 56, 67, 68), see tests/vm/results/garage-v3.md; restore needs btrfs send/receive (T-21), GS-AC-67 root-ID wording (spec)
- Type: slice
- Requirements: GS-FR-70..72, 75, 76, 77, 78, 79, 90, 91, 92, 74; GS-BR-03, BR-11; GS-NFR-06; GS-E-15, E-22, E-26, E-27; GS-A-17, A-19, A-24, A-25, A-27; GS-R-01, GS-R-03
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: VM sequence (3)
- Depends on: T-17, T-04 (done), T-14
- Files owned (may modify): `tests/vm/scenarios/garage-v3-*.sh`, `tests/vm/results/garage-v3.md`    Must not touch: roles
- Context: One-time drills that gate enabling (GS-FR-118): GS-AC-55 with the metadata snapshot taken under continuous upload load (live LMDB, GS-R-03) and GS-AC-56. The store holds the objects created by the test setup. The restore steps are those of the role README (T-21 text drafted from this drill); any missing repair step is reported to `docs-writer` (T-21) and, if a repair command is needed, to `requirements-engineer` (GS-R-03).
- Acceptance criteria (verifiable): GS-AC-04, 20, 21 (both rows), 45 (V bullet: `backup-disk-health.service` exit 0), 53 (all four values, `btrbk.conf` unchanged), 55 (secrets re-rendered with `--tags garage`, status within 60 s, `selftest/up` sha S, `block list-errors` clean), 56 (A reads back, B returns 404); the measured `<ts>` pairing confirms GS-A-17.
- Verification: `tests/vm/scenarios/garage-v3-*.sh` exits 0; results file all PASS and quoted into the enable PR (T-22).
- Where: VM. Gate: simulator    Risk/notes: GS-AC-55 and GS-AC-56 are enable preconditions (GS-FR-118).

#### T-19 — VM run V4: secrets out of logs, idempotency (lifecycle part dropped)          [x] 2026-10-19: GS-AC-23 (fresh store and user-made state, -vvv, output and garage.service journal clean) and GS-AC-12 (changed=0, --check --diff empty) PASS on the VM, see tests/vm/results/garage-v4.md
- Type: slice
- Requirements: GS-FR-21, GS-FR-61, GS-FR-138 (re-run on user-made state), GS-AC-12, GS-AC-23
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: VM sequence (4)
- Depends on: T-18
- Files owned (may modify): `tests/vm/scenarios/garage-v4-*.sh`, `tests/vm/results/garage-v4.md`    Must not touch: roles
- Context: v1.1 removes GS-AC-60 to GS-AC-64 (lifecycle, expiration demonstration, `bucket-admin`), so there is no 48 h wait and no `GS-FR-119` precondition. What remains is the whole-run proof.
- Acceptance criteria (verifiable): GS-AC-23 (`ansible-playbook -i inventories/vm site.yml --tags garage -vvv`, on a fresh store and again on a store with user-made buckets and keys: no fixture secret value in the Ansible output or in `journalctl -u garage.service`); GS-AC-12 (second `--tags garage,caddy,btrbk` run `changed=0`, then `--check --diff` shows no diff).
- Verification: `tests/vm/scenarios/garage-v4-*.sh` exits 0; results file all PASS.
- Where: VM. Gate: simulator    Risk/notes: none beyond T-16..T-18 prerequisites.

#### T-20 — Security review of the Garage feature          [ ] todo
- Type: security
- Requirements: GS-FR-12, GS-FR-13, GS-FR-20, GS-FR-21 (incl. the assert exception, GS-CC-39), GS-FR-132, GS-FR-133, GS-FR-134, GS-FR-138, GS-BR-05, GS-BR-09, GS-BR-14, GS-BR-15, GS-NFR-09, GS-A-08
- Agent: security-auditor    Priority: P1    Size: S    Parallel group: G2
- Depends on: T-09, T-10, T-14 (T-06 done)
- Files owned (may modify): none (read-only review; findings are returned to the orchestrator)    Must not touch: all files
- Context: Audits secret handling (no_log, the assert-only exception with `quiet: true` and untemplated conditions, file modes, `garage_secrets_dir` outside snapshots), the exposure model (nothing published, anonymous reads only on buckets the user enables, the S3 API reachable only through the Caddy API route and from `caddy.network`), the Caddy fragment (unsigned PUT/POST/DELETE), the public hostname (GS-BR-05) and the one pinned image. v1.1 removed the key-import command line and the lifecycle credentials; the review confirms nothing of that remains and that the README steps do not tell the user to put key secrets in files or process lists carelessly (T-21 reviewed once it exists, if the auditor is re-run).
- Acceptance criteria (verifiable):
  - [ ] A written finding list exists with severity per item; each blocking finding becomes a fix task for `ansible-doctor` before T-22.
  - [ ] Confirms or refutes: no secret in repository files, task output or `journalctl`; no Garage port published; the role runs no state-changing Garage command (GS-AC-74).
- Verification: reviewer checks the finding list against `grep -rn 'no_log' roles/garage` and the VM results of T-16, T-17, T-19.
- Where: LOCAL (inspection of repo and VM results). Gate: host    Risk/notes: NAS not touched.

#### T-21 — Documentation: role README (layout, user steps, restore), CLAUDE.md, repo README          [ ] todo
- Type: docs
- Requirements: GS-FR-34, GS-FR-77, GS-FR-84, GS-FR-139, GS-FR-140, GS-FR-63 (CLAUDE.md note), GS-AC-41, GS-AC-50, O-9
- Agent: docs-writer    Priority: P1    Size: M    Parallel group: G2
- Depends on: T-19, T-20, T-13, T-02
- Files owned (may modify): `roles/garage/README.md`, `CLAUDE.md` (stack table row for `garage`, molecule exclusion note names `garage`), `README.md` (a short Garage/consumer section if the file lists services), `roles/btrbk/README.md` and `roles/caddy/README.md` only for cross-links    Must not touch: roles' code, `reqs/**`
- Context: The README is the user's manual after v1.1. Contents: (1) S3 settings for consumers (endpoint `https://s3.de.int.wahlberger.dev`, path-style, region `garage`) and the mirror line `SSTATE_MIRRORS ?= "file://.* https://s3.de.int.wahlberger.dev/<bucket>/PATH"` with `sstate` as the example (GS-FR-34); (2) the one-node layout steps: read the node ID from `garage status`, `garage layout assign -z <zone> -c <capacity> <node_id>`, `garage layout apply --version 1`, verify with `garage status`, capacity is a placement weight, `500GB` differs from `500GiB` (GS-FR-139); (3) the user steps for bucket, key, grant read/write, website access, quota (recommendation `sstate` 500 GiB, within the GS-NFR-02 budget) and lifecycle rule, with the limits recorded in GS-F-21 and the two spike notes (GS-FR-140); (4) restore (stop `garage.service`; restore `data/` and the metadata subvolume from the same `<ts>`; re-render the secrets from Vault with `ansible-playbook site.yml --tags garage`; start; `garage status` and `garage block list-errors`), exactly as run in T-18; (5) the recorded image user (GS-FR-84); (6) the consequence that a fresh store has no layout until step 2 (GS-BR-16); (7) empty fields for the day-30 and day-120 backup-disk values (filled by T-26). The commands in (2) and (3) are checked against `tests/vm/scenarios/garage-test-setup.sh`.
- Acceptance criteria (verifiable):
  - [ ] GS-AC-50: `roles/garage/README.md` contains the S3 settings and the `SSTATE_MIRRORS` line with `<bucket>`, the layout steps (`garage status`, `layout assign`, `layout apply`, verify), the user steps of GS-FR-140, the restore steps including "same `<ts>`" and "re-render the secrets from Vault", and the recorded image user; `vault.yml.example` lists only the two `vault_garage_*` variables (T-13).
  - [ ] GS-AC-41: `molecule/default/converge.yml` has no `garage`; the molecule exclusion note in `CLAUDE.md` names `garage`.
  - [ ] Every `garage ...` and S3 command in README sections (2) and (3) also appears in `tests/vm/scenarios/garage-test-setup.sh` (or is marked "not run in the test setup" with a reason), and every restore command equals the one run in T-18.
- Verification: `grep -n 'SSTATE_MIRRORS\|layout assign\|layout apply\|same .<ts>\|re-render' roles/garage/README.md && grep -n garage CLAUDE.md molecule/default/converge.yml && yamllint .`
- Where: LOCAL. Gate: host    Risk/notes: NAS not touched.

#### T-22 — Prepare the enable change (`garage_enabled: true`) with the checklist          [ ] todo
- Type: enabling
- Requirements: GS-FR-61, GS-FR-115, GS-FR-116, GS-FR-117, GS-FR-118, GS-FR-120, GS-AC-66, GS-AC-69
- Agent: git-release-manager    Priority: P1    Size: S    Parallel group: -
- Depends on: M1 (T-04), M2 (T-06), M3 (T-05) merged; T-15, T-18, T-19, T-20, T-21, T-23
- Files owned (may modify): `inventories/production/group_vars/all/vars.yml` (only `garage_enabled: true`)    Must not touch: everything else
- Context: One small change, prepared as a PR (not merged, not applied). v1.1: there is no `garage_layout_capacity` to set and no expiration demonstration (GS-FR-119 is deleted). The PR description links the merged btrbk change, the merged caddy change and the GS-AC-66 update, records the pass results of GS-AC-55 and GS-AC-56 (T-18) and the GS-AC-47 values (T-23).
- Acceptance criteria (verifiable):
  - [ ] GS-AC-69: the PR description contains the three merged-change links, the GS-AC-55 and GS-AC-56 results and the GS-AC-47 values; no GS-AC-61 or capacity-variable item is on the checklist; the production `vault.yml` defines `vault_garage_rpc_secret` and `vault_garage_admin_token` non-empty (the T-15 check still passes).
  - [ ] `git diff` of the PR touches only the `garage_enabled` line in `vars.yml`; the three compositions evaluate with Garage entries (T-14 pytest passes with `garage_enabled: true`).
  - [ ] GS-AC-66: `git log` shows the T-05 update merged before this change.
- Verification: `git diff --stat`; `pytest tests/unit/test_garage_production_vars.py -q`.
- Where: LOCAL. Gate: host    Risk/notes: Erik reviews and merges; commit/push/merge only on Erik's request. Do not run any playbook.

#### T-23 — Capacity analysis (GS-AC-47) from the README quota recommendation          [ ] todo
- Type: hardware-validation
- Requirements: GS-NFR-02, GS-FR-120, GS-AC-47
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: -
- Depends on: T-21 (the README quota recommendation, GS-FR-140), T-14
- Files owned (may modify): none (values are recorded in the T-22 PR description)    Must not touch: all files
- Context: Needs **A2**. Erik runs (or approves the agent running, read-only) `ssh nas.de.int.wahlberger.dev 'df -B1 --output=size,used /mnt/data'`. v1.1: Q is the total of the bucket quotas the README recommends (500 GiB for `sstate`), not the sum of role-managed quotas; the user sets the quota, so the check is a budget analysis before enabling.
- Acceptance criteria (verifiable):
  - [ ] The recorded S, U and Q (Q read from the README recommendation) satisfy U + Q <= 0.85 x S (GS-AC-47); the arithmetic is shown.
  - [ ] If it fails, the task stops and reports to Erik; it changes no quota and no README text itself.
- Verification: recorded values and the arithmetic in the PR description.
- Where: NAS (read-only). Gate: hardware    Risk/notes: **A2** required; not executed by the planner.

#### T-24 — Production apply (`--check --diff`, then apply)          [ ] todo
- Type: hardware-validation
- Requirements: enabled-state requirements on the NAS: GS-FR-01..09, 20, 29, 32, 35, 70, 74, 78, 79, GS-BR-10, GS-BR-16
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: -
- Depends on: T-22 (merged by Erik), A3
- Files owned (may modify): none    Must not touch: all files
- Context: Needs **A3**. Command order: `ansible-playbook site.yml --check --diff --tags cloudflare_dns,caddy,garage,btrbk,backup_disk` (in check mode only the readiness wait is skipped, GS-FR-85; the Quadlet, config and subvolume creations are previewed), review with Erik, then the same command without `--check`. The Cloudflare token and vault password come from 1Password via `.vault_pass.sh`. After the apply Garage runs with "NO ROLE ASSIGNED" (GS-BR-16): that is the expected end state of this task, not a failure. There is no teardown in the spec; if something fails, Erik decides.
- Acceptance criteria (verifiable):
  - [ ] The check run exits 0 and its diff shows only the Garage Quadlet/config/subvolume creations and secret files, the S3-host Caddy block, the CNAME `s3.de.int.wahlberger.dev` and the Garage btrbk sources / freshness checks, and no change to other sites.
  - [ ] The apply exits 0; a second apply with the same tags reports `changed=0`; `systemctl is-active garage.service` prints `active` and `podman exec garage /garage status` exits 0 within 60 s.
  - [ ] `systemctl show btrbk.service -p Result -p ExecMainStatus` still reports success after the next scheduled run.
- Verification: recorded recap lines and the commands above, pasted to Erik.
- Where: NAS. Gate: hardware    Risk/notes: **A3**. Changes the live NAS (Caddy reload affects all sites briefly; btrbk config changes). Not executed by the planner.

#### T-25 — Production setup by Erik (README steps), then validation          [ ] todo
- Type: hardware-validation
- Requirements: GS-FR-30, 31, 35, 44, 45, 50, 51, 137, 139, 140; GS-BR-05; GS-E-12; GS-AC-05, 10 (H bullet), 20 (first real run), 32, 33, 34, 45
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: -
- Depends on: T-24, A4
- Files owned (may modify): none    Must not touch: all files
- Context: Needs **A4**. v1.1 order: first **Erik runs the README steps himself** on the NAS (layout, the `sstate` bucket, a key with write access, website access, the quota and the retention rule he wants; his choices, recorded by him, never by Ansible). Only then the [H] smoke checks below run, signed with the key Erik created (the agent never holds that key; Erik runs the signed commands or approves each). Includes stopping `garage.service` for GS-AC-34 and a 1 GiB test upload that is deleted afterwards. GS-AC-45 and the first real btrbk pair are checked after the next scheduled btrbk run (next day).
- Acceptance criteria (verifiable):
  - [ ] Before the README steps: `podman exec garage /garage status` lists the node with "NO ROLE ASSIGNED"; after them it shows a role (GS-FR-139, GS-FR-137 on the NAS).
  - [ ] GS-AC-05 (smbclient share list unchanged, no share named `garage`, no `path =` at or below the Garage paths); GS-AC-10 [H] bullet (`curl .../sstate/<K>` prints 200 from a LAN host after K is uploaded); GS-AC-32 (1 GiB PUT 200, signed DELETE 204, key created by Erik).
  - [ ] GS-AC-33 (`dig +short s3.de.int.wahlberger.dev @1.1.1.1` -> `nas.de.int.wahlberger.dev.` then `10.10.0.100`; `sstate.s3...` prints nothing; certificate SAN only `DNS:s3.de.int.wahlberger.dev`; every cloudflare_dns task `proxied: false`).
  - [ ] GS-AC-34 (service stopped: 502; after start: 200 within 60 s); GS-AC-20/45 on the NAS after the next btrbk run: both snapshot pairs share one `<ts>`, both replicas exist, `backup-disk-health.service` exit 0.
- Verification: command outputs recorded and shown to Erik.
- Where: NAS. Gate: hardware    Risk/notes: **A4**. GS-P-01 (ZeroTier rule) is not needed for the LAN checks. If a README command does not work on the NAS, the fix is a README change in T-21's file, raised to `docs-writer`.

#### T-26 — Day-30 and day-120 backup-disk measurements          [ ] todo
- Type: hardware-validation
- Requirements: GS-NFR-04, GS-AC-51, GS-AC-65
- Agent: ansible-doctor    Priority: P2    Size: S    Parallel group: -
- Depends on: T-25, A5 (checkpoints 30 and 120 days after enabling)
- Files owned (may modify): `roles/garage/README.md` (the two measured values only)    Must not touch: everything else
- Context: Needs **A5**; read-only commands on the NAS at both dates. v1.1: the day-120 re-measure no longer follows a "90-day expiry cycle"; it is taken 120 days after enabling, when deleted objects exist only in older backup snapshots (GS-AC-65). There are no `garage bucket info` size or lifecycle checks any more (GS-AC-64 is deleted).
- Acceptance criteria (verifiable):
  - [ ] Day 30: `btrfs filesystem du -s /mnt/backup/btrbk/garage /mnt/backup/btrbk/garage-meta` sum of Exclusive + Set shared <= 1 TiB (GS-AC-51).
  - [ ] Day 120: the same sum <= 1 TiB and the value recorded in `roles/garage/README.md` next to the day-30 value (GS-AC-65). After day 120 no further re-measure is required (GS-NFR-04).
- Verification: recorded command outputs; `git diff roles/garage/README.md`.
- Where: NAS (read-only). Gate: hardware    Risk/notes: **A5**. Calendar items, not executed by the planner.

### Traceability
Re-derived from spec v1.1. "[Deleted 1.1]" IDs (GS-FR-14, 15, 24 to 28, 33, 100 to 105, 119, 123 to 125, 131; GS-BR-06, 07, 12, 13; GS-NFR-01, 07, 08; GS-E-06 to E-10, E-14, E-28 to E-31; GS-AC-06, 08, 09, 26 to 29, 60 to 64; GS-A-20 to A-22, A-28) have no task by design (spec Verification table: "none (out of scope, GS-CC-40)").

| Requirement | Tasks | Verified by (test/procedure) |
|---|---|---|
| GS-FR-01, 02, 03, 04, 05, 06, 09, 83, 106, 107, GS-BR-02, GS-E-01, E-02, E-03 | T-08 (done), T-16 | GS-AC-01, 02, 03, 14, 15, 16, 17, 18, 19 (VM) |
| GS-FR-07, 08, 11, 23, 38, 62, 108, 109, 111, GS-CC-04, CC-05, CC-35 | T-10, T-01 | GS-AC-38, 24, 13 (LOCAL render-check) |
| GS-FR-136 | T-01 (Quadlet line), T-10 | GS-AC-38 (LOCAL), GS-AC-35 (VM) |
| GS-FR-10, 18 | T-01 | GS-AC-44 (LOCAL regex check) |
| GS-FR-12 | T-07, T-14, T-15 | GS-AC-25, 69 |
| GS-FR-13, 16, 17, 19, 22, 73, 80, 81, 82, 121, 122 | T-01, T-10 | GS-AC-38 (LOCAL), 36, 37, 71 (VM) |
| GS-FR-20, 21, 132, 133, 134, GS-BR-14, GS-NFR-09, GS-E-32 | T-09, T-07 (assert exception), T-19, T-20 | GS-AC-22, 23, 25, 67, 68 (VM), security review |
| GS-FR-29, 85, GS-NFR-05, GS-E-05, E-19, E-21 | T-10, T-16 | GS-AC-35, 46, 72, 37 (VM) |
| GS-FR-135, GS-E-04 | T-07, T-16 | GS-AC-25 (LOCAL, VM) |
| GS-FR-137, 139, 140, GS-BR-16, GS-E-33 | T-13, T-17, T-21, T-16, T-25 | GS-AC-07, 75 (VM), README diff vs test setup (GS-AC-50), NAS check in T-25 |
| GS-FR-138, GS-BR-15 | T-01 (static guard), T-10, T-17 | GS-AC-74 (LOCAL), GS-AC-73 (VM) |
| GS-FR-30, 31, 93, 94, GS-BR-09, GS-E-24, E-25 | T-03 (done), T-14, T-17 | GS-AC-10, 52, 48 (LOCAL spike, VM) |
| GS-FR-36, 37, GS-E-13 | T-17 | GS-AC-30, 31, 52 (VM) |
| GS-FR-32, 112, 113, 129, 35, 114, 45, 41, 44, 50, 51, GS-BR-05 | T-14, T-25 | GS-AC-48, 49, 59 (LOCAL); GS-AC-05, 32, 33 (NAS) |
| GS-FR-34, 77, 84, 63 (note) | T-21, T-18 | GS-AC-50, 41, 55 |
| GS-FR-60, 67, GS-BR-10, GS-E-20 | T-01 | GS-AC-39, 43 |
| GS-FR-61, 115, 116, 117, 118, 120 | T-22 (gate), T-05, T-04, T-06, T-18, T-23 | GS-AC-66, 69 |
| GS-FR-64 | T-01 | GS-AC-42 |
| GS-FR-65, 66, 68 | T-13, T-17 | GS-AC-70, 50, 24 |
| GS-FR-70, 78, 79, 126, 127, 128, 74, GS-NFR-06 | T-14, T-04, T-18 | GS-AC-59, 54, 45 |
| GS-FR-71, 72, GS-BR-03, BR-11 | T-04, T-18 | GS-AC-20, 04, 55 |
| GS-FR-75, 76, 90, 91, 92, GS-BR-04, GS-E-15, E-22 | T-04, T-18 | GS-AC-54, 21, 53 |
| GS-FR-95, 96, 97, 130, GS-E-23 | T-06, T-17 | GS-AC-57, 58 |
| GS-FR-110, 117 | T-05 | GS-AC-66 |
| GS-NFR-02 | T-23 | GS-AC-47 |
| GS-NFR-03 | T-14 | inspection of `disk_space_paths` |
| GS-NFR-04 | T-26 | GS-AC-51, 65 |
| GS-BR-08 | external (GS-P-01, Erik) | `zerotier-flow-rules.md` record |
| GS-E-12 | T-25 | GS-AC-34 |
| GS-E-11, E-16 to E-18, E-26, E-27 | existing roles / not tested (E-11, E-16 to E-18); T-18 (E-26, E-27) | GS-AC-56 for E-26; E-27 by the README requirement of the same `<ts>` |
| GS-P-03 | T-15, T-13 | GS-AC-69, 50 |

Scenario coverage (all 63 non-deleted scenarios of v1.1 (AC-01 to AC-75 minus the 12 deleted) mapped): GS-AC-01, 02, 03, 05 (VM), 11, 14, 15, 16, 17, 18, 19, 22, 25 (VM), 35, 36, 37, 40, 43, 46, 67, 68, 71, 72, 75 -> T-16; GS-AC-07, 10, 30, 31, 52, 58, 70, 73 -> T-17; GS-AC-04, 20, 21, 45 (VM), 53, 55, 56 -> T-18; GS-AC-12, 23 -> T-19; GS-AC-13, 39, 42, 43 (LOCAL), 44, 74 (guard), 38 (container half) -> T-01; GS-AC-38 (toml and generator half), 24, 74 -> T-10; GS-AC-25 (LOCAL) -> T-07; GS-AC-41, 50 -> T-21; GS-AC-47 -> T-23; GS-AC-48, 49, 54 (production list), 57, 59, 45 (S) -> T-14; GS-AC-54 -> T-04; GS-AC-57, 58 (LOCAL) -> T-06; GS-AC-66 -> T-05, T-22; GS-AC-69 -> T-22; GS-AC-70 (static) -> T-13; GS-AC-05 (NAS), 10 (H), 20/45 (NAS), 32, 33, 34 -> T-25; GS-AC-51, 65 -> T-26.

Not mappable in v1.1: none. Two spec items are verification-only dependencies rather than tasks: GS-A-29 (`GARAGE_CONFIG_FILE`) and GS-A-30 (Quadlet generator in the render-check container) are settled by T-16 / T-01 and, on failure, go to `requirements-engineer`.

### Task status log   (orchestrator updates checkboxes; never delete history)
- 2026-10-18: plan created (26 tasks). No task started. Nothing executed against the NAS.
- 2026-10-18 (re-plan for spec v1.1, GS-CC-40, coordinator message): T-02, T-03, T-04, T-05, T-06, T-08 reported done in the working tree and still valid -> `[x] done`. T-01 and T-07 are done but need the v1.1 trim -> `[~] done, v1.1 trim open` (T-01: remove bootstrap/lifecycle stage files, removed inputs, add the GS-AC-74 guard; T-07: drop bucket, key, capacity and expiry validation). T-11 and T-12 dropped (`[-]`). T-13, T-14, T-15, T-16, T-17, T-19, T-20, T-21, T-22, T-23, T-25, T-26 rewritten for v1.1; T-09, T-10, T-18, T-24 adjusted. Approval gates A0 to A5 and M1 to M3 unchanged. Total: 26 ids, 24 live (6 done, 2 done-with-trim, 16 open). No qa-verifier result recorded in this log for the done tasks; the orchestrator should record it.
