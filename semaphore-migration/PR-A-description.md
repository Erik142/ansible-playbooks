# PR A: Semaphore to Hetzner, step 0 (new VM directory, no-op key hardening, Renovate freeze)

Written 2026-10-11 (T-19). The file lists below come from the branch diff against master.

## Summary

Adds the new `ops-de-wahlberger-dev/` Ansible directory for the Hetzner VM that
will take over Semaphore from the Pi, plus the small changes the migration needs
in the existing nas and cloud directories. Nothing here moves Semaphore. Merge is
deploy for nas and cloud (the Pi's Semaphore applies `master`), so this PR is
limited to changes that are no-ops there (SH-BR-16, row A).

Contents:

- New `ops-de-wahlberger-dev/` (roles, inventory with `vm_zt_ip` empty, README runbook, tests, tools, docs).
- `ssh_authorized_keys`: new `ssh_authorized_keys_revoked` input (default empty) and a "key in both lists" failure, in nas and cloud (and in the new directory).
- `renovate.json`: two `enabled: false` rules, one for `pi-de-int-wahlberger-dev/**` (SH-FR-160) and one for `ops-de-wahlberger-dev/roles/semaphore/defaults/main.yml` (SH-FR-161), no other matchers.
- `.github/workflows/ci.yml`: new `ops-static` job.
- Planning documents under `semaphore-migration/`, `architecture/`, `homelab-architecture/`.
- "Before" flow-rule record in `ops-de-wahlberger-dev/docs/zerotier-flow-rules.md`: see "Open before merge".

## Files by class (`tests/pr-boundaries.sh A`: OK, 251 changed files)

Class: new VM directory (`ops-de-wahlberger-dev/*`), all untracked/new:
roles (`caddy`, `cloudflare_dns`, `common`, `container`, `disk_space`, `firewall`,
`notify_failure`, `podman`, `reboot_notify`, `restic_backup`, `security`,
`semaphore`, `ssh_authorized_keys`, `zerotier`, `beszel_agent`), `inventories/`,
`molecule/`, `tests/` (static gate, guards, render checks, unit, vm fixture), `tools/`,
`docs/` (incl. `docs/spikes/`), `README.md`, `CLAUDE.md`, `site.yml`, `ansible.cfg`, `requirements.yml`.

Class: nas/cloud `ssh_authorized_keys` role only (T-04), 8 modified + 2 new:

- `nas-de-int-wahlberger-dev/roles/ssh_authorized_keys/{README.md,defaults/main.yml,meta/argument_specs.yml,tasks/main.yml}` (modified), `vars/main.yml` (new)
- `cloud-wahlberger-dev/roles/ssh_authorized_keys/{README.md,defaults/main.yml,meta/argument_specs.yml,tasks/main.yml}` (modified), `vars/main.yml` (new)

Class: repo config:

- `renovate.json` (modified)
- `.github/workflows/ci.yml` (modified, +45 lines, `ops-static` job)

Class: planning docs (no runtime effect):

- `semaphore-migration/PLAN.md`, `semaphore-migration/reqs/{index.md,semaphore-to-hetzner.md}`, `semaphore-migration/PR-A-description.md`
- `architecture/{index.md,ai-incident-remediation-pipeline.md}`
- `homelab-architecture/{index.md,forgejo-runner-placement.md}`

Not touched: `pi-de-int-wahlberger-dev/` (`git diff master --stat -- pi-de-int-wahlberger-dev` is empty, `git status` for it is empty; SH-FR-97).
Not yet touched (pending Erik): `cloud-wahlberger-dev/roles/restic_backup/defaults/main.yml` (see deviations).

## Gate scenarios for step 0 and "safe to apply early"

Gate (README, Step 0): SH-AC-01, 17, 27, 30, 44, 45, 52, 56, 59, 60, 65, 66.
The `[S]` ones run with `tests/static-checks.sh`; AC-17 (decrypted part), 52, 59 and
the live checks are operator steps (OP-00b/c). PLAN.md's T-19/OP-00c list omits
AC-65 and AC-66; the README list is the longer one.

Row A, "safe to apply early": an empty revoked list and an unchanged effective
backup host change nothing on nas and cloud. The new directory is applied from
the workstation only; the Pi does not apply it. Rollback: revert PR A.

## Deviations from the spec

1. `cloud_zt_ip` is set in PR A2 (with `vm_zt_iface`), not PR A. The spec's Inputs table says PR A; the firewall role fails without it, and the value is only readable from Central at OP-02. The PR table in the README already says A2.
2. `restic_backup_sqlite_required: false` is set in `vars.yml` in PR A and deleted in PR A3 (before step 5), not at step 4/5 by a separate toggle. A3 must also update `tests/guards.d/vm_vars.yml` (the `sameas false` assert), which is not in the FR-221/AC-64 file list. Amend the spec or accept.
3. Cloud `restic_backup` default host `pi.de.int.wahlberger.dev` -> NAS: the edit was denied by the permission classifier (T-11, CC-06) and is NOT in this branch. Erik makes the one-line edit manually (`cloud-wahlberger-dev/roles/restic_backup/defaults/main.yml:28`, `restic_backup_rest_server_host`, and the README next to it), otherwise row A's "unchanged effective backup host" statement is trivially true but CC-06 is open. `tests/pr-boundaries.sh A` already allows both files.
4. `ssh_authorized_keys` revoked-list and both-lists check in nas and cloud: with the default empty list this is a no-op (the removal loop has no items; the assert loop has no items). Evidence in PLAN.md, QA(T-04/T-06/T-02b): full ops `molecule test` passes, nas molecule PASS, cloud molecule PASS only with the Galaxy prerun disabled (environment TLS error fetching `geerlingguy.security`, not the change). Caveat from T-04: nas and cloud Molecule verify have NO T-04 assertions, so AC-44 on nas/cloud rests on idempotence + the code reading above, not on an assertion. Roles in ops and nas are byte-identical; cloud differs only in `meta` platforms.

## Not verified / live-only (README "Known unverified")

- Host networking plus the firewalld zone as the effective gate for 443; Caddy sees real client addresses (SH-AC-51); bridge-fallback DNAT. Only a container-level proof exists (`docs/spikes/A-33-caddy-global-options.md`).
- `firewall-cmd --reload` after the zone-creating run and its effect on established sessions.
- The final `public` zone service list (fixed deny-list incl. `dhcpv6-client`).
- rebootmgr window and overrun queueing; real `zypper dup` exit codes 102/103 (103 is not in `SuccessExitStatus`); snapper pairs on btrfs; the vendor `sshd_config` layout on the real image; a real reboot-notify email.
- That the Pi's Vault holds the seven key names `tools/populate-vault.sh` copies (the tool refuses on a missing key).
- `cloud_public_ip: 49.13.141.178` in `vars.yml` was taken from public DNS; confirm it.
- Exact `hcloud` flags and the Tumbleweed image name; Semaphore extra-arguments field syntax.
- A-34 (Renovate leaves the Pi and the VM defaults alone): `renovate-config-validator` passes, but the `renovate --platform=local` dry run could not run here (Node v25 is unsupported by current Renovate). Verify at OP-00c on the Dependency Dashboard (AC-60): no update PR for those files.
- Molecule half of T-06b (reboot-notify cases, legacy-file check, key C), `cloudflare_dns` on the fixture, and the SSH check-mode tolerance (TI-2) are unverified (see PLAN.md carry-overs).

## Operator pre-merge checks (Erik)

1. AC-44 no-op property: merge is deploy for nas and cloud because the Pi's Semaphore applies `master`. Before merging, read the Molecule output (`molecule test` in `nas-de-int-wahlberger-dev` and `cloud-wahlberger-dev`; for cloud, with the Galaxy prerun disabled if the TLS error recurs) and confirm the `ssh_authorized_keys` converge and idempotence steps report `changed=0` with the empty revoked list.
2. Optionally run `--check --diff` of the nas and cloud playbooks with `--tags ssh_authorized_keys`: expect 0 changed.
3. Step-0 items OP-00a/b: Vault item, FR-163/164/165 checks, AC-17 hash comparison (also with plain `ansible-vault view ... | sha256sum`), AC-52 `config.json` hash, Pi image tag.
4. Cloud `restic_backup` host default edit (deviation 3): done on 2026-10-11 (commit `fix(cloud): point restic_backup at the NAS rest server`). Check that the cloud REST password equals the NAS's: `ops-de-wahlberger-dev/tools/vault-pair-compare.sh --cloud-nas`.
5. Fill in the baseline below.

## Open before merge (added by Erik)

- "Before" rule set: the text of Central's current rule set (OP-00b, SH-FR-33) was added by Erik on 2026-10-11 to `ops-de-wahlberger-dev/docs/zerotier-flow-rules.md`, section "Before": the verbatim Central default rule set (no custom rules).
- Step-0 baseline (SH-FR-213), date and time: every Beszel system and every Uptime Kuma monitor that is up. **Not recorded before merge (AC-65 unmet at merge, decided by Erik on 2026-10-11); record it at step 0 before any live change.**

## CI caveats

- The `ops-static` job needs the "before" text and the other operator edits to be consistent with what `static-checks.sh` checks; if the check for the flow-rule record is tightened to require non-placeholder text, `ops-static` fails until Erik's follow-up commit lands.
- `ops-static` runs on the PR branch with the PR base from `git merge-base`, so `STATIC_CHECKS_PR` and the boundary guard only prove themselves on a real PR. The seeded-failure demonstration (a deliberately bad change that the job must reject) needs a PR; it was not run locally.
- The decrypted-vault checks print SKIPPED in CI by design (dummy vault password). The workflow and the `ci.yml` jobs `validate`, `molecule`, `vault-encrypted` have not been run on a push yet (PLAN.md, carry-over T-02).

## Local verification (2026-10-11)

- `tests/pr-boundaries.sh A`: OK (251 changed files).
- `STATIC_CHECKS_SKIP_UNIT=1 tests/static-checks.sh`: all passed. SKIPPED: SH-AC-17v (no vault password file), SH-AC-43 (applies after PR E), SH-BR-16 (needs `STATIC_CHECKS_PR`), UNIT (skipped on request).
- `npx --yes --package renovate@latest -- renovate-config-validator renovate.json`: config validated, exit 0 (RE2 unavailable locally, so regex validation may be inaccurate).
- `git diff master --stat -- pi-de-int-wahlberger-dev`: empty.
- `git diff --stat` for nas/cloud: 8 files, all `ssh_authorized_keys` (T-04).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
