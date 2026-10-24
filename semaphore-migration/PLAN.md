## Plan: Move Semaphore from the Pi to a Hetzner VM (UI over ZeroTier only, key-only public SSH) and retire the Pi          spec: semaphore-migration/reqs/semaphore-to-hetzner.md (v1.2)   planned: 2026-10-10   status: in progress (PRs A–D merged to master, 2026-10-11 to 2026-10-17; PR E and Pi retirement open)

Branch: `feature/semaphore-to-hetzner`. IDs: `T-nn` agent tasks (repo, offline-verifiable), `OP-nn` operator checklist items (Erik only, live systems). Spec IDs carry the prefix `SH-`; in this file `FR-nn`, `AC-nn`, `BR-nn`, `CC-nn`, `DOC-nn`, `NFR-nn`, `D-nn`, `A-nn`, `E-nn` all mean `SH-...`.

### Reality check (2026-10-19, verified against `master` and live DNS)

Checked against the repository on `master` (not against this document's checkboxes, which lagged behind) and public DNS via `dig @1.1.1.1`.

| Item | Actual state | Evidence |
|---|---|---|
| Semaphore DNS | `semaphore.de.int.wahlberger.dev` is a CNAME to `ops.de.int.wahlberger.dev`, which resolves to `10.243.25.185` (= `vm_zt_ip`). `pi.de.int.wahlberger.dev` still has an A record (`10.10.0.101`), used by nothing in the CNAME chain. | `dig`; PR D `1c40eaa`: `semaphore_dns_cutover_enabled: true` in `ops-de-wahlberger-dev/inventories/production/group_vars/all/vars.yml:121` |
| Semaphore cut-over (OP-08 code side) | Merged: PR #40 (`ad198c9`, 2026-10-17). Live steps (Pi stop, schedule activation, Uptime Kuma TCP monitor) are not verifiable from the repo. | `git log master`, `1c40eaa` message |
| Pi still in repo | `pi-de-int-wahlberger-dev/` present with its own `site.yml` (incl. `semaphore`, `restic_server`, `caddy`). Renovate freeze rule for `pi-de-int-wahlberger-dev/**` still in `renovate.json:89`. Root `README.md` Pi row still says "runs all the playbooks… Retires at PR E". | `git ls-tree master pi-de-int-wahlberger-dev/`; `renovate.json`; `README.md:16` |
| Pi as backup target | No longer. Cloud client defaults to `nas.de.int.wahlberger.dev`; NAS `restic_backup_decommission_enabled: true`; NAS runs `restic_server` (gated by `backup_disk_enabled: true`). | `cloud-wahlberger-dev/roles/restic_backup/defaults/main.yml:28`; `nas-de-int-wahlberger-dev/inventories/production/group_vars/all/vars.yml:55,72` |
| SSH automation key | Replaced on ops, nas and cloud by PR C (`cd9e322`, `3e9fa02`). Old Pi key still needs revoking in PR E. | PR C commit |
| Pi retirement (OP-09, PR E, T-26/T-27) | Not started. PR E has not been merged; `pi-de-int-wahlberger-dev/` still exists. | `git log master`; directory listing |

Merged PRs (from `master` history): #26 plan; #27 podman socket check mode; #28 PR A2 (ZeroTier values); #29 PR A3 (step-3 decision); #30 PR A4 (pin Semaphore image); #31 beszel check mode; #32 vault copy keys tool; #33 and #36 NAS restic `ops` client and Vault keys (PR B); #37 NAS restic maintenance (PR B2); #38 maintenance log fix; #39 PR C (new automation key with `from=`); #40 PR D (cut-over).

Open: PR E (T-26, T-27); OP-W stabilisation window (≥14 days from cut-over); OP-09 Pi retirement, including the point-of-no-return steps and the USB drive (which holds the frozen `nas` and `cloud` restic repos, per the runbook). Not yet confirmed from the repo: whether OP-04 to OP-08 live steps were executed as written, and whether any Pi-side schedule was reactivated or left stopped.

### Scope split (read first)

**(a) REPO tasks (T-nn)**: an agent implements and verifies them offline. Allowed verification: `--syntax-check`, `ansible-lint`, `yamllint`, Molecule on a local Docker container, `tests/render-check.sh` and guard tests inside a disposable container, the local qemu fixture VM at `127.0.0.1:2222` (`tests/vm/ans.sh` refuses any other target), local `ansible-vault view | sha256sum` (values never printed; Erik unlocks 1Password), `git`, read-only `dig`. Agents prepare pull-request branches and draft descriptions; **Erik merges** (merge is deploy, BR-16).

**(b) OPERATOR steps (OP-nn)**: only Erik runs them on live systems (hcloud, ZeroTier Central, Hetzner firewall, 1Password/Vault unlock, Semaphore UI/API, Uptime Kuma, Beszel, Cloudflare, DB copy, cut-over, Pi retirement). They are checklist items below (runbook-driven: pointer to the README runbook, gate scenario ids, rollback), never agent tasks.

**Hard stop (workflow section 8)**: no agent runs `ansible-playbook` against any `inventories/production` host (nas, cloud, pi, ops), `ssh` to any of them, `hcloud`, the Central, Semaphore, Cloudflare or Uptime Kuma APIs. Every operator apply starts with `--check --diff` against the target, is read by Erik, and only then applied. A step whose `--check` output is unexplained does not proceed (BR-12).

### Assumptions / open risks

Plan decisions (T-01 ratifies them in a spec amendment, v1.3; until then consumer tasks use these names):
- PA-1 (gap 1, blocks planning) Variable contract, all in `<vm-dir>/inventories/production/group_vars/all/vars.yml` unless noted:
  - `vm_proxy_design`: `primary` (default) or `bridge_fallback`. Single selector. Wired to role inputs `caddy_design` and `semaphore_design` (same two values; role-prefixed, roles stay self-contained). Network names: `semaphore.network` (primary, fixed subnet) and `caddy.network` (fallback, shared by both containers).
  - `vm_zt_ip` (exists), `vm_zt_iface` (feeds `firewall_zerotier_interface`), `semaphore_network_subnet` (= `<sem-subnet>`, FR-127), `semaphore_uid` (int, empty by default; the `semaphore` role fails before any change naming `semaphore_uid` while it is empty, same pattern as FR-193).
  - Vehicle: **new pull request A3**, merged at the end of step 3 (after the step-3 tests, before step 4). A3 carries: `vm_proxy_design` as decided (primary, or `bridge_fallback` with the AC-04/AC-61 results recorded under SH-R-04 in the README), `semaphore_uid`, the AC-05 "directive not applied" note, the AC-08 snapshot-rollback note. Reason: A2 is merged before the step-3 tests, so it cannot hold test results.
  - `semaphore_uid` is read on the Pi **read-only in step 3** (`podman exec semaphore id -u`, allowed by FR-200; same pinned image, Renovate frozen) so it rides in A3 and no workstation `-e` is needed. Step 4 re-reads it (AC-53, A-32). Fallback if Erik prefers the spec's step-4 read: workstation `-e semaphore_uid=<n>` for the step-4 run, and every FR-70 rerun needs the same `-e` until pull request C (which then commits it). T-01 records Erik's choice.
  - During the step-3 fallback test the selector is passed as `-e vm_proxy_design=bridge_fallback` on the workstation and committed by A3 before any self-run exists.
- PA-2 (gap 2) The newest-task-ID comparison (FR-53/AC-20) runs **before the first VM task** of step 4 (before the AC-22 `--check` tasks create task rows); equivalently it compares against the "newest migrated task ID". T-01 amends FR-53/AC-20/AC-22 order.
- PA-3 (gap 3) Step-6 gate adds: new key logs in to cloud (template run) and a `<vm-dir>` self-run login; AC-23 `from=` list = `<vm-public-ip>`, `<vm-zt-ip>`, `<sem-subnet>` plus any FR-191 address (checked by `tests/static-checks.sh`).
- PA-4 (gap 4) AC-03 "public zone has no rich rules" reads `firewall-cmd --permanent --zone=public --list-rich-rules`, and T-05 pins a fail2ban `banaction` that adds no firewalld rich rule (nftables/ipset based). T-16 measures this on the fixture.
- PA-5 (gap 5) AC-51 must pass in the fallback too. If AC-51 fails in the fallback: **stop condition** = step 3 halts, no step 4, step-3 rollback runs, Erik decides on a redesign (spec return to requirements-engineer). AC-04's zone test is not a gate in the fallback (spec text), AC-04's other clauses still are.
- PA-6 (gap 6) AC-62 is two separate runs: `--tags cloudflare_dns` and `--tags caddy`, each expected to fail naming `vm_zt_ip`; guard tests exist separately per role (T-08, T-10).
- PA-7 (gap 7) FR-91's HTTP monitor (hostname `semaphore.de.int...`) resolves to the **Pi until step 8**, so AC-58 "up" proves nothing about the VM. From step 4 the operator also adds an Uptime Kuma TCP monitor `ops.de.int.wahlberger.dev:443` (cloud's Kuma reaches it via row M-04) and states it in the runbook. Step 0 records the Beszel systems and Uptime Kuma monitors that are up (baseline for FR-197/FR-198).
- PA-8 (gap 8) If `zypper-dup.service` overruns the window, the reboot request is queued through rebootmgr (`maint-window`) and happens in the next window, never outside. No `systemctl reboot` in the update script (T-06).
- PA-9 (gap 9) Retry after C-R: the revoked new key stays in `ssh_authorized_keys_revoked`; the retry generates a fresh keypair (FR-56 repeated), a new pull request C, and re-runs step 6 from the top. BR-16 rows C, C2, C-R: "Applied by: workstation" (step 6 deletes the Pi project; the VM's nas/cloud templates are the only automation left).
- PA-10 (gap 10, wording, folded into T-01 and T-17): "task history carried over" means "except the Pi project, deleted in step 6"; FR-162 reference point is the time AC-05 passed (the step-2 gate is AC-05; AC-49 is its time check; AC-62 may run after); FR-166 to FR-168 get one ID each in the amendment; FR-101 reads schedules "immediately before the Pi's stop" and step 8 text matches; "repeat them with AC-61" means: repeat AC-51 and the non-zone clauses of AC-04, then read the Quadlets (AC-61); reboot reference point for AC-07 is the owner reboot recorded in step 3 (AC-09); FR-198 "up before the change" means the step-0 baseline; FR-82 and FR-152 are one invocation, `restic check --read-data-subset=10%`, covering both.
- PA-11 `container` is a helper role used through `include_role`; FR-13 constrains only the role entries in `site.yml`. If `caddy` host networking needs a change in `container`, T-02 owns that role and T-08 must request it from the orchestrator, not edit it.
- PA-12 Pi `semaphore` role and the NAS roles are copied verbatim by T-02 (all 14 `site.yml` roles plus `container`), then adapted by one task per role. This keeps the skeleton green and file sets disjoint.
- PA-13 Local Molecule needs Docker or Podman; local ansible-core is 2.16 (pyenv venv), CI pins 2.20.8. Both must pass; CI is the final word.
- PA-14 The qemu fixture is aarch64; the target VM is x86_64. Fixture results are "simulator" evidence and never reported as hardware/live verified (host networking, firewalld zones, bridge DNAT, sshd reload, fail2ban banaction only).
- PA-15 FR-97: no commit under `pi-de-int-wahlberger-dev/` until step 7 ends. PR E tasks (T-26, T-27) therefore start after OP-07 and are never merged into the integration branch earlier.
- PA-16 The plan has 27 tasks (more than ~25): the 9-PR structure, the two-design Caddy/Semaphore matrix and the five documentation owners do not group further without breaking file-set disjointness. 11 of them are S.
- Open risks: (R1) Quadlet host networking / `container` role limits; (R2) the A-33 Caddy global options may not exist in `caddy:2` (T-03 decides before T-08); (R3) rebootmgr window behaviour is only checkable statically plus on the fixture; (R4) T-12 needs Erik's 1Password unlock and OP-00a; (R5) Docker not available to the agent host; (R6) 60-min hardening bound (FR-162) leaves no slack for a failed first `--check`, hence the T-16 rehearsal and the OP-02 dry-run budget.

### Definition of Done (all tasks)
- code formatted+linted, builds; task acceptance criteria verified by qa-verifier; unit tests for new logic to the test-quality tier; no skipped/weakened tests; no new warnings; docs/config updated; no secrets committed
- Additionally: `ansible-lint` (production profile), `yamllint`, `ansible-playbook site.yml --syntax-check` pass in every touched playbook directory; each role carries `meta/argument_specs.yml` and `README.md`; no `meta/main.yml` dependencies; role-prefixed variables; FQCN; Molecule second converge reports 0 changes where the role is in the Molecule list; nothing printed from a Vault (hash only); no live system touched.

### Execution order
Walking skeleton: T-02 (after the tiny contract task T-01).
- G0 (sequential): T-01 -> T-02.
- G1 {T-03, T-05, T-07, T-10, T-11}: disjoint (spike docs; `roles/security`; `roles/firewall`; `roles/cloudflare_dns`; `roles/restic_backup` + cloud restic role). Orchestrator may throttle to 4 worktrees.
- G2 {T-04, T-06, T-08, T-09, T-13}: T-04, T-08, T-09, T-13 need T-03; T-06 needs T-05. Disjoint (three `ssh_authorized_keys` role dirs + nas/cloud/vm molecule files; `roles/security` update files + `roles/reboot_notify`; `roles/caddy`; `roles/semaphore`; `tools/`).
- G3 {T-12}: needs T-04..T-11 (vars reconciliation, vault population; needs OP-00a and Erik's unlock).
- G4 {T-14, T-16, T-17}: need T-12 (+T-13): `tests/static-checks.sh` + `tests/pr-boundaries.sh`; `tests/vm/**` + `inventories/vm/**`; `README.md` + `CLAUDE.md` + `docs/**`. T-16 only blocks OP-03 (step 3), not PR A.
- G5 {T-15, T-18}: after T-14 (+T-17 for T-18): `.github/workflows/ci.yml`; security review (writes `docs/security-review.md` only).
- G6: T-19 (PR A packaging) then OP-00 merge.
- Late (after the named operator step; each group's file sets are disjoint inside the group):
  - L1 {T-20, T-24} any time after PR A is merged, before step 5/8 (nas `restic_server` client vs nas `homepage` + vm cutover flag + `renovate.json`).
  - T-21 after T-20 (shared nas vars/README). T-22 at steps 3 (A2, A3). T-23 at steps 4/6. T-25 after T-24 (+OP-08 evidence). T-26 and T-27 after OP-07 (PA-15), T-27 after T-26.
- Critical path: T-01 -> T-02 -> T-03 -> T-09 -> T-12 -> T-17 -> T-18 -> T-19 -> OP-00 (PR A) -> OP-01 -> OP-02 -> T-22 (A2) -> OP-03 -> T-22 (A3) -> OP-04 -> T-23 (C) -> OP-06 -> OP-07 -> OP-08 -> 14-day window -> OP-09 (T-26, T-27 = PR E).
- Sequential-only constraints: `vars.yml`, `README.md`, `renovate.json` and NAS `vars.yml` have one owner at a time (dependency order above enforces it).

### Tasks

#### T-01 — Contract and spec amendment v1.3 (variable names, PR A3, ordering/wording gaps)          [x] done
- Type: docs (spec amendment)
- Requirements: SH-FR-07/40/186/187, SH-FR-52, SH-FR-53, SH-FR-82/152, SH-FR-101, SH-FR-162, SH-FR-166..168, SH-BR-16, SH-D-12, SH-AC-03/04/05/08/20/22/48/49/51/58/61/63, Inputs table, PR table
- Agent: requirements-engineer    Priority: P0    Size: S    Parallel group: -
- Depends on: none. Needs Erik's one-line choice on the `semaphore_uid` vehicle (PA-1: A3 recommended).
- Files owned (may modify): `semaphore-migration/reqs/semaphore-to-hetzner.md`, `semaphore-migration/reqs/index.md`    Must not touch: everything else
- Context: Final audit gap 1 blocks planning: no selector for Caddy primary vs fallback, no Semaphore UID variable, no PR vehicle for README edits needed by step-2 to step-4 gates. The same pass fixes the wording gaps 2 to 10 so later tasks can copy acceptance text without contradicting the spec.
- Acceptance criteria (verifiable):
  - [ ] Given the amended spec, when searched, then the Inputs table has rows for `vm_proxy_design` (primary|bridge_fallback), `caddy_design`/`semaphore_design`, `vm_zt_iface`, `semaphore_network_subnet`, `semaphore_uid` (empty default, guard), each with the PR that sets it
  - [ ] The PR table (BR-16) has a row A3 (end of step 3: selector, UID, README observations) with a "why safe to apply early" cell, rows C/C2/C-R say "workstation", and Pi-read of the UID moves to step 3 (or the `-e` alternative is written out with the FR-70 consequence)
  - [ ] SH-D-12 states the fallback stop condition (PA-5); AC-03 uses `--permanent` for the rich-rule clause (PA-4); AC-51 is required in both designs; AC-62 names two separate runs
  - [ ] FR-53/AC-20/AC-22 order and wording per PA-2; AC-48/step-6 gate per PA-3; FR-91/AC-58 per PA-7; FR-73/74 per PA-8; retry after C-R per PA-9; every PA-10 wording item fixed, with new IDs for the split FR-166..168 (never reusing a Deleted ID)
  - [ ] Version is 1.3, decision log has a 1.3 entry, `status: ready`, no open questions, `index.md` updated
- Verification: `git diff master -- semaphore-migration/reqs`; `grep -n 'vm_proxy_design\|semaphore_uid\|A3' semaphore-migration/reqs/semaphore-to-hetzner.md`; requirements-engineer self-audit of ID uniqueness (`grep -o 'SH-[A-Z]*-[0-9]*' ... | sort | uniq -d` prints only intended repeats)
- Gate: host    Risk/notes: Erik reviews the diff (gate A is not re-run for pure clarifications, but the new PR row is a decision). All later tasks cite the amended names.

#### T-02 — Walking skeleton: `ops-de-wahlberger-dev` scaffold, 14 roles tagged, Molecule + render harness + CI green          [x] done (CI criterion pending push)
- Type: skeleton
- Requirements: SH-FR-10..14 (hostname var), SH-FR-135..143, SH-FR-12, SH-FR-13, SH-FR-62, SH-FR-20 (copy), SH-FR-22/23/24 (copies), SH-C-01
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: -
- Depends on: T-01
- Files owned (may modify): `ops-de-wahlberger-dev/**` (new directory)    Must not touch: nas/cloud/pi dirs, `.github/`, `renovate.json`, root README
- Context: Smallest end-to-end slice that proves the toolchain: a playbook dir that passes CI validate + Molecule and contains the security, firewall, zerotier, caddy and semaphore roles (verbatim copies first; later tasks adapt them). Enabling work that unblocks G1 and G2. If the agent exceeds its context, split into scaffold vs role copies.
- Acceptance criteria (verifiable):
  - [ ] Given a clean checkout, when `cd ops-de-wahlberger-dev && ansible-playbook site.yml --syntax-check`, then exit 0, and `site.yml` lists exactly `common, notify_failure, disk_space, ssh_authorized_keys, security, reboot_notify, firewall, podman, zerotier, beszel_agent, cloudflare_dns, caddy, semaphore, restic_backup`, each with `tags: [<role name>]`
  - [ ] `hosts.yml` lists only `ops.de.wahlberger.dev` and sets no `ansible_host` (D-17); `group_vars/all/` has `vars.yml` (every Inputs-table key with T-01 names and safe placeholders), an Ansible-Vault-encrypted placeholder `vault.yml` (encrypted with a throwaway local password kept outside the repo; T-12 re-keys it), and `vault.yml.example`; `.vault_pass.sh` reads `op://DevOps/Ansible Vault - ops-de-wahlberger-dev/password`; `.yamllint`, `.ansible-lint`, `ansible.cfg`, `requirements.yml` exist
  - [ ] `yamllint .` and `ansible-lint` (production) exit 0 in the directory
  - [ ] `molecule test` converges `common, notify_failure, disk_space, ssh_authorized_keys, security` on `opensuse/tumbleweed` and the second converge reports 0 changed; `molecule/default/verify.yml` imports stub `verify-ssh-keys.yml` and `verify-security.yml` (owned by T-04/T-05)
  - [ ] `tests/render-check.sh` (adapted from NAS) renders the `zerotier` Quadlet from `tests/render.d/zerotier.yml` and `systemd-analyze verify` passes in a Tumbleweed container; `tests/render.d/` and `tests/guards.d/` registries exist for role tasks to add files
  - [ ] Pushing the branch gives green `validate`, `molecule` and `vault-encrypted` CI jobs for the new directory (generic discovery by `ansible.cfg`, no CI edit)
- Verification: `cd ops-de-wahlberger-dev && ansible-playbook site.yml --syntax-check && yamllint . && ansible-lint && molecule test && tests/render-check.sh`; `gh run list --branch feature/semaphore-to-hetzner`
- Gate: host    Risk/notes: Molecule covers no firewall/caddy/semaphore (container limits, as NAS). `container` helper role present (PA-11). Placeholder vault holds only fake values.

#### T-03 — Spikes: authorized_key `from=` (A-26), Caddy global options (A-33), Semaphore image facts (A-09/A-31/A-32)          [x] done (spike; decisions in docs/spikes)
- Type: spike
- Requirements: SH-A-26, SH-A-33, SH-A-09, SH-A-31, SH-A-32 (inputs to FR-126, FR-129, FR-183/184, FR-91, FR-166..169, T-13)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G1
- Depends on: T-02
- Files owned (may modify): `ops-de-wahlberger-dev/docs/spikes/**` only (throwaway scratch goes to the scratchpad directory)    Must not touch: roles, vars, tests
- Context: Time-boxed (about 2 h) decisions that three role tasks depend on. Output is a decision note per assumption with the exact command and result, not production code.
- Acceptance criteria (verifiable):
  - [ ] A-26: given the Molecule container, when `ansible.posix.authorized_key` is run with a leading `from="..."` option line, then the note records whether the line is stored verbatim and whether a second run with changed options updates in place (idempotent); if not, it states the `key_options` fallback to use in T-04
  - [ ] A-33: given `docker run caddy:2` (and the xcaddy build used by the NAS role), when a Caddyfile with global `admin off`, `auto_https disable_redirects`, `default_bind <ip>` is validated, then the note records the working syntax or the alternative (T-08 input); `ss`-equivalent proof of no port 80/2019 from a local run is attached
  - [ ] A-09/A-32/A-31: given a local `semaphoreui/semaphore:v2.19.16` container with a throwaway SQLite DB, then the note records `GET /api/ping` status, `id -u` of the process, and the API endpoints/JSON fields that yield the project/template/inventory/repository/environment/key/user/schedule counts, newest task id and active schedules (T-13 input)
  - [ ] Each note ends with a one-line decision and the task(s) it affects
- Verification: read `docs/spikes/*.md`; re-run the recorded commands (all local, container only)
- Gate: host (container)    Risk/notes: Pulls images; needs network. Nothing is applied to any real host.

#### T-04 — `ssh_authorized_keys`: revoked list, both-lists failure, `from=` options in nas, cloud and `<vm-dir>`          [x] done (verified CONDITIONAL)
- Type: slice
- Requirements: SH-FR-60, SH-FR-190, SH-FR-62, SH-CC-04, SH-E-40, SH-AC-44, SH-DOC-05 (role README), SH-BR-10 (mechanism)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-02, T-03
- Files owned (may modify): `nas-de-int-wahlberger-dev/roles/ssh_authorized_keys/**`, `cloud-wahlberger-dev/roles/ssh_authorized_keys/**`, `ops-de-wahlberger-dev/roles/ssh_authorized_keys/**`, the three `molecule/default/*` files for this role (nas, cloud: `converge.yml`/`molecule.yml` additions; vm: `verify-ssh-keys.yml`)    Must not touch: any `vars.yml`, `vault.yml`, pi dir
- Context: PR A content for nas and cloud (merge is deploy: with `ssh_authorized_keys_revoked: []` and unchanged lists the role must change nothing). Same role code in three directories (copy-per-playbook convention).
- Acceptance criteria (verifiable):
  - [ ] Given `meta/argument_specs.yml`, then `ssh_authorized_keys_revoked` is `list` of `str`, default `[]`, in all three roles
  - [ ] Given a test key line with `from="a,b"` in `ssh_authorized_keys_list`, when Molecule converges, then the test user's `authorized_keys` holds the line with its option; given the key only in `_revoked`, then it is absent and a repeat reports 0 changed; given the key (any options/comment) in both lists, then the role fails before any change naming the key's comment
  - [ ] Given `ssh_authorized_keys_revoked: []` and the production lists, the role's task results are identical to master's (no changed task) in the Molecule second converge
  - [ ] Role READMEs describe the revoked list, the options, and BR-10's rule; the three roles stay byte-identical except directory-specific vars
- Verification: in each of `nas-de-int-wahlberger-dev`, `cloud-wahlberger-dev`, `ops-de-wahlberger-dev`: `molecule test`, `ansible-lint`, `yamllint .`, `ansible-playbook site.yml --syntax-check`; `diff -r` of the three role dirs
- Gate: host    Risk/notes: Negative scenarios (both lists) live inside the default Molecule sequence (verify with block/rescue) so CI needs no change. T-03 decides `key_options` vs line.

#### T-05 — `security` role for public SSH: sshd directives, `sshd -t` guard, reload, fail2ban, locked passwords, login email          [x] done (verified CONDITIONAL; see notes)
- Type: slice
- Requirements: SH-FR-15..19, SH-FR-116..125, SH-FR-157..159, SH-FR-188, SH-FR-122, SH-FR-14, SH-NFR-14, SH-NFR-15, SH-CC-14 (sshd/fail2ban/login-hook part), SH-E-29/30/32, SH-AC-45, SH-AC-56 (handler), SH-DOC-05
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G1
- Depends on: T-02
- Files owned (may modify): `ops-de-wahlberger-dev/roles/security/**` except the update/reboot files owned by T-06 (`tasks/updates.yml`, `templates/zypper-dup*`, `templates/rebootmgr*`; T-05 includes them with `include_tasks` stubs), `ops-de-wahlberger-dev/molecule/default/verify-security.yml`, `ops-de-wahlberger-dev/tests/render.d/security*.yml`, `tests/guards.d/security*.yml`    Must not touch: other roles, vars.yml
- Context: The VM is the only host with public SSH (SH-R-01); this role is the main preventive control. Differences vs NAS copy are listed in CC-14.
- Acceptance criteria (verifiable):
  - [ ] Given a converge, `sshd -T` in the container shows `passwordauthentication no`, `kbdinteractiveauthentication no`, `permitrootlogin no`, `authenticationmethods publickey`, `allowusers erikwahlberger` (from `security_ssh_allow_users`), and the applied Should directives `maxauthtries 3`, `logingracetime 30`, `allowtcpforwarding no`, `allowagentforwarding no`, `x11forwarding no`
  - [ ] Given an sshd override that fails `sshd -t`, when the converge runs, then the role fails, no reload/restart task ran, and `sshd -T` output is unchanged (AC-45)
  - [ ] The sshd handler uses `state: reloaded`; `grep -rn 'restarted' roles/security/handlers` prints nothing for sshd (AC-56, FR-188)
  - [ ] fail2ban jail renders `maxretry = 5`, `findtime = 600`, `bantime = 3600`, `ignoreip` = 127.0.0.0/8, `security_fail2ban_ignoreip` list (`<sem-subnet>`, 10.10.0.0/16, 10.243.0.0/16, cloud public IPv4), and a pinned `banaction` that adds no firewalld rich rule (PA-4)
  - [ ] Every password field in `/etc/shadow` of the container starts with `!` or `*` after converge (FR-122), with root and `erikwahlberger` handled
  - [ ] The public-login hook (PAM or sshd `ExposeAuthInfo` based, T-05's choice, documented) sends via `notify_failure`'s Resend credentials only for sources outside the ignore list; rendered script passes `shellcheck`; failure to send does not block login (E-32) and logs to the journal
  - [ ] Second converge: 0 changed
- Verification: `cd ops-de-wahlberger-dev && molecule test && tests/render-check.sh && ansible-lint && shellcheck` on rendered scripts
- Gate: host (container)    Risk/notes: fail2ban ban behaviour and rich-rule absence are rehearsed on the fixture (T-16) and verified live at OP-03 (AC-46/47). `userAllowed` lockout risk is mitigated by the `sshd -t` guard and by AC-05 step 2.

#### T-06 — `security`/`reboot_notify`: weekly `zypper dup`, rebootmgr maint-window, snapper pairs          [x] done (verified CONDITIONAL; live-only items pending)
- Type: slice
- Requirements: SH-FR-71..76 (unit side), SH-FR-195, SH-FR-25, SH-FR-68/150 (no upgrade on self-run side: `common_upgrade` honoured), SH-NFR-13, SH-E-16/17, SH-CC-14 (zypper-dup/rebootmgr part), PA-8, SH-DOC-05
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-05
- Files owned (may modify): `ops-de-wahlberger-dev/roles/security/{tasks/updates.yml,templates/zypper-dup*,templates/rebootmgr*,defaults/main.yml additions,README.md section}`, `ops-de-wahlberger-dev/roles/reboot_notify/**`, `ops-de-wahlberger-dev/roles/common/**` (only if snapper-zypp-plugin install belongs there), `tests/render.d/updates*.yml`    Must not touch: `roles/security/tasks/main.yml` beyond the include (T-05)
- Context: Replaces the NAS's weekly `zypper patch` with `zypper-dup.service`/`.timer` on Sunday 04:00 Europe/Berlin and sets rebootmgr to `maint-window` (04:00, 1h, Sunday).
- Acceptance criteria (verifiable):
  - [ ] Rendered `zypper-dup.timer` has `OnCalendar=Sun *-*-* 04:00:00` with `Europe/Berlin`, `Persistent=true`; `systemd-analyze verify` passes; `zypper-dup.service` has `OnFailure=notify-failure-immediate@%n.service`
  - [ ] Rendered rebootmgr config has strategy `maint-window`, window start `Sun 04:00`, duration `1h`
  - [ ] The update script requests reboots only through `rebootmgrctl` (no `systemctl reboot`/`shutdown`), only when `zypper needs-rebooting` exits 102, and calls `reboot_notify` before the request; a run that ends after 05:00 therefore leaves the request queued for the next window (PA-8; documented in the role README)
  - [ ] `common_upgrade=false` leaves `zypper dup` out of the `common` role; with the default it still upgrades (guard test via render/`--list-tasks` with the var)
  - [ ] snapper-zypp-plugin is installed so a btrfs root gets pre/post pairs (FR-25); README says what to do on a non-btrfs root (Hetzner snapshot)
  - [ ] Second converge: 0 changed
- Verification: `molecule test` in `ops-de-wahlberger-dev`; `tests/render-check.sh`; `ansible-playbook site.yml --list-tasks --tags security -e common_upgrade=false`
- Gate: host (container)    Risk/notes: Window overrun and rebootmgr behaviour are verified on the fixture (T-16, `rebootmgrctl` status) and live at OP-W (AC-28). Not all of this is provable in a container (R3).

#### T-07 — `firewall` role: public zone ssh only, ZeroTier zone by name, no reload, empty-interface guard          [x] done (verified CONDITIONAL: real firewalld unverified)
- Type: slice
- Requirements: SH-FR-06, SH-FR-08, SH-FR-09, SH-FR-128, SH-FR-185, SH-FR-189, SH-FR-194, SH-CC-15, SH-AC-62 (skip message), SH-DOC-05
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G1
- Depends on: T-02
- Files owned (may modify): `ops-de-wahlberger-dev/roles/firewall/**`, `tests/render.d/firewall*.yml`, `tests/guards.d/firewall*.yml`    Must not touch: other roles
- Context: The host firewall is the effective gate with host-networked Caddy (measured, BD-AC-45). firewalld cannot run in a Docker container (nftables), so this role is proven by render/guard tests here, by the fixture (T-16), and live at OP-03.
- Acceptance criteria (verifiable):
  - [ ] Given `firewall_zerotier_interface: ""`, when the role is rendered/run in check-list mode, then the public zone is configured, the ZeroTier binding and rules are skipped, and the skip message names `vm_zt_iface` (AC-62 firewall clause)
  - [ ] Given an interface name, then permanent plus immediate tasks exist for: interface bound by name to zone `zerotier` (`--permanent --zone=zerotier --add-interface`), services `ssh` and `https` in `zerotier`, a rich rule for `45876/tcp` from `<cloud-zt-ip>` only, public zone services `ssh` only (no `samba`, `http`, `https`)
  - [ ] `grep -rniE 'reload|restarted' roles/firewall` finds no firewalld reload/restart task or handler (AC-56, FR-189)
  - [ ] Role argument_specs validate required inputs (interface optional, cloud ZT IP required); README documents the zone model and `trusted` bypass for container traffic
- Verification: `ansible-lint`, `ansible-playbook site.yml --syntax-check`, `tests/guard-tests.sh firewall` (container, from T-02 harness), AC-56 `grep` above; fixture rehearsal in T-16
- Gate: simulator (fixture in T-16) / host here    Risk/notes: This task alone cannot show the rules apply; do not report it as verified on a firewalld host.

#### T-08 — `caddy` role: host-networked, bound to `vm_zt_ip`, `remote_ip` allowlist, both designs          [x] done (verified PASS)
- Type: slice
- Requirements: SH-FR-07, SH-FR-39, SH-FR-40, SH-FR-129, SH-FR-183, SH-FR-184, SH-FR-186 (Caddy side), SH-FR-187, SH-FR-193 (caddy), SH-FR-196, SH-FR-167 (`caddy.env` 0600 root), SH-FR-21/144 (caddy OnFailure), SH-CC-09, SH-AC-51 (render side), SH-AC-61 (Quadlet side), SH-AC-62 (caddy guard), SH-E-33/34, SH-DOC-05
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-02, T-03 (A-33)
- Files owned (may modify): `ops-de-wahlberger-dev/roles/caddy/**`, `tests/render.d/caddy*.yml`, `tests/guards.d/caddy*.yml`    Must not touch: `roles/container/**` (PA-11), semaphore role
- Context: Primary design (D-12): `Network=host`, bind `caddy_bind_address`, proxy `127.0.0.1:3000`. Fallback is a selector value (`caddy_design: bridge_fallback`): `caddy.network`, `PublishPort=<vm-zt-ip>:443:443`, upstream `semaphore:3000`.
- Acceptance criteria (verifiable):
  - [ ] Given `caddy_design: primary`, the rendered Quadlet has `Network=host`, no `PublishPort`, and the Caddyfile binds only `caddy_bind_address`, has no `:80` listener or `auto_https` redirect, `admin off`, a `remote_ip` allowlist from `caddy_allowed_sources` answering 403 otherwise, an access log with client address, upstream `127.0.0.1:3000`, DNS-01 through Cloudflare with the locally built `caddy-cloudflare` image
  - [ ] Given `caddy_design: bridge_fallback`, the Quadlet joins `caddy.network`, has exactly `PublishPort=<vm-zt-ip>:443:443`, upstream `semaphore:3000`; everything else unchanged
  - [ ] Given `vm_zt_ip` empty, when the role runs, then it fails before any change and the message names `vm_zt_ip` (guard test runs for caddy alone, separate from T-10's)
  - [ ] `caddy.env` renders mode `0600` owner root; `Restart=always` and `OnFailure=notify-failure@%n.service`; bind failure before the ZT IP exists leaves restart to systemd (E-33, A-20; role README says so)
  - [ ] `caddy validate` of the rendered Caddyfile passes in the `caddy-cloudflare` image for both designs
- Verification: `tests/render-check.sh` (both designs, via `-e caddy_design=bridge_fallback`), `tests/guard-tests.sh caddy`, `ansible-lint`, syntax-check
- Gate: host (render) / simulator (T-16)    Risk/notes: R2. Real client-address behaviour is only provable at OP-03 (AC-51); fixture NAT sources differ from ZeroTier.

#### T-09 — `semaphore` role: migrated-DB guard, UID/mode/label handling, dual design, self-run-safe          [x] done (verified PASS)
- Type: slice
- Requirements: SH-FR-41, SH-FR-52, SH-FR-55, SH-FR-127, SH-FR-130, SH-FR-166, SH-FR-168, SH-FR-169, SH-FR-207, SH-FR-208, SH-FR-167 (`semaphore.env`), SH-FR-186 (Semaphore side), SH-FR-204, SH-FR-21/144, SH-CC-07, SH-E-01, SH-AC-19 (offline half), SH-AC-53 (render half), SH-AC-61 (Quadlet side), SH-DOC-05, SH-FR-66 (role side)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G2
- Depends on: T-02, T-03 (A-09/A-32), T-01
- Files owned (may modify): `ops-de-wahlberger-dev/roles/semaphore/**`, `tests/render.d/semaphore*.yml`, `tests/guards.d/semaphore*.yml`    Must not touch: caddy role
- Context: Adapted from the Pi role (Debian-specific parts not ported, D-07). Config must come from the Vault values copied verbatim; the role never creates an empty DB when `semaphore_require_existing_db` is true.
- Acceptance criteria (verifiable):
  - [ ] Given `semaphore_require_existing_db: true` and no `<semaphore_data_dir>/data/database.sqlite`, when the role runs (guard test in a container), then it fails before any container task, message names the full path, and the file is still absent
  - [ ] Given `semaphore_uid` empty, then the role fails before any change naming `semaphore_uid`
  - [ ] Rendered files: `config.json` mode `0600` owner `semaphore_uid`; `semaphore.env` mode `0600` owner root; data dir mode `0700` owner `semaphore_uid`; an existing `database.sqlite` gets mode `0600`, owner `semaphore_uid`, SELinux type `container_file_t` (via `:Z` volume or an explicit `sefcontext`/`restorecon` task, documented); the role never copies or creates `-wal`/`-shm`/`-journal` files
  - [ ] Primary: Quadlet publishes `127.0.0.1:3000:3000` only, joins `semaphore.network` with fixed `semaphore_network_subnet`; fallback: joins `caddy.network`, publishes nothing
  - [ ] Container DNS is 1.1.1.1/8.8.8.8, and `getent hosts` expectations for `nas.de.int.wahlberger.dev`, `cloud.wahlberger.dev`, `ops.de.wahlberger.dev` (own name resolves to the public IPv4, `/etc/hosts` not inherited) and `github.com` are encoded in `tests/render.d` expectations
  - [ ] `OnFailure=notify-failure@%n.service`, `Restart=always`; `semaphore_dns_cutover`-independent; image tag is an input defaulting to the Pi's tag (`v2.19.16`), Renovate stays frozen via T-19
  - [ ] Role README covers migration, `semaphore_require_existing_db`, self-run exclusion (tag `semaphore` skipped by the template), file modes
- Verification: `tests/guard-tests.sh semaphore`, `tests/render-check.sh` (both designs), `ansible-lint`, syntax-check
- Gate: host (container) / simulator for SELinux label (T-16 checks `ls -Z` on the fixture)    Risk/notes: A-32 UID comes from T-03; the live compare is OP-04 (AC-53).

#### T-10 — `cloudflare_dns` role: extra A records, CNAME target and gate, `vm_zt_ip` guard          [x] done (verified PASS, stubbed Cloudflare)
- Type: slice
- Requirements: SH-FR-36, SH-FR-131, SH-FR-37, SH-FR-38, SH-FR-193 (cloudflare_dns), SH-CC-08, SH-AC-14 (render/idempotence), SH-AC-62 (cloudflare_dns guard), SH-E-12, SH-DOC-05
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: G1
- Depends on: T-02
- Files owned (may modify): `ops-de-wahlberger-dev/roles/cloudflare_dns/**`, `tests/guards.d/cloudflare_dns*.yml`    Must not touch: caddy role
- Context: Copy from the NAS role with the SH-CC-08 inputs. Live record behaviour (A-06, A-19) can only be checked at OP-03/OP-08.
- Acceptance criteria (verifiable):
  - [ ] Given default `cloudflare_dns_ip` and `cloudflare_dns_extra_a_records` = `[{record: ops.de.int.wahlberger.dev, value: "{{ vm_zt_ip }}"}]`, then the task list (mocked API in a guard test using `community.general.cloudflare_dns` with `check_mode`/stub module) creates the A record for `inventory_hostname` and the extra A record, and no CNAME while `cloudflare_dns_cnames_enabled: false`
  - [ ] Given `cloudflare_dns_cnames_enabled: true` and `cloudflare_dns_cname_target: ops.de.int.wahlberger.dev`, the CNAME `semaphore.de.int.wahlberger.dev` points at the target
  - [ ] Given empty `cloudflare_dns_extra_a_records` or empty `vm_zt_ip`, the role fails before any change; the `vm_zt_ip` message names `vm_zt_ip` (guard test runs for cloudflare_dns alone, PA-6)
  - [ ] Role never deletes records (grep: no `state: absent`)
- Verification: `tests/guard-tests.sh cloudflare_dns`, `ansible-lint`, syntax-check
- Gate: host    Risk/notes: A-06 (in-place CNAME update) is verified live with `--check --diff` in OP-08.

#### T-11 — `restic_backup` for the VM (consistent SQLite copy, no forget/prune, excludes) and cloud default (CC-06)          [~] VM half done+verified; cloud CC-06 default edit BLOCKED (needs Erik)
- Type: slice
- Requirements: SH-FR-77, SH-FR-78, SH-FR-80, SH-FR-81, SH-FR-82, SH-FR-152, SH-FR-151, SH-FR-171, SH-FR-83, SH-FR-21/145 (restic-backup OnFailure), SH-NFR-05/06 (design), SH-CC-06, SH-BR-11, SH-AC-30, SH-DOC-05, SH-DOC-11 (role README default), SH-E-19
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G1
- Depends on: T-02
- Files owned (may modify): `ops-de-wahlberger-dev/roles/restic_backup/**`, `cloud-wahlberger-dev/roles/restic_backup/{defaults/main.yml,meta/argument_specs.yml}`, `tests/render.d/restic*.yml`    Must not touch: cloud `vars.yml`, other cloud roles
- Context: Cloud `restic_backup` pattern (D-08) with the VM's paths. CC-06 is the PR A change to cloud: default host becomes `nas.de.int.wahlberger.dev`; production already overrides, so nothing changes.
- Acceptance criteria (verifiable):
  - [ ] Rendered timer: `OnCalendar=*-*-* 05:00:00`, `Persistent=true`; repository URL `rest:http://ops:<pw>@nas.de.int.wahlberger.dev:8000/ops/` from vars
  - [ ] Rendered script contains no `forget`/`prune`, contains exactly one `restic check --read-data-subset=10%` (covers FR-82/152, PA-10), and takes a consistent DB copy with `sqlite3 ... ".backup"` (or `VACUUM INTO`) into a staging dir that is the only DB path backed up
  - [ ] Backup paths/excludes keep `config.json`, every `*.env` (including the restic env file) and `identity.secret` out; a render test greps for each
  - [ ] Unit has `OnFailure=notify-failure-immediate@%n.service`; env file mode `0600` root; failure sends mail within 10 min via the existing `notify_failure` path
  - [ ] Given the cloud role, a rendered diff of cloud's templates with its production vars before vs after CC-06 is empty (`git stash`-free: compare render of master vs branch)
- Verification: `tests/render-check.sh`, `ansible-lint`/syntax-check in both dirs, `diff` of rendered cloud units (script in the task notes)
- Gate: host    Risk/notes: Backup content is demonstrated live at OP-05 (AC-31/33).

#### T-12 — VM vars/vault reconciliation: real `vars.yml`, populated `vault.yml` (hash-verified against the Pi Vault)          [x] done 2026-10-11: populate-vault.sh run by Erik, 7 copied keys match (tool verify), 2 generated; independent ansible-vault|sha256sum check (AC-17) optional, parser caveat F-2
- Type: slice (operator-assisted: needs OP-00a and Erik's 1Password unlock)
- Requirements: SH-FR-42..46, SH-FR-146..148, SH-FR-201, SH-FR-45, SH-FR-43/44, SH-FR-88 (value kept for OP), SH-FR-136/137, SH-FR-20 (thresholds), SH-FR-127 (value), SH-BR-09 (VM half), SH-C-02, SH-C-05, SH-AC-17, SH-AC-01 (vault clauses)
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G3
- Depends on: T-04..T-11, OP-00a
- Files owned (may modify): `ops-de-wahlberger-dev/inventories/production/group_vars/all/{vars.yml,vault.yml,vault.yml.example}`    Must not touch: nas/cloud/pi vault files (read-only for hash comparison)
- Context: Single owner of `vars.yml` after the role tasks, so role tasks never conflict on it. Placeholders become production values (names, `caddy_sites`, `semaphore_network_subnet` outside 10.10/16 and 10.243/16, `vm_proxy_design: primary`, `semaphore_uid: ""`, `vm_zt_ip: ""`, `vm_zt_iface: ""`, `semaphore_dns_cutover_enabled: false`, `semaphore_require_existing_db: true`, `beszel_agent_hub_key`, restic inputs, thresholds).
- Acceptance criteria (verifiable):
  - [ ] Given both Vaults unlocked, when each key of FR-43/44/146/201/46/147/148 is piped from both `vault.yml` files through `sha256sum`, then each hash pair is equal and no value is printed or logged
  - [ ] `vault.yml` is re-keyed with the real 1Password password (`head -c 15 vault.yml` is `$ANSIBLE_VAULT`); contains `vault_restic_backup_repo_password` and `vault_restic_backup_rest_server_password` (32 alphanumeric each, generated locally); `vault.yml.example` lists every key with empty values
  - [ ] `vars.yml` sets `semaphore_url`, `semaphore_oidc_client_id` (63093482-...), `vm_zt_ip: ""`, `semaphore_uid: ""`, `ssh_authorized_keys_list` = personal key only (BR-10 steps 0 to 5), `ssh_authorized_keys_revoked: []`; every `*_enabled`/design flag has a value; `ansible-playbook site.yml --syntax-check` passes
  - [ ] FR-62: personal key is in the list
- Verification: `tests/tools/vault-hash-compare.sh` (from T-13 if merged, else inline `ansible-vault view ... | sha256sum`), `ansible-playbook site.yml --syntax-check`, `yamllint .`, `ansible-lint`
- Gate: host    Risk/notes: R4. Output of decrypt commands must be piped to `sha256sum` only. The two restic passwords are later copied into the NAS vault by T-20.

#### T-13 — Operator tooling for steps 4/6: step-4 record, DB prepare/scan, compare, vault-hash, from= check          [x] done (verified CONDITIONAL; polish T-13b done: 114 tests pass)
- Type: slice (enabling tooling for operator checklist items)
- Requirements: SH-FR-49, SH-FR-53, SH-FR-175/176/203/204 (helper checks), SH-FR-178, SH-FR-179 (listing), SH-FR-177 (listing), SH-FR-54 (inactive schedules), SH-FR-126/191 (list check), SH-AC-17, SH-AC-18, SH-AC-20, SH-AC-54, SH-AC-55, SH-AC-23
- Agent: python-engineer    Priority: P1    Size: M    Parallel group: G2
- Depends on: T-03 (A-31 endpoints), T-02
- Files owned (may modify): `ops-de-wahlberger-dev/tools/**`, `ops-de-wahlberger-dev/tests/tools/**`    Must not touch: roles, vars
- Context: These scripts make the error-prone operator steps closed-loop and testable offline against a local Semaphore container and synthetic SQLite files. They never contact production; the operator runs them.
- Acceptance criteria (verifiable):
  - [ ] `step4-record.py <base-url>` (read-only GETs after a session login read from env) prints counts per kind, newest task id and active schedules as JSON; pytest runs it against a local `semaphoreui/semaphore:v2.19.16` container
  - [ ] `db-prepare.sh <copy>` runs `PRAGMA wal_checkpoint(TRUNCATE)`, asserts `integrity_check` is `ok`, asserts no `-wal/-shm/-journal` beside the copy, sets every schedule inactive, and lists matches of `pi.de.int.wahlberger.dev|pi-de-int-wahlberger-dev|/mnt/data`, API tokens and integrations by name only (never values); pytest on a synthetic DB covers ok, corrupt (exit non-zero) and WAL cases
  - [ ] `compare-record.py <record.json> <vm-url>` fails if any count differs from the record or the newest migrated task id differs (PA-2), and prints which kind differs
  - [ ] `vault-hash-compare.sh <key>...` prints only `match`/`MISMATCH` per key
  - [ ] `check-from-list.sh <repo>` verifies the new key line is the same string in nas, cloud, `<vm-dir>` and its `from=` equals `<vm-public-ip>,<vm-zt-ip>,<sem-subnet>` plus optional extras (PA-3)
- Verification: `cd ops-de-wahlberger-dev && pytest tests/tools -q && shellcheck tools/*.sh`
- Gate: host    Risk/notes: Needs Docker for the local Semaphore container test (skip marker with explicit reason, never silently pass).

#### T-14 — Static gate: `tests/static-checks.sh` for every [S] scenario + PR-boundary guard          [x] done 2026-10-11 CONDITIONAL (qa-verifier): 4 static FAILs are the expected missing T-17/T-19 files; see carry-over T-14
- Type: enabling (verification harness)
- Requirements: SH-AC-01, AC-17 (structure part), AC-23, AC-27, AC-30, AC-43, AC-44, AC-45, AC-56, AC-60, AC-61 (static), AC-62 (two guard tests separately), AC-63, SH-FR-97, SH-FR-62, SH-FR-160/161, SH-BR-16, SH-BR-10, SH-FR-111, SH-FR-205, SH-FR-13/143
- Agent: ansible-doctor    Priority: P0    Size: M    Parallel group: G4
- Depends on: T-12, T-13
- Files owned (may modify): `ops-de-wahlberger-dev/tests/static-checks.sh`, `ops-de-wahlberger-dev/tests/pr-boundaries.sh`, `ops-de-wahlberger-dev/tests/guard-tests.sh`    Must not touch: roles, `tests/vm/**`, `.github/`
- Context: Mirrors NAS `tests/static-checks.sh`: one command prints PASS/FAIL/SKIPPED per scenario id. `pr-boundaries.sh <A|A2|A3|B|B2|C|C2|C-R|D|E>` asserts, from `git diff`, the allowed file set per PR (BR-16 table, amended) so "safe to apply early" and AC-63 are machine-checked.
- Acceptance criteria (verifiable):
  - [ ] Given the current branch, when `tests/static-checks.sh` runs, then every listed [S] id prints PASS (or SKIPPED with a reason for decrypted-vault checks with no password), exit non-zero on any FAIL; each check demonstrably fails on a seeded defect (negative test per check, scripted in `tests/unit/`)
  - [ ] `tests/guard-tests.sh cloudflare_dns` and `tests/guard-tests.sh caddy` are separate invocations and both pass (PA-6)
  - [ ] `pr-boundaries.sh A` passes on the PR A branch and asserts: nothing under `pi-de-int-wahlberger-dev/`, only the file classes listed for A; `pr-boundaries.sh A2` and `A3` fail when any file outside `<vm-dir>` is touched; `pr-boundaries.sh E` is allowed to touch the Pi dir only when `STEP7_DONE=1`
  - [ ] `git grep -n -i -e 'zerotier.*token' -e 'ZT_TOKEN'` and `git grep 'PRIVATE KEY'` print nothing (FR-205, AC-23)
- Verification: `cd ops-de-wahlberger-dev && tests/static-checks.sh && tests/pr-boundaries.sh A && pytest tests/unit -q`
- Gate: host    Risk/notes: Decrypted-vault checks stay SKIPPED in CI by design.

#### T-15 — CI: run the static gate for `<vm-dir>` (and keep ansible-core pin note)          [~] done 2026-10-11 repo part (ops-static job added, actionlint clean for it); seeded-failure + green run need a PR (Erik)
- Type: enabling
- Requirements: SH-FR-11, SH-FR-140..142 (verify generic coverage), SH-FR-12 (CI molecule job covers the dir), SH-DOC-14 (CI comment part is done later in T-25)
- Agent: ci-pipeline-engineer    Priority: P1    Size: S    Parallel group: G5
- Depends on: T-14
- Files owned (may modify): `.github/workflows/ci.yml`    Must not touch: anything else
- Context: `validate`, `molecule` and `vault-encrypted` already discover the new directory by `ansible.cfg`. Add a job (like `nas-backup-static`) that runs `tests/static-checks.sh` and `tests/render-check.sh` for `<vm-dir>`.
- Acceptance criteria (verifiable):
  - [ ] Given a pull request, when CI runs, then jobs `validate (ops-de-wahlberger-dev)`, `molecule`, `vault-encrypted` and a new static job all pass; a seeded failing static check makes the new job fail (shown once on a throwaway branch, then reverted)
  - [ ] No other job's behaviour changes (diff of `ci.yml` limited to the new job)
- Verification: `gh run list`/`gh run view` for the branch; `actionlint .github/workflows/ci.yml`
- Gate: host    Risk/notes: Touching `.github/workflows` is merge-is-deploy-free (CI only).

#### T-16 — Fixture rehearsal: Caddy host networking, firewalld zone binding, bridge fallback, fail2ban banaction, sshd reload          [x] done 2026-10-11 CONDITIONAL
- Type: spike (simulator)
- Requirements: SH-D-12 (decision input), SH-A-20, SH-A-21 (stand-in), SH-A-22, SH-A-30, SH-A-08 (partial), SH-FR-185, SH-FR-128, SH-FR-06, SH-FR-188, SH-FR-189, SH-NFR-15 (banaction), PA-4, PA-8; informs SH-AC-03/04/46/51/61
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: G4
- Depends on: T-05, T-07, T-08, T-09, T-12
- Files owned (may modify): `ops-de-wahlberger-dev/tests/vm/**`, `ops-de-wahlberger-dev/inventories/vm/**`    Must not touch: roles, production inventory
- Context: Reuse the NAS `tests/vm` approach (qemu aarch64 Tumbleweed, disposable, key-only, `ans.sh` refuses non-fixture targets). Rehearses what OP-03 will measure on the real VM so a failed first attempt does not eat the 60-min and step-3 budget. Required before OP-03, not before PR A.
- Acceptance criteria (verifiable):
  - [ ] Given the fixture provisioned with a fake `zt0`-style dummy interface and a stand-in ZT IP, when the roles are applied via `tests/vm/ans.sh`, then the zone binding exists in `--permanent` config and survives `firewall-cmd --reload` and a guest reboot
  - [ ] Primary design: `firewall-cmd --zone=<zt zone> --remove-service=https` (runtime) makes the host-side request fail and re-adding restores it (AC-04 analogue); `ss -tlnp` shows Caddy only on the stand-in IP:443 with no :80 and no :2019; Caddy restarts by itself after the address appears (A-20)
  - [ ] Bridge fallback: measure and record whether the published port bypasses zone rules and whether the client source address survives (A-22) with a result file `RESULTS.md`
  - [ ] `sshd` reload keeps an established session (A-30); fail2ban bans after 5 failures and `firewall-cmd --permanent --zone=public --list-rich-rules` stays empty with the T-05 `banaction` (PA-4)
  - [ ] `ls -Z` of the placed database shows `container_file_t` after the first container start (FR-208)
  - [ ] `RESULTS.md` labels every result "simulator, aarch64"; any failure becomes a defect list handed to the owning role task
- Verification: `tests/vm/up.sh && tests/vm/scenarios/*.sh` as documented in `tests/vm/README.md`; results file reviewed by qa-verifier
- Gate: simulator    Risk/notes: R5/PA-14. Cost: first image build 10-15 min. If the fixture cannot run in the agent environment, Erik runs it (counts as a one-line operator item OP-02a) or step 3 proceeds with the spec-defined test and fallback.
- Carry-over (done 2026-10-11): the first `--check --diff` of the whole `site.yml` now passes on the fixture (snapshot `clean`; `--skip-tags cloudflare_dns`, which needs the real API), then real apply, second run, check on the applied host (changed=0) and s10+s20 (`tests/vm/RESULTS.md`, defect 1 fixed; guard `tests/guards.d/firewall.yml`). Conditions: the bridge fallback bypasses the zone rules (RESULTS.md); s30/s40/s50 were verified by the author only, not re-run here; zypper exit 103 stays a failure by decision (mail on 103 accepted); check mode skips the three ZeroTier-zone firewall tasks on a fresh host; the second real run showed changed=1 (zerotier data dir mode, converges on the third run); `cloudflare_dns` not exercised on the fixture.

#### T-17 — `<vm-dir>/README.md` runbook, `CLAUDE.md`, flow-rule doc skeleton          [x] done 2026-10-11 (qa-verifier CONDITIONAL, F-1..F-7 fixed; AC-27/01/63 PASS)
- Type: docs
- Requirements: SH-FR-96, SH-FR-70, SH-FR-90, SH-FR-133, SH-FR-134, SH-FR-132 (README link), SH-FR-139, SH-FR-114 (DOC-03/04), SH-BR-01..04, SH-BR-12, SH-BR-16 (PR table incl. A3), SH-NFR-07 (timed recovery in README), SH-DOC-03, SH-DOC-04, SH-AC-27, SH-FR-33 (file skeleton), SH-DOC-06 skeleton, SH-E-35 (incident note), SH-R-04
- Agent: docs-writer    Priority: P0    Size: M    Parallel group: G4
- Depends on: T-12 (and T-04..T-11 for accuracy)
- Files owned (may modify): `ops-de-wahlberger-dev/README.md`, `ops-de-wahlberger-dev/CLAUDE.md`, `ops-de-wahlberger-dev/docs/**` except `docs/spikes/**` and `docs/security-review.md`    Must not touch: roles, tests, other dirs
- Context: The README is the operator's runbook (this is what OP-nn items point to). It must carry the amended gates, the stop condition (PA-5), the PA-7 monitor, the PA-3 step-6 additions and the `--check --diff` first rule for every apply.
- Acceptance criteria (verifiable):
  - [ ] Given the README, then it contains steps 0 to 9 each with its gate scenario ids (from the amended step-gate table) and a rollback, the PR table with A, A2, A3, B, B2, C, C2, C-R, D, E, the BR-02/BR-13 preconditions, and an explicit "run `--check --diff` first" line for every apply command
  - [ ] It contains: the workstation command for the roles a self-run excludes (`--tags semaphore,zerotier`, `-e ansible_host=ops.de.int.wahlberger.dev`) and the note that a `semaphore_image` change takes effect only through it; the DB restore procedure (stop, replace, owner/mode, start); the Cloud Firewall rule table and the `hcloud` commands; break-glass; update/reboot policy incl. the window-overrun rule; snapshot 30-day deadline; incident note for E-35; key procedure; fallback and SR-04 text; step-9.3 log rule
  - [ ] `docs/zerotier-flow-rules.md` exists with "before" and "in force" sections (dated, link to Central's rules reference); the "before" text is filled in by T-19 from OP-00b input
  - [ ] `CLAUDE.md` documents conventions/deviations (CC-07..09, 14, 15), stack table, data and secrets, file modes
  - [ ] `tests/static-checks.sh` README checks (AC-27) PASS
- Verification: `tests/static-checks.sh` (AC-27 section), `markdownlint` if configured, qa-verifier reads against AC-27 line by line
- Gate: host    Risk/notes: Role READMEs (DOC-05) are owned by the role tasks, not this one.

#### T-18 — Security review of `<vm-dir>` before PR A (public SSH, key handling, secrets, ports)          [x] done 2026-10-11 (0 crit/high, 2 medium F-01,F-02 fixed + F-05; 12 low in docs/security-review.md; xcaddy pins unverified by live build)
- Type: security
- Requirements: SH-R-01, SH-R-04, SH-R-06, SH-FR-04/06/15..18/115..125/157..159/166..169/171, SH-D-14..16/18..21, SH-BR-06/11, SH-NFR-03/14/15
- Agent: security-auditor    Priority: P0    Size: M    Parallel group: G5
- Depends on: T-14, T-17
- Files owned (may modify): `ops-de-wahlberger-dev/docs/security-review.md` (findings only)    Must not touch: anything else
- Context: Dedicated security gate (auth, secrets, network exposure, firewall, key rotation) before the first merge. Reviews roles, vars, README, tests; no live access.
- Acceptance criteria (verifiable):
  - [ ] Given the branch, then the review lists each FR in the "security-relevant IDs" list with PASS/FINDING and evidence (file:line), including: no listener/ports beyond TCP 22 in any rendered Quadlet; file modes/owners; no secret in logs or env of units visible to other users; excludes of `config.json`/`*.env`/`identity.secret`; `from=` handling; fail2ban ignore list; the login email hook cannot be triggered by attacker-controlled input into a shell
  - [ ] Every FINDING of severity medium or higher has a task assigned and is closed before T-19 starts (re-review line)
- Verification: security-auditor report attached to the task log; `git diff` shows only the review file
- Gate: host    Risk/notes: Residual risk SH-R-01 is accepted by Erik; this review does not re-open it.

#### T-19 — PR A packaging: Renovate freeze rules, "before" flow-rule record, boundary check, PR description          [~] done 2026-10-11 repo part; Erik: 'before' rule text + cloud restic one-liner + step-0 baseline pending (see PR-A-description.md)
- Type: slice
- Requirements: SH-FR-160, SH-FR-161, SH-FR-33, SH-FR-97, SH-FR-62, SH-CC-16, SH-BR-16 (row A), SH-AC-01, AC-60, AC-36 (git half), SH-DOC-06 ("before"), SH-DOC-15
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: G6
- Depends on: T-18, T-15, T-14 and OP-00b input (Central's current rule set text)
- Files owned (may modify): `renovate.json`, `ops-de-wahlberger-dev/docs/zerotier-flow-rules.md` ("before" section only), PR A description draft    Must not touch: pi dir
- Context: Final assembly of PR A (all of T-02..T-17 outputs + two Renovate rules). Erik merges it as part of OP-00.
- Acceptance criteria (verifiable):
  - [ ] `renovate.json` has a package rule with `enabled: false` and `matchFileNames` for `pi-de-int-wahlberger-dev/**`, and one for `ops-de-wahlberger-dev/roles/semaphore/defaults/main.yml`; `npx renovate-config-validator renovate.json` passes
  - [ ] `renovate --platform=local` (dry run, if installable; otherwise A-34 is verified at OP-00 via the Dependency Dashboard, AC-60) lists no update for those files
  - [ ] `tests/pr-boundaries.sh A` PASS; `git diff master --stat -- pi-de-int-wahlberger-dev` is empty; nas/cloud changes limited to T-04 and T-11 files; `tests/static-checks.sh` PASS; the PR description lists the gate scenarios for step 0 and the "safe to apply early" statement of row A
  - [ ] The "before" rule set is in the flow-rules doc with a date, or the PR description says it is added by Erik in a follow-up commit before merge
- Verification: commands above plus `gh pr view --json files`
- Gate: host    Risk/notes: Merge is deploy for nas/cloud (Pi Semaphore applies master): operator confirms the AC-44 no-op property from the Molecule output before merging.

#### T-20 — PR B: NAS rest-server client `ops` (+ Vault keys, examples, docs)          [x] done (merged #33, #36; 2026-10-16/17)
- Type: slice
- Requirements: SH-FR-84, SH-CC-02, SH-BR-09 (NAS half), SH-BR-16 (row B), SH-DOC-07 (part), SH-R-03
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: L1
- Depends on: T-19 merged (OP-00), T-12 (passwords exist in VM vault)
- Files owned (may modify): `nas-de-int-wahlberger-dev/inventories/production/group_vars/all/{vars.yml,vault.yml,vault.yml.example}` (restic_server entries only), `nas-de-int-wahlberger-dev/README.md` Backups section, `nas-de-int-wahlberger-dev/CLAUDE.md` restic rows    Must not touch: `roles/restic_server/**` (T-21), cloud, pi
- Context: Adds one htpasswd client and its Vault keys; copies the two shared secrets from the VM vault by hash-verified copy (BR-09). Nothing uses it until the VM backup runs.
- Acceptance criteria (verifiable):
  - [ ] `restic_server_clients` contains `cloud` and `ops` with `vault_restic_server_ops_htpasswd_password`; NAS `vault.yml` gains `..._ops_htpasswd_password` and `..._ops_repo_password`, each hash-equal to the VM vault's `vault_restic_backup_rest_server_password` / `_repo_password` (BR-09, hash only)
  - [ ] `vault.yml.example` lists both keys; `ansible-playbook site.yml --syntax-check`, `ansible-lint`, `yamllint .`, `molecule test` pass in the NAS dir; `tests/render-check.sh` (NAS) still passes
  - [ ] `tests/pr-boundaries.sh B` PASS (nas files only)
- Verification: commands above in `nas-de-int-wahlberger-dev`; `ops-de-wahlberger-dev/tests/tools/vault-hash-compare.sh`
- Gate: host    Risk/notes: Needs Erik's unlock. NAS Vault must not contain `access_key_encryption` (BR-11).

#### T-21 — PR B2: NAS maintenance for both repositories (CC-01) and freshness path (CC-03)          [x] done (merged #37, #38; 2026-10-17)
- Type: slice
- Requirements: SH-FR-85, SH-FR-86, SH-FR-87, SH-FR-153, SH-FR-154, SH-FR-155, SH-CC-01, SH-CC-03, SH-E-18/20, SH-BR-16 (row B2), SH-AC-32 (render/test half), SH-DOC-07
- Agent: ansible-doctor    Priority: P1    Size: M    Parallel group: -
- Depends on: T-20
- Files owned (may modify): `nas-de-int-wahlberger-dev/roles/restic_server/**`, `nas-de-int-wahlberger-dev/tests/unit/test_restic_maintenance.py` (+fixtures), `nas-de-int-wahlberger-dev/tests/vm/scenarios/t29-*` if scenarios need the list form, NAS `vars.yml` maintenance list and `backup_disk_freshness_checks`, NAS README/role README    Must not touch: cloud, pi, `ops-de-wahlberger-dev`
- Context: `restic_server_maintenance_repo` (single) becomes a list of `{repo, password}` (production `cloud`, `ops`); each repo gets prune guard, forget 7/4/6, prune, check. `cloud` commands must be unchanged. Merged only after the first VM backup created the repository (E-18).
- Acceptance criteria (verifiable):
  - [ ] Given the rendered maintenance script for `cloud` before and after, then the `cloud` commands and keep values are identical (diff empty, FR-86)
  - [ ] Given two list entries, then for `ops` the script shows: prune guard, `forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6`, prune, check; guard applies before forget (FR-154/153)
  - [ ] Given an empty/missing list entry password, the role fails before any change; argument_specs updated; `backup_disk_freshness_checks` contains `/mnt/data/restic-repos/ops/snapshots` with `max_age_hours: 26`
  - [ ] `pytest tests/unit -q` and `tests/static-checks.sh` (NAS) PASS; `molecule test` unaffected; `tests/pr-boundaries.sh B2` PASS
- Verification: in `nas-de-int-wahlberger-dev`: `pytest tests/unit -q`, `tests/static-checks.sh`, `tests/render-check.sh`, ansible-lint/yamllint/syntax-check
- Gate: host (fixture `t29`/`t31` scenarios optional, simulator)    Risk/notes: Existing NAS fixture scenarios cover rest-server; updating them is allowed here.

#### T-22 — PR A2 (step 3 values) and PR A3 (step 3 observations, selector, UID)          [x] done (merged #28, #29; 2026-10-11)
- Type: slice (runtime repo task; two sittings, inputs from Erik)
- Requirements: SH-FR-34, SH-FR-192, SH-FR-29 (value), SH-FR-185 (name), SH-DOC-06 (in force), SH-AC-63, SH-BR-16 (rows A2, A3), PA-1, SH-AC-05/08/61 (README notes)
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: -
- Depends on: OP-02 (A2 inputs: `vm_zt_ip`, `vm_zt_iface`, flow-rule text, from OP-03); A3 inputs after the step-3 tests; T-19 merged
- Files owned (may modify): `ops-de-wahlberger-dev/inventories/production/group_vars/all/vars.yml`, `ops-de-wahlberger-dev/docs/zerotier-flow-rules.md`, `ops-de-wahlberger-dev/README.md` (observation sections only)    Must not touch: anything outside `ops-de-wahlberger-dev/`
- Context: Two tiny PRs. A2 (merged at the start of step 3): `vm_zt_ip` in 10.243.0.0/16, `vm_zt_iface`, dated "in force" rules. A3 (end of step 3): `vm_proxy_design`, `semaphore_uid`, test observations (AC-05 directives not applied, AC-08 snapshot note, AC-04/AC-61 result and SH-R-04 text if the fallback is used).
- Acceptance criteria (verifiable):
  - [ ] A2: `vm_zt_ip` matches `^10\.243\.` , `vm_zt_iface` non-empty, "in force" section present with a date, `tests/pr-boundaries.sh A2` PASS (no file outside `<vm-dir>`), `--syntax-check` PASS
  - [ ] A3: `vm_proxy_design` is `primary` or `bridge_fallback` matching the operator's decision; `semaphore_uid` is a positive integer; README observation sections filled from operator-supplied text; `tests/pr-boundaries.sh A3` PASS
  - [ ] If `bridge_fallback`, the rendered Quadlets show `semaphore:3000` and one shared bridge network (AC-61 static half) via `tests/render-check.sh -e vm_proxy_design=bridge_fallback`
- Verification: `tests/static-checks.sh && tests/pr-boundaries.sh A2` (resp. `A3`)
- Gate: host    Risk/notes: Values come from Erik; the agent never reads Central or the Pi.

#### T-23 — PR C: new key with `from=` in nas, cloud, `<vm-dir>` (+ contingent C2 and C-R branches)          [x] done (merged #39; 2026-10-17)
- Type: slice (runtime repo task, inputs from Erik)
- Requirements: SH-FR-56 (pubkey use), SH-FR-62, SH-FR-126, SH-FR-191 (C2), SH-CC-05, SH-BR-10, SH-BR-16 (rows C, C2, C-R), SH-AC-23, PA-3, PA-9
- Agent: ansible-doctor    Priority: P0    Size: S    Parallel group: -
- Depends on: OP-04 (draft starts at step 4), new key public half from OP-00b, `<vm-public-ip>`, T-22
- Files owned (may modify): the three `vars.yml` (`ssh_authorized_keys_list` / `_revoked` only), draft PR description (migration notes: names only, supplied by Erik)    Must not touch: roles, vault files
- Context: One identical key line `from="<vm-public-ip>,<vm-zt-ip>,<sem-subnet>" ssh-ed25519 ... semaphore-automation@ops.de.wahlberger.dev` in all three lists. C2 (only if FR-191 finds another source) widens `from=` by one address; C-R (only on step-6 rollback) moves the new key to `_revoked` in all three. Applied by the workstation (PA-9).
- Acceptance criteria (verifiable):
  - [ ] Given PR C, the lists match the BR-10 "step 6 to 9.4" row (nas, cloud: personal, old, new; `<vm-dir>`: personal, new), the new key line is the same string in all three files, `from=` has exactly the three addresses, `git grep 'PRIVATE KEY'` prints nothing
  - [ ] `tests/tools/check-from-list.sh` PASS; `tests/pr-boundaries.sh C` PASS
  - [ ] C2 branch prepared on request with the extra address in all three lists; C-R branch prepared on request moves exactly the new key line to `ssh_authorized_keys_revoked` in all three and leaves the old key in nas/cloud lists; both pass `pr-boundaries.sh`
  - [ ] Migration-notes description contains only names, never values (grep for `ssh-ed25519` private markers and for 32+ char base64 blobs finds nothing but the public key line)
- Verification: `tests/static-checks.sh && tests/pr-boundaries.sh C`; Molecule in nas/cloud (idempotence with the new key) if time allows
- Gate: host    Risk/notes: Merge is deploy: Pi Semaphore may apply C to nas/cloud at any time; the key is usable only from the VM's addresses.

#### T-24 — PR D code: NAS homepage label (CC-10), `semaphore_dns_cutover_enabled: true`, Renovate rule removal          [x] done (merged #40, commit `1c40eaa`; 2026-10-17)
- Type: slice
- Requirements: SH-CC-10, SH-FR-38, SH-FR-161 (removal), SH-CC-16, SH-BR-16 (row D), SH-DOC-08, SH-AC-38 (static half)
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: L1
- Depends on: T-19 merged; prepare after step 6 (before step 8)
- Files owned (may modify): `nas-de-int-wahlberger-dev/roles/homepage/**`, `ops-de-wahlberger-dev/inventories/production/group_vars/all/vars.yml` (flag only), `renovate.json` (remove the `<vm-dir>` rule only)    Must not touch: pi dir, README files (T-25)
- Context: The NAS dashboard group "Pi (pi.de.int.wahlberger.dev)" becomes `ops.de.wahlberger.dev`; `homepage_semaphore_url` unchanged. Merged at step 8 together with T-25.
- Acceptance criteria (verifiable):
  - [ ] Rendered `services.yaml` in the NAS render check shows the group named `ops.de.wahlberger.dev` and no `pi` text; `homepage_semaphore_url` unchanged; role README/defaults/argument_specs consistent
  - [ ] `semaphore_dns_cutover_enabled: true` and `cloudflare_dns_cnames_enabled` follows it; `renovate.json` no longer contains the `<vm-dir>` rule but still contains the Pi rule (E removes it)
  - [ ] `tests/pr-boundaries.sh D` PASS; NAS `molecule test`, `tests/render-check.sh`, lint PASS
- Verification: commands above in `nas-de-int-wahlberger-dev` and `ops-de-wahlberger-dev`
- Gate: host    Risk/notes: Cosmetic NAS change; safe if the Pi still applies it before it is stopped.

#### T-25 — PR D docs: root README (ops row), architecture update, CI comments          [~] partial (ops row added in root README in #40; Pi row still says "Semaphore UI… Retires at PR E" (T-27); architecture update and CI comments not verified)
- Type: docs
- Requirements: SH-DOC-01, SH-DOC-12, SH-DOC-14, SH-FR-114, SH-BR-16 (row D docs)
- Agent: docs-writer    Priority: P1    Size: S    Parallel group: -
- Depends on: T-24; OP-08 pre-evidence (`podman exec semaphore ansible --version` on the VM) for the CI pin note
- Files owned (may modify): `README.md` (root), `architecture/ai-incident-remediation-pipeline.md`, `.github/workflows/ci.yml` (comments only)    Must not touch: Pi row of root README (T-27), code
- Context: Docs that hold at the end of step 8.
- Acceptance criteria (verifiable):
  - [ ] Root README playbooks table has a row for `ops-de-wahlberger-dev` (Hetzner CX23, Tumbleweed, Semaphore, UI over ZeroTier only, key-only public SSH); "Automated runs" names it with the reasons and the `cd` example
  - [ ] `architecture/ai-incident-remediation-pipeline.md` "Current state", diagram and "Trade-offs" name Semaphore on `ops-de-wahlberger-dev`; "pi ruled out because it holds the master keys" applies to the VM, which also has public SSH (SH-R-01); "Shared fate" says Semaphore depends on ZeroTier and Hetzner
  - [ ] `ci.yml` comments reference `ops-de-wahlberger-dev`'s `semaphore` role and the re-confirmed ansible-core pin; `git diff -- .github` contains only comment lines
- Verification: `git diff --stat`; `git diff -U0 -- .github/workflows/ci.yml | grep '^[+-][^+-]' | grep -v '^[+-][[:space:]]*#'` prints nothing
- Gate: host    Risk/notes: Pi row stays until PR E (DOC-02).

#### T-26 — PR E code: revoke old key, remove `pi-de-int-wahlberger-dev/`, drop the Pi Renovate rule          [ ] todo
- Type: slice
- Requirements: SH-FR-109, SH-FR-110, SH-FR-60/61 (list side), SH-FR-62, SH-FR-111, SH-FR-160 (removal), SH-FR-105 (nothing deletes frozen repos), SH-CC-05, SH-CC-11, SH-BR-08, SH-BR-10 (last row), SH-NFR-01, SH-BR-16 (row E), SH-AC-43 (code half)
- Agent: ansible-doctor    Priority: P1    Size: S    Parallel group: -
- Depends on: OP-07 done (PA-15), T-23 merged, T-24 merged; start the branch only after step 7 ends
- Files owned (may modify): `pi-de-int-wahlberger-dev/**` (delete), `nas-de-int-wahlberger-dev/inventories/production/group_vars/all/vars.yml`, `cloud-wahlberger-dev/inventories/production/group_vars/all/vars.yml` (key lists), `renovate.json` (Pi rule), `.github/workflows/ci.yml` only if it names the Pi dir    Must not touch: `ops-de-wahlberger-dev` lists (unchanged per FR-110), docs (T-27)
- Context: Merged only after the point of no return (OP-09 9.3), so no rollback depends on it.
- Acceptance criteria (verifiable):
  - [ ] Old key moved from `ssh_authorized_keys_list` to `ssh_authorized_keys_revoked` in nas and cloud; both lists then equal BR-10 "after 9.4" row (personal + new key); `<vm-dir>` lists unchanged
  - [ ] `pi-de-int-wahlberger-dev/` does not exist; `renovate.json` contains neither the SH-FR-160 nor the SH-FR-161 rule; no workflow still names the Pi dir
  - [ ] `tests/pr-boundaries.sh E` (with `STEP7_DONE=1`) PASS; Molecule in nas and cloud PASS with the revoked list non-empty (second converge 0 changed)
- Verification: `git grep -n -e 'pi\.de\.int\.wahlberger\.dev' -e 'pi-de-int-wahlberger-dev'` matches only paths allowed by FR-111 after T-27 lands; `tests/static-checks.sh`
- Gate: host    Risk/notes: The old key is revoked only here (BR-08). The old public key line is copied from the existing list, not from any other source.

#### T-27 — PR E docs: Pi row removal, DOC-09/10/11/13, FR-111 allowlist check          [ ] todo
- Type: docs
- Requirements: SH-DOC-02, SH-DOC-09, SH-DOC-10, SH-DOC-11, SH-DOC-13, SH-FR-111, SH-FR-112, SH-FR-114, SH-AC-43 (docs half)
- Agent: docs-writer    Priority: P1    Size: M    Parallel group: -
- Depends on: T-26
- Files owned (may modify): `README.md` (root, Pi row), `nas-de-int-wahlberger-dev/{README.md,CLAUDE.md,roles/security/{README.md,defaults/main.yml,tasks/main.yml comments},roles/ssh_authorized_keys/README.md,inventories/.../vars.yml comments}`, `cloud-wahlberger-dev/{CLAUDE.md,site.yml comment,vars.yml comments,vault.yml.example,roles/{restic_backup,zerotier,beszel_hub,uptime_kuma,cloudflare_dns,ssh_authorized_keys}/README.md}`, `homelab-architecture/forgejo-runner-placement.md` (dated note)    Must not touch: executable code beyond comments
- Context: Docs that hold at the end of step 9 (DOC-09 NAS README restore from the detached drive via a local repository path, no rest-server).
- Acceptance criteria (verifiable):
  - [ ] `git grep -n -e 'pi\.de\.int\.wahlberger\.dev' -e 'pi-de-int-wahlberger-dev'` matches only the FR-111 allowlist (`*/reqs/*`, `*/PLAN*.md`, dated notes in `architecture/` or `homelab-architecture/`, NAS README DOC-O5, the runbook section of `<vm-dir>/README.md`)
  - [ ] NAS README DOC-O5 gives a restore from the frozen `nas` repository using `restic -r /path/to/restic-repos/nas ...` (local path), with no rest-server
  - [ ] DOC-10/11: NAS and cloud text names `ops-de-wahlberger-dev` as the Semaphore host, states the BR-10 key-list rule and the revoked-keys input; cloud's `restic_backup` row no longer says Pi; the code diff is comments/docs only
  - [ ] DOC-13: a dated update note below "Context" in `forgejo-runner-placement.md`; the verified 2026-10-01 context text is unchanged
- Verification: the `git grep` above; `git diff -U0` shows no non-comment code change
- Gate: host    Risk/notes: NAS CLAUDE.md edits must not touch `reqs/` (D-11).

### Operator checklist (Erik; live systems; runbook = `<vm-dir>/README.md` from T-17)

Rule for every apply below: run `--check --diff` first, read it, then apply (workflow section 8). Agent assist = a T-nn task may prepare files; the OP item is not an agent task. Gate ids are from the (amended) step-gate table. Rollbacks are the spec's per-step rollbacks, copied into the README.

- [ ] OP-00a Before T-12: create the 1Password item `Ansible Vault - ops-de-wahlberger-dev` (password) and unlock 1Password for T-12/T-20.
- [ ] OP-00b Step 0 prepare. FR-163 (key protection), FR-164 (Hetzner 2FA), FR-165 (Central 2FA): AC-59. FR-180: Pi `config.json` hash vs Pi Vault: AC-52. Generate the new key (FR-56) and hand the public half to T-23. Save Central's current rule set text (FR-33) for T-19. Record the Beszel systems and Uptime Kuma monitors that are up (PA-7 baseline for FR-197/198). Read, do not change, Pi facts (FR-200). Hand the Pi image tag to the roles (A-02: `podman inspect`).
- [ ] OP-00c Merge PR A (T-19) after reviewing nas/cloud no-op evidence. Gate step 0: AC-01, 17, 27, 30, 44, 45, 52, 56, 59, 60. Rollback: revert PR A.
- [ ] OP-01 Step 1 provision (FR-01..04, 115, 122, 133, 162 clock start): `hcloud` CX23, nbg1/fsn1, Tumbleweed, public IPv4 only, personal key, Cloud Firewall of D-15 attached at creation, `erikwahlberger` with sudo and locked password (cloud-init or root). Check price (NFR-02, A-16, A-27). Gate: AC-02. Rollback: delete server and firewall.
- [ ] OP-02 Step 2 bootstrap within 60 min (FR-162, PA-10): `site.yml --tags common,notify_failure,disk_space,ssh_authorized_keys,security,reboot_notify,firewall,podman,zerotier -e ansible_host=<vm-public-ip>`, `--check --diff` first within a 10 min budget. Check A-08 (`ausearch -m avc`). Gate: AC-05, AC-49, AC-62 (two separate runs, `--tags cloudflare_dns` and `--tags caddy`, plus the firewall skip message). Over 60 min: delete the server, repeat step 1 (E-46). Record unapplied sshd directives and snapper result for A3. Optional OP-02a: run T-16 (fixture) yourself if the agent cannot.
- [ ] OP-03 Step 3: in Central authorize the member, fix `<vm-zt-ip>`, read `vm_zt_iface`, write the flow rules (FR-132); read `id -u` of the Semaphore process on the Pi (read-only, PA-1). Hand values to T-22 and merge PR A2. Run `site.yml --skip-tags semaphore,restic_backup -e ansible_host=<vm-zt-ip>` (`--check --diff` first). Add the VM to Beszel. Tests: AC-04, 08, 09, 10, 11, 12, 13, 14, 19, 46, 47, 51, 63 (AC-50 stays in the step-5 gate, per spec). If AC-51 or AC-04 fails: switch to the fallback with `-e vm_proxy_design=bridge_fallback`, repeat AC-51 and the non-zone AC-04 clauses, then AC-61. If AC-51 fails in the fallback: STOP, run the step-3 rollback (PA-5). Hand results to T-22 and merge A3. Rollback: restore the saved "before" rule set, deauthorize, delete server, delete both Cloudflare A records by hand.
- [ ] OP-04 Step 4 migrate DB: optional snapshot (FR-102, AC-34, 30-day deadline FR-170); check BR-13; take the step-4 record (`tools/step4-record.py`) and compare image tags (AC-18); stop the Pi cleanly, copy DB + companions, restart (<=10 min); `tools/db-prepare.sh`; place on the VM with owner `semaphore_uid` and mode 0600; `--tags semaphore` (`--check --diff` first). Open draft PR C with migration notes (T-23). Tests in this order (PA-2): AC-20 (counts + newest migrated task id, `tools/compare-record.py`) before AC-22, then AC-03 (`--permanent` clause), 07, 15, 16, 18, 21, 22, 53, 54, 58 (+ PA-7 TCP monitor, FR-91 monitor); AC-34 if snapshot; AC-55 last (delete the workstation copy). Rollback: stop the VM's Semaphore, delete its DB; E-36 if the Pi will not restart.
- [ ] OP-05 Step 5 backups: merge PR B (T-20), apply NAS `--tags restic_server`; apply VM `--tags restic_backup`, start one backup (repository created); merge PR B2 (T-21), apply NAS `--tags restic_server,backup_disk`, start one maintenance run, restore test. Store `vault_restic_backup_repo_password` in 1Password (FR-88). Gate: AC-06, 31, 32, 33, 50. Rollback: disable the VM timer, revert B2 and B, delete the `ops` `.htpasswd` line by hand.
- [ ] OP-06 Step 6: merge PR C (T-23); apply `--tags ssh_authorized_keys` to nas, cloud and the VM from the workstation (`--check --diff` first); add the new key as a second Key Store entry; switch nas and cloud templates; create the `<vm-dir>` project/template with `--skip-tags semaphore,zerotier -e common_upgrade=false`; delete the Pi project, API tokens, integrations and the deletion-list items; run the FR-178 scan; AC-48 plus the PA-3 additions (cloud login with the new key, `<vm-dir>` self-run login); FR-191 address check, then PR C2 if needed; delete the workstation key (FR-58). Gate: AC-23, 24, 25, 48. Rollback per spec with PR C-R (T-23); retry rule PA-9.
- [ ] OP-07 Step 7 full run (BR-02 slot): nas, cloud, `<vm-dir>` templates. Gate: AC-26, 36, 37 (NFR-08, 10, 11). Then T-26/T-27 may start.
- [~] OP-08 Step 8 cut-over within 72 h (BR-15) — repo side merged (PR D, #40, 2026-10-17); live status: DNS cut-over done (CNAME → ops); Pi was NOT put in stopped standby until 2026-10-19 (its Semaphore had run since 2026-10-19 03:00 with no schedules and no tasks since 2026-10-01); Pi stopped/disabled 2026-10-19; Uptime Kuma TCP monitor for `ops` and the Pi-monitor removal: not verified (see status below). Original text: optional snapshot; BR-13/BR-14 checks; read the Pi's active schedules; merge PR D (T-24, T-25); apply `<vm-dir> --tags cloudflare_dns` (`--check --diff` verifies A-06) and NAS `--tags homepage`; wait 300 s; Pi to stopped standby; activate schedules per FR-101 (list excluded ones in the PR D description); add the Uptime Kuma TCP monitor for `<vm-fqdn>:22` (FR-92). Gate: AC-35, 38 (+34). Rollback per spec.
- [ ] OP-W Stabilization window (>=14 days; NOT waited — Pi retirement started 2026-10-19, about 9 days after the 2026-10-10 plan and 2 days after PR D; the VM's clean-backup and 14-day preconditions of BR-05 are unverified): AC-28, AC-29, AC-39; NFR-09 (day 30), NFR-13; 30-day snapshot deadline.
- [~] OP-09 Step 9 (order D-20, BR-17) — partially done 2026-10-19 outside the runbook order, see "Pi retirement status" below. Original text: 9.1 evidence for BR-05 a)..j) (AC-40, noted in the PR E description); 9.2 remove the Pi from Beszel and Uptime Kuma; 9.3 first action = point of no return, log every command to the step-9.3 log (shred -n 1 on the FR-173 files, delete `/mnt/data/containers/semaphore`, old-key Key Store entry, shutdown, detach drive, erase and re-image SD, delete the Cloudflare A record `pi.de.int...`), gate AC-41; 9.4 merge PR E (T-26, T-27), apply `--tags ssh_authorized_keys` to nas, cloud, VM (`--check --diff` first), gate AC-42, AC-43; 9.5 archive the Pi's 1Password item, delete all VM snapshots, gate AC-57. Rollback: step-8 rollback until the first 9.3 action; none afterwards (NFR-07 recovery).

### Pi retirement status (2026-10-19, performed on the live Pi and verified by read-only checks)

Done:
- Pre-check (read-only): Pi reachable; `semaphore`, `caddy`, `restic-server`, `beszel-agent` active; Semaphore DB had no schedules and no tasks since 2026-10-01 (table `task`, latest `created` 2026-10-01).
- Stopped and disabled: `semaphore.service`, `caddy.service`, `restic-server.service`, `beszel-agent.service` (`systemctl disable --now`).
- Quadlet units removed from `/etc/containers/systemd/`: `semaphore.container`, `caddy.container`, `caddy.network`, `restic-server.container`; `daemon-reload` run; `semaphore.service` failed state cleared. No containers remain (`podman ps -a` empty).
- Secrets shredded (`shred -n 1 -u`): `containers/semaphore/data/database.sqlite{,-wal,-shm}`, `containers/semaphore/config.json`, `containers/semaphore/semaphore.env`, `containers/caddy/caddy.env` (Cloudflare token copy).
- Service data removed: `/mnt/data/containers/semaphore` and `/mnt/data/containers/caddy` (incl. the Caddy ACME account key and certificate private keys). Not shredded individually (plain `rm -rf`); the drive's other contents were kept.
- Retired key removed from the Pi's `~/.ssh/authorized_keys`: `semaphore-automation@pi.de.int.wahlberger.dev` (SHA256 `jgza9UYt…`). Remaining keys: `erikwahlberger@personal`, `erik@LTGEMEA-18858`.
- Firewall (ufw): removed `80/tcp`, `443/tcp`, `45876/tcp`, `8000/tcp` (from 10.10.0.0/16). Remaining: `22/tcp` (v4+v6) and the Podman DNS rules on `podman+`.
- The Pi's own repo state is unchanged (`pi-de-int-wahlberger-dev/` still exists, `site.yml` still defines the old services; do not apply it).

Not done (still open, each needed for full runbook compliance):
- 9.1 preconditions (BR-05 a–j), including the 14-day wait and the 7 nightly VM backups; not verified.
- 9.2 remove the Pi from the Beszel hub (on cloud) and remove its Uptime Kuma monitors. Not done; the hub still lists the Pi as a system (not verified from the repo).
- 9.3 remaining items: detach the USB drive and store it offline (drive still attached to the Pi); erase and re-image the SD card (not done; OS kept on purpose for embedded use); shut down (not done); delete Cloudflare A record `pi.de.int.wahlberger.dev` (not done, harmless to keep).
- Old key still authorized on nas and cloud until PR E (T-26) revokes it. The key's private half is destroyed on the Pi, so it is no longer usable from there.
- PR E (T-26, T-27) not started; `pi-de-int-wahlberger-dev/` removal, Renovate rule `renovate.json:89`, root `README.md` Pi row still present.
- `ops`'s Uptime Kuma TCP monitor (FR-92, OP-08) not verified.

Deviations from the runbook: the Pi kept running Semaphore after the cut-over until 2026-10-19 (it was not put in stopped standby at step 8); the 14-day stabilization (OP-W) and 9.1 preconditions were skipped; the caddy data directory (ACME account and certificate keys) was removed in addition to the runbook's 9.3 list; the firewall and SSH-key cleanup was not part of the runbook.

### Traceability

Gate/AC coverage: 63/63 scenarios mapped (11 [S] through T-14; the rest are operator gates). Requirement coverage: 100% of the SH-FR/BR/NFR/CC/DOC groups below.

| Requirement | Tasks | Verified by (test/procedure) |
|---|---|---|
| FR-01..04, 115, 122 | OP-01 (+T-17 documents, T-05 for FR-122 baseline) | AC-02 |
| FR-06, 07, 130, NFR-03 | T-07, T-08, T-09, T-16 | OP-03/04: AC-03, AC-51 |
| FR-08, 09, 128, 185 | T-07, T-16 | AC-04, AC-09, AC-11, AC-12 |
| FR-10, 135..143, 11 | T-02, T-12, T-15 | AC-01 (CI + `tests/static-checks.sh`) |
| FR-12, 13, 143 | T-02 | AC-01 (Molecule, site.yml check) |
| FR-14..19, 116..120, 121, 157..159, 188, NFR-14 | T-05 | Molecule + guard (AC-45, AC-56), OP-02 AC-05 |
| FR-20, 22, 23, 24, 25 | T-02 (copies), T-06 (FR-25), T-12 (thresholds), T-09 (FR-23 `/etc/hosts`) | AC-05, AC-06, AC-07, AC-08 |
| FR-21, 144, 145, 206 | T-05, T-06, T-08, T-09, T-11 (units), T-02 (zerotier, beszel copies) | `tests/static-checks.sh` OnFailure grep; OP-05 AC-06 |
| FR-26, 27, 28, 29, 205 | T-02 (zerotier copy), OP-03; T-14 (FR-205 grep) | AC-09, AC-10 |
| FR-30..35, 132, 197..199, 33, 34 | OP-03, T-17 (README, doc skeleton), T-19 ("before"), T-22 ("in force") | AC-11, 12, 13, 50, 63 |
| FR-36, 131, 37, 38, 193 (cloudflare_dns) | T-10, OP-03, OP-08 | guard test; AC-14, AC-38, AC-62 |
| FR-39, 40, 129, 183, 184, 186, 187, 196, 193 (caddy) | T-08, T-09 (FR-186 side), T-16 | render tests; AC-15, 51, 61, 62 |
| FR-41, 55 | T-09 | OP-04 AC-16 |
| FR-42..46, 146..148, 201, 202 | T-12 (values), OP-04 (FR-47, 48, 202) | AC-17 (hash), AC-21 |
| FR-47, 48 | OP-04 | AC-21 |
| FR-49, 50, 175, 176, 203, 204 | T-13 (tools), OP-04 | AC-18 |
| FR-51, 53, 54, 177, 178, 179 | T-13, T-23 (notes), OP-04, OP-06 | AC-20, 22, 25, 54 |
| FR-52 | T-09 | guard test; AC-19 |
| FR-127, 166..169, 207, 208, 172 | T-09, T-12, OP-04 | render; AC-53, AC-55 |
| FR-56, 57, 58, 59, 181, 182 | OP-00b, OP-06, OP-09 | AC-24, AC-41 |
| FR-60, 190 | T-04 | AC-44 |
| FR-61, 110, 156 | T-26, OP-09 | AC-42 |
| FR-62 | T-02, T-04, T-12, T-14, T-19, T-23, T-26 | AC-01, AC-23, AC-43 |
| FR-126, 191 | T-23, T-13 (`check-from-list.sh`), OP-06 | AC-23, AC-48 |
| FR-163, 164, 165 | OP-00b | AC-59 |
| FR-63..65, 149, 150 | OP-06 (+T-17 documents) | AC-25 |
| FR-66..69, 70 | T-05 (reload), T-07 (no reload), T-06, T-09, T-17, OP-07 | AC-26, AC-27, AC-56 |
| FR-71..76, 195, NFR-13 | T-06, T-08, T-09 (restart), OP-W | AC-28, AC-29 |
| FR-72, 83 | T-06, T-11 | AC-06 |
| FR-77, 78, 80, 81, 82, 152, 151, 171, BR-11 | T-11 | AC-30 (static), AC-31 (OP-05) |
| FR-84, BR-09 | T-12, T-20 | AC-31, AC-32 |
| FR-85, 86, 87, 153..155 | T-21 | pytest + AC-32 |
| FR-88, 89, 90 | OP-05, T-17 | AC-33, AC-27 |
| FR-91..95 | OP-04 (91), OP-08 (92), OP-03/08 (93), OP-09 (94, 95) | AC-58, AC-35, AC-41 |
| FR-96, 114 | T-17, T-25, T-27 | AC-27, AC-43 |
| FR-97, 200 | T-14 (`pr-boundaries.sh`, git log), PA-15, OP-04..07 | AC-36 |
| FR-98, 99, 101, 100, 102, 103, 170, 209 | OP-07, OP-08, OP-W, OP-09 | AC-37, 38, 39, 34, 40, 57 |
| FR-104..108, 173, 174, 113 | OP-09 | AC-41, AC-57 |
| FR-105 | OP-09 (never delete) + T-26 | AC-41 |
| FR-109, 111, 112 | T-26, T-27 | AC-43 |
| FR-133, 134 | T-17 | AC-27 |
| FR-123, 124, 125, NFR-15 | T-05, T-16, OP-03 | AC-46, AC-47 |
| FR-160, 161 | T-19, T-24, T-26 | AC-60, AC-38, AC-43 |
| FR-162 | OP-01, OP-02 | AC-49 |
| FR-192, 194 | T-22, T-07 | AC-63, AC-62 |
| BR-01..04, 12, 13, 14, 15, 17 | T-17 (runbook), OP-04..09 | AC-36..38, AC-27, AC-41 |
| BR-05, 07, 08 | OP-09 / OP-08 / T-26 | AC-40, AC-38, AC-42 |
| BR-06 | OP-03 (+T-17 matrix in README, T-19 doc) | AC-11, AC-12 |
| BR-10 | T-23, T-26, T-14 | AC-23, AC-39, AC-42 |
| BR-16 | T-14 (`pr-boundaries.sh`), T-19, T-20..T-27 | AC-36, AC-63 |
| NFR-01 | T-26, T-27 | AC-43 |
| NFR-02, 09 | OP-01, OP-W | inspection (no scenario, as in the spec) |
| NFR-03, 14, 15 | T-05, T-07, T-08, OP-03/04 | AC-03, AC-05, AC-46 |
| NFR-04, 12 | OP-08 | AC-35, AC-38 |
| NFR-05, 07 | T-11 (schedule), T-17 (README timed recovery) | analysis (as in the spec) |
| NFR-06, 08, 10, 11 | T-11 (design), OP-05, OP-07 | AC-31, AC-37 |
| CC-01, 03 | T-21 | AC-32 |
| CC-02 | T-20 | AC-31, AC-32 |
| CC-04 | T-04 | AC-44 |
| CC-05 | T-23, T-26 | AC-23, AC-42 |
| CC-06 | T-11 | render diff (cloud) |
| CC-07, 08, 09, 14, 15 | T-09, T-10, T-08, T-05/T-06, T-07 | per role tests above |
| CC-10 | T-24 | render test; AC-38 |
| CC-11 | OP-08, OP-09, T-26 | AC-41, AC-43 |
| CC-12 | OP-00..OP-09 (out-of-repo list) | the OP gates |
| CC-13 | OP-06 | AC-24 |
| CC-16 | T-19, T-24, T-26 | AC-60, AC-38, AC-43 |
| DOC-01 | T-25 | AC-43 |
| DOC-02, 09, 10, 11, 13 | T-27 | AC-43 |
| DOC-03, 04, 06 | T-17 (+T-19 "before", T-22 "in force") | AC-27, AC-13 |
| DOC-05 | T-04..T-11 (role READMEs) | `tests/static-checks.sh` (README per role) |
| DOC-07 | T-20, T-21 | AC-32 |
| DOC-08 | T-24 | render test |
| DOC-12, 14 | T-25 | git diff checks |
| DOC-15 | T-01 (updates), T-19 (check) | file present |
| Assumptions A-26, 33, 09, 31, 32 | T-03 | spike notes |
| Assumptions A-20, 21, 22, 30 (offline part) | T-16 | `RESULTS.md` (simulator) |
| Assumptions A-02, 05, 06, 08, 19, 27, 28, 29, A-34 | OP-00b, OP-02, OP-03, OP-08 (A-34: T-19 dry-run or OP-00) | their named scenarios |
| Error cases | E-01: T-09; E-12: T-10 + OP-08; E-30: T-05; E-33/34: T-08 + OP-03; E-40: T-04; E-44: T-19; E-46: OP-02; the rest are operator-observed in the OP gates | as listed |

Scenario map (all 63): AC-01 T-02/T-14; AC-02 OP-01; AC-03 OP-04; AC-04 OP-03; AC-05 OP-02; AC-06 OP-05; AC-07 OP-04; AC-08 OP-03; AC-09 OP-03; AC-10 OP-03; AC-11/12/13 OP-03; AC-14 OP-03; AC-15/16 OP-04; AC-17 T-12/OP-00c; AC-18 OP-04; AC-19 T-09/OP-03; AC-20/21/22 OP-04; AC-23 T-23/T-14; AC-24/25 OP-06; AC-26 OP-07; AC-27 T-17/T-14; AC-28/29 OP-W; AC-30 T-11/T-14; AC-31/32/33 OP-05; AC-34 OP-04/08; AC-35 OP-08; AC-36/37 OP-07; AC-38 OP-08; AC-39 OP-W; AC-40/41/42 OP-09; AC-43 T-26/T-27; AC-44 T-04; AC-45 T-05; AC-46/47 OP-03; AC-48 OP-06; AC-49 OP-02; AC-50 OP-05; AC-51 OP-03; AC-52 OP-00b; AC-53/54/55 OP-04; AC-56 T-05/T-07; AC-57 OP-09; AC-58 OP-04; AC-59 OP-00b; AC-60 T-19/OP-00c; AC-61 T-22/OP-03; AC-62 T-07/T-08/T-10/OP-02; AC-63 T-22.

### Task status log   (orchestrator updates checkboxes; never delete history)
- 2026-10-10: plan created (27 tasks, 13 operator items OP-00a..OP-09). No task started.
- 2026-10-19: Pi retirement performed (see "Pi retirement status"): services stopped and disabled, Quadlets removed, Semaphore/Caddy secrets and service data deleted, retired SSH key and ports removed. Pi is usable for other work. OP-09 partially done; PR E and the Beszel/Uptime Kuma/drive/SD steps remain.
- 2026-10-19: status reconciled against `master` and live DNS (see "Reality check" above). T-20, T-21, T-22, T-23, T-24 marked done (merged). T-25 partial. T-11 CC-06: cloud `restic_backup_rest_server_host` now `nas.de.int.wahlberger.dev` on master (the earlier permission-denied edit is resolved). PR D cut-over merged 2026-10-17; `semaphore.de.int` CNAME resolves to ops. T-26, T-27 (PR E) not started. Operator items OP-00c to OP-08: repo side merged, live execution not verifiable from the repo, Erik to confirm.

### Carry-over notes (orchestrator, from implementer reports)
- T-02: `podman` role asserts `podman_data_dir` is a mountpoint; on the VM `/opt/podman` is not -> needs a fix (owner: T-09 or T-12; unassigned). `semaphore_network_subnet` placeholder 172.29.30.0/24 and `cloud_zt_ip` var name need confirming in T-12. CI jobs (validate, molecule, vault-encrypted) not yet run (needs a push).
- T-03: A-26 holds (whole `from="..." ssh-ed25519 ...` line, no key_options needed). `default_bind` makes Caddy fail if the ZT IP is absent -> T-08 orders the Quadlet after ZeroTier; NAS Caddyfile lacks `admin off`. Newest task id = max over each project's `/tasks`, not `/api/tasks`; schedules per project; Semaphore image runs uid 1001, DB files 1001:0 0644 (role must set 0600/0700).
- T-07: new zone is permanent-only on the creating run (no reload allowed, AC-56); T-17 must put the exact `firewall-cmd --reload`-equivalent in the step-3 README before AC-04. `firewall_public_removed_services` includes `dhcpv6-client` -> confirm on the T-16 fixture. T-12 must add `firewall_cloud_zt_ip: "{{ cloud_zt_ip }}"` and the real cloud ZT IP. Guard-test format: each `tests/guards.d/<role>*.yml` is a standalone playbook (`ansible-playbook -i localhost, ...`), exit 0 = pass -> T-14 wrapper only runs them. Guard tests use stubs, not real firewalld/Cloudflare.
- T-10: no `no_log` on the Cloudflare tasks on purpose (SH-E-12 needs the error text); test asserts the token never appears.
- QA(T-07/10/11): CONDITIONAL, no FAIL. Open: (F-1) `restic_backup_sqlite_required: true` mails a failure daily until step 4 -> T-12/T-17 decide toggle (set false in PR A, true at step 4). (F-3) public-zone "ssh only" relies on a deny-list incl. dhcpv6-client -> assert the final zone service list (T-16/OP-03). (F-4) null `vm_zt_iface` gives opaque error; (F-5) guard regex accepts trailing newline; (TI-1) firewall guard grep should be `reload|restart`; (TI-2) AC-62 skip message only half-asserted (`vm_zt_iface` matched in task name); (TI-4) restic env-file mode 0600 and forget-refusal untested at task level; (F-7) restic URL does not URL-encode the REST password -> generate URL-safe password (T-12). Fixes for F-4/F-5/TI-1/TI-2 queued as a small T-07 polish.
- T-11 CC-06: cloud/roles/restic_backup default host pi->nas edit was denied by the permission classifier; waiting on Erik (do not retry silently).
- QA(T-05): CONDITIONAL, 8 pass/0 fail, mutation 10/10 killed. Open: (F-1, medium, real defect) creating /etc/ssh/sshd_config shadows vendor /usr/etc/ssh/sshd_config -> drops `Subsystem sftp`, AcceptEnv, PrintMotd; fix = seed from /usr/etc when missing or add Subsystem line; confirm `sshd -T | grep subsystem` on the VM in T-16/OP-02. (F-2) OpenSSH 10 PerSourcePenalties drops the 5th rapid attempt, so the AC-46 procedure must space attempts ~6 s apart (T-17 runbook). (F-3) `--check` on a fresh host fails at enable/start of fail2ban/ssh-login-notify (and disk_space timer in the T-02 copy) -> add check-mode guards (security role now; disk_space copy via T-06/T-12) since OP-02 runs --check first. (F-4) lineinfile edits last match, could land in a Match block on a base file with one -> AC-05 `sshd -T` catches it. AC-56 literal grep: PASS (the `restarted` hit is the ssh-login-notify handler; a T-14 static check must scope its grep to the sshd handler). FR-124 full ignoreip list = T-12 + add a check.
- T-04 (implementer): ssh_authorized_keys revoked-list + both-lists failure done in ops, nas, cloud (10 edits, none denied; ops/nas roles byte-identical, cloud differs only in meta platforms). OPEN: (1) full ops Molecule is blocked by image drift: `common` zypper install of snapper fails (`busybox-diffutils` conflicts with `diffutils`) - fix in `common` (owner: T-12/T-02 follow-up; likely affects nas/cloud-common Molecule too); (2) nas/cloud molecule verify have no T-04 assertions - add by copying ops verify-ssh-keys.yml; (3) T-12 keeps the retired Semaphore key in `ssh_authorized_keys_revoked` after applying (BR-10); (4) verify uses include_role + mtime/checksum for idempotence.
- T-08 (implementer): caddy primary (host network, default_bind vm_zt_ip, admin off, no :80, remote_ip 403) and bridge fallback done; T-07 polish (F-4, F-5, TI-1, TI-2) done. OPEN: (1) `tests/render-check.sh -e caddy_design=bridge_fallback` fails in the container stage (`.network` items not copied into the generator input) -> fix in tests/lib/container-verify.sh (T-14); (2) fallback Quadlet is `kind: text` in the default run, so its systemd-analyze verify evidence is from one earlier run only; (3) `roles/security/tasks/updates.yml:28` line >160 chars (T-06); (4) full caddy role run (podman build, handlers, idempotence) and AC-51 real client address are unverified (T-16/OP); (5) removed caddy_http_port/caddy_https_port, caddy_data_dir default now /opt/podman/caddy, RestartSec=10, After/Wants zerotier.service, fallback omits default_bind and remaps loopback upstreams to caddy_upstream_fallback. SLIP: the T-08 runtime check ran Caddy with a dummy token without `--network none`; it contacted Let's Encrypt and attempted DNS-01 (possible Cloudflare API call with an invalid dummy token, possible ACME account creation from Erik's IP). No real credentials involved.
- T-13 (implementer): tools in ops-de-wahlberger-dev/tools, 86 tests, 25/26 mutants killed; Python 3.9 stdlib only (system python), env vars SEMAPHORE_USER/SEMAPHORE_PASSWORD, VAULT_PI/VAULT_VM(+_PASS_FILE), VM_PUBLIC_IP; check-from-list exits 2 until vm_zt_ip is set (T-12).
- T-09 (implementer): semaphore role done (modes: config.json uid:root 0600, data/ 0700, DB 0600, env 0600 root; both designs; to_json config; admin creation idempotent+no_log). Cross-task fixes needed (assigned to follow-up task T-02b): (1) roles/container handler `Restart the container service` needs `when: not ansible_check_mode` (else `--check` on a fresh VM fails; the only failing T-09 guard case); (2) roles/podman: add `podman_require_mountpoint` (default true) gating the mountpoint assert, set false in VM vars.yml (T-12); (3) tests/lib/container-verify.sh: map `.network` items to `<name>-network.service` so `render-check.sh -e caddy_design/semaphore_design=bridge_fallback` works and the fallback render items can be kind `quadlet`. Guard image `geerlingguy/docker-debian13-ansible` must be pullable in CI (T-14/T-15). New input semaphore_oidc_provider_url default https://id.wahlberger.dev. Incident: first --syntax-check omitted ANSIBLE_VAULT_PASSWORD_FILE and ran .vault_pass.sh once (exit 1, no secret).
- T-02b (follow-up, implemented, not QA'd yet): container handler skipped in check mode; podman_require_mountpoint (default true; VM vars set false; assert moved to tasks/verify_mount.yml; tests/guards.d/podman.yml 3 cases); container-verify.sh maps .network items; caddy/semaphore fallback render items now kind quadlet. Both `render-check.sh` and `render-check.sh -e caddy_design=bridge_fallback -e semaphore_design=bridge_fallback` end `render-check: OK`. ansible-lint not run on these yet; the semaphore guard result rests on failed=0 (no before/after).
- T-06 (implementer, not QA'd yet): zypper-dup.service/timer (Sun 04:00 Europe/Berlin, SuccessExitStatus=102, OnFailure immediate), rebootmgr maint-window Sun 04:00/1h written to /etc/rebootmgr/rebootmgr.conf (D3: rebootmgr 4.0 ignores /etc/rebootmgr.conf -> NAS copy likely has an inert config; not touched, worth a separate look), reboot-request script (heads-up email first, then `rebootmgrctl reboot`, always exit 0), snapper pkgs + root config on btrfs, F-1 vendor sshd_config seeding (+ directive regexp now matches active lines only, early vendor Include removed on seeding run), F-3 check-mode guards (security, disk_space), `security_snapper_force_resolution` (true only in containers; works around busybox-diffutils conflict in the image - resolves the earlier `common`/snapper Molecule blocker for the security path only). Unverified: live rebootmgr window/overrun, real zypper dup exit 102/103, btrfs snapper pairs, real-host vendor sshd layout. R2: old request-reboot-if-needed.sh.j2 deleted (no other reference in this tree).
- QA(T-04/T-06/T-02b): CONDITIONAL, no functional FAIL; T-02b PASS. Full ops `molecule test` passes (common/snapper conflict gone: snapper moved to security/updates.yml with container-only force_resolution); nas molecule PASS; cloud molecule PASS only with Galaxy prerun disabled (env TLS error ASN1 NOT_ENOUGH_DATA fetching geerlingguy.security - environment, not the change). Only the 8 ssh_authorized_keys files in nas/cloud are modified (+ untracked vars/). D3 confirmed (rebootmgr 4.0 reads /etc/rebootmgr/rebootmgr.conf, ignores /etc/rebootmgr.conf). Follow-ups queued (polish task T-06b): TI-1 (medium) ops verify-ssh-keys scenario 3 doesn't prove 'fails before any change' - seed an unrelated listed key C and assert it stays absent; BUG-1 zypper-dup-request-reboot.sh.j2 touches /var/run/reboot-notify-sent even when reboot-notify.sh fails -> touch only on success; BUG-2 stale comment in roles/security/handlers/main.yml (old rebootmgr.conf path); TI-4 verify-security 'old units gone' checks a path never created; TI-5 add a --check-on-fresh-host guard case (T-14); zypper exit 103 is not in SuccessExitStatus -> decide on fixture (T-16); nas/cloud molecule have no T-04 assertions (known). Unverified/live: overrun-past-05:00 queueing, real zypper dup exit 102/103, btrfs snapper pairs, real-host vendor sshd layout, real reboot-notify mail.
- QA(T-08/T-09, task-escalator run): PASS both. Minor: roles/semaphore/tasks/main.yml:11 `semaphore_uid | string is match('^[1-9][0-9]*$')` accepts "1001\n" -> use \A[1-9][0-9]*\Z + add a trailing-newline guard case (queued in T-06b-style polish). caddy.env mode is checked by a source-text regex, not a runtime read-back (acceptable). Stall cause: host overload (load ~166, ~30 stale ansible/render/mutation processes + leftover containers from earlier verifiers); fix = run long commands with nohup + log, one at a time, poll briefly. Load back to ~2, no leftover t09-/qa6- containers. render-check takes 4-5 min and uses network for package installs (openSUSE mirrors).
- QA(T-13): CONDITIONAL, 5/5 criteria PASS, mutation 12/13 killed (survivor = first wal_checkpoint, equivalent). Polish queue (T-13b): F-1 (medium, test reliability) Docker test `test_container_new_task_row_is_detected_as_newest_id_difference` flaked once under load (`POST /api/auth/login: timed out`, SemaphoreClient timeout=15 s, semaphore_record.py:~58) -> longer login timeout/retry or wait for the task to finish; F-2 db_prepare.py:~138 sqlite URI not URL-quoted (paths with ? or #) creates a stray empty file; F-3 corrupt copy WITH a -wal is not left byte-identical (unconditional wal_checkpoint(TRUNCATE) runs before integrity check) - decide: integrity-check a read-only copy first or document; F-4 vault_hash: catch yaml.YAMLError and re-raise VaultError without the message (plaintext line could reach stderr); F-5 flat parser mis-parses an unterminated single quote. All tools verified to run on stock macOS /usr/bin/python3 3.9.
- T-13b (python-engineer): F-1..F-5 fixed (timeouts 30/60 s configurable via SEMAPHORE_TIMEOUT/SEMAPHORE_LOGIN_TIMEOUT, one login retry on timeout, URI quoting, corrupt+WAL left byte-identical via scratch precheck, no YAML message leak, single-quote parsing); tests hermetic (empty ANSIBLE_CONFIG, tmp cwd, canary `op`). Orchestrator fix: tools/vault_hash.py `view_with_ansible_vault` cwd was vault.parents[3] (= inventories dir, no ansible.cfg) -> now parents[4] (= playbook dir) so the playbook's ansible.cfg/.vault_pass.sh applies as documented. INCIDENT: before the hermetic fix, pytest runs from the ops dir (implementer's several runs + one by the orchestrator) may have executed `.vault_pass.sh` -> `op read` of the real item; effect unknown (possible 1Password prompts). Rule: never run tests/tools or ansible-vault with cwd inside a playbook dir without ANSIBLE_CONFIG override.
- T-06b (implementer, not QA'd yet): 7 fixes done with scratch-copy mutations (semaphore_uid \A..\Z; reboot-notify marker only on success; handler comment; legacy-file assertion; verify-ssh-keys scenario 3 seeds key C; new guards tests/guards.d/security_check_mode.yml and restic_backup.yml; restic README flip procedure). T-12 line: `restic_backup_sqlite_required: false` in vars.yml next to `restic_backup_forget_enabled: false`, delete after step 4. security_check_mode guard needs network (zypper --dry-run) and the local molecule image (T-14/T-15 wiring).
- T-12 (implementer; secret part restructured to an operator-run tool): vars.yml production values set; vault.yml.example = 9 keys; tools/populate-vault.sh (+ vault-manifest.yml; 24+26 tests; 15/16 mutants killed) builds the VM's real vault.yml: 7 keys copied from the PI vault (access_key_encryption, cookie hash/encryption, admin password, OIDC client secret, Cloudflare DNS token, Resend key) + 2 generated alnum32 restic passwords; operator command: `ops-de-wahlberger-dev/tools/populate-vault.sh --replace-placeholder` then `tools/vault-hash-compare.sh <7 keys>`. Unverified: the Pi vault actually holds those key names (tool refuses naming any missing key). New var `cloud_public_ip: 49.13.141.178` taken from public DNS (dig cloud.wahlberger.dev) - Erik to confirm. `cloud_zt_ip` stays empty until OP-02. tests/guards.d/vm_vars.yml guards vars. Orchestrator fixed two stale render fixtures (restic.yml pins sqlite_required: true; updates.yml matches the new `if reboot-notify.sh; then` form).
- QA(T-06b/T-12 repo): CONDITIONAL. F-1 fixed by orchestrator (populate_vault json.dumps ensure_ascii=False; CLI catches VaultError). F-2: tools on stock /usr/bin/python3 use the fallback YAML parser (verify is parser-relative); operator should ALSO check the 7 copied keys with plain `ansible-vault view ... | sha256sum` per SH-AC-17. TI-1 (no test proves ANSIBLE_CONFIG isolation inside populate_vault), TI-2 (sshd check-mode tolerance not exercised), TI-3 (vm_vars semaphore_uid regex accepts newline) open/low. Molecule half of T-06b (reboot-notify cases, legacy-file check, key C) unverified (verifier not allowed to run Molecule).

### Carry-over: T-14 QA (2026-10-11, CONDITIONAL, ~45 mutations caught)
- Expected FAILs until owners land: SH-AC-01/27 (README, CLAUDE.md: T-17), SH-AC-60 (renovate rules: T-19), SH-AC-63 (docs/zerotier-flow-rules.md: T-19). Re-run static-checks.sh after T-17/T-19; all must be green before PR A.
- F1 low: AC-60 `covers()` ignores matchers other than matchFileNames (a narrowed Pi rule would pass).
- F2 low: pr-boundaries `docs_any='*.md'` too wide for B/B2/D/E (should be nas-only md for B/B2); E also allows ops vars.yml + ssh_authorized_keys roles not named in the row.
- F3 low: no scripted negative unit test for SH-AC-30r and the lint/syntax branches of SH-AC-01L.
- F4: the literal `git grep -e 'zerotier.*token'` of the plan matches prose in roles/zerotier/README.md:40 (cloud + ops copy) and the planning docs. Script scopes to code/config; amend AC wording or reword the README sentence.
- Observation: SH-AC-64 and SH-AC-66 (`guard-tests.sh semaphore`) not wired into the static gate.
- Tooling: yamllint=/opt/homebrew/bin/yamllint, ansible-lint/pytest via pipx run (shims in ~/Library/Python/3.11 are stale).

### Carry-over: T-17 QA (2026-10-11)
- Documented deviations from spec: `cloud_zt_ip` is set in PR A2 with `vm_zt_iface` (spec Inputs table says PR A; firewall role fails otherwise). `restic_backup_sqlite_required: false` is deleted in PR A3 (before step 5); A3 must also update `tests/guards.d/vm_vars.yml` (`sameas false` assert) - not in FR-221/AC-64 list; amend spec or accept.
- F-8 (T-14 owner): AC-27 check is presence-only; does not test "--check first" or PR table content.
- Assumptions to confirm at gate C: /etc/hosts mapping for AC-20; `ssh-keygen -N ""` (TODO verify); Mermaid inline.
- Role README of restic_backup aligned by orchestrator to the A3 timing.

### Carry-over: Code review PR A (2026-10-11)
- Fixed: (1) ssh_authorized_keys key-body/comment regexes anchored on exactly one options token (`ssh-ed25519 AAAA my ssh-thing x` now yields body `AAAA`), identical in nas, cloud and ops `vars/main.yml`; new guard `tests/guards.d/ssh_authorized_keys_regex.yml` + unit tests (old regex caught per copy). Empty revoked list re-checked with `-C` on localhost for nas, cloud, ops: revoked tasks "skipping".
- (2) ops `firewall`: enable/start tolerates "Could not find the requested service" in check mode only; all `ansible.posix.firewalld` tasks are skipped by `firewall_firewalld_usable` (check mode without the firewalld unit file); real runs unchanged; asserted in `tests/guards.d/firewall.yml`.
- (3) `semaphore_image` pin removed from production `vars.yml` (role default is the identical Pi tag v2.19.16).
- (4) `tests/static-checks.sh`: new SH-GUARDS (every guard without its own id) and SH-GUARDS-C (Docker/Podman guards; `STATIC_CHECKS_SKIP_CONTAINER_GUARDS=1` skips); `STATIC_CHECKS_STAGE` exported; `vm_vars.yml` is stage-aware (DNS cutover flag A vs D/E; `restic_backup_sqlite_required` absent-or-false, so A3 no longer edits tests; key assertions allow the new key and a revoked new key).
- (5) SH-AC-44 `diff -r` of tasks/, vars/, defaults/, meta/argument_specs.yml across the three roles + negative unit tests. (6) vm_vars guard: caddy/zerotier/restic `/opt/podman` defaults must equal podman_data_dir-derived paths. (7) `vault_hash_cli._announce` uses parents[4]; test asserts the exact directory. (8) semaphore admin check/create retry also on "no such container", "state improper", "is not running". (9) README Tests section: SH-BR-16 is operator-run per PR.
- Not changed: CI (`ci.yml`) does not run SH-BR-16; untracked `vars/` dirs are for Erik to commit. Pre-existing: ansible-lint warns about a duplicate mapping key `restic_backup_sqlite_required` (tests/render.d/restic.yml, not touched).

### PR A final verification (2026-10-11, qa-verifier): CONDITIONAL, recommend merge after Erik's items
- Static gate all passed; unit 154/154; tools 136 (+2 skipped, PyYAML absent in pipx env); pr-boundaries A OK (247 files; PR text says 245: update); Pi dir untouched; nas/cloud diff = ssh_authorized_keys only.
- Fixture (aarch64 sim): fresh-host check ok, apply, apply2 changed=1 (zerotier data dir, known), apply3 changed=0, check on applied host changed=0, s10+s20 PASS. Pinned Caddy Containerfile builds (v2.11.7, cloudflare module present).
- AC-44 no-op proven differentially (master role vs new nas/cloud, -C localhost and fixture, empty revoked list).
- Open for Erik: AC-65 baseline (Beszel/Uptime Kuma list) + 'before' flow-rule text (OP-00b) in PR-A-description.md; cloud restic one-liner; branch is 1 commit behind master (632facd, homepage v2.5.0): rebase/merge before PR; zerotier data-dir mode non-idempotence on apply 2 (document or fix).
- Unverified/live-only: x86_64, real Hetzner image, ZeroTier, cloudflare_dns, mail, enforcing SELinux, Renovate dry run (A-34 at OP-00c), CI ops-static, molecule for ops/nas/cloud.
