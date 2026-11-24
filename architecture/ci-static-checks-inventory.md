# CI static-checks inventory and classification          date: 2026-11-23   status: proposed

Source: `ops-de-wahlberger-dev/tests/static-checks.sh` (ops-static job) and
`nas-de-int-wahlberger-dev/tests/static-checks.sh` (nas-backup-static job). Timings from the passing
run of `renovate/henrygd-beszel-0.x` (ops-static, nas-backup-static on 2026-11-12, job logs).
Classification is from each check's description line in the script. Function bodies were not read
one by one; verify before deleting anything.

## Classes
- **KEEP**: cheap and unique. Policy or safety check that no other job covers.
- **DEDUPE**: already run by another CI job (`validate`, `molecule`, the render step). Remove from the static script.
- **MOVE**: replace with a molecule `verify.yml` assertion, or a Molecule scenario. Molecule runs in its own parallel job.
- **LOCAL**: prints SKIPPED in CI (no vault access, or an opt-in). Run locally only, or drop.
- **DELETE**: migration scaffolding or documentation-traceability check. Remove when the migration is done.
- **SPLIT**: mixes classes. Break up before deciding.

## Timing summary (ops-static, 5 min 14 s of "Static checks", plus 1 min render)
| Slowest | Seconds | Scenario |
|---|---|---|
| 1 | 184 | SH-GUARDS-C container guards (Docker) |
| 2 | 35 | UNIT (pytest, tests/unit) |
| 3 | 32 | SH-AC-62a cloudflare_dns guard |
| 4 | 27 | SH-AC-62b caddy guard |
| 5 | 21 | SH-AC-01L yamllint, ansible-lint, syntax-check |
| 6 | 18 | SH-GUARDS offline guards |

NAS static: under 10 s total for the scenarios, plus 46 s UNIT and 7 s AC-05. The render step (`tests/render-check.sh`, two runs) takes 1-2 min in both jobs.

## ops-de-wahlberger-dev (`tests/static-checks.sh`)
| ID | What | CI time | Class | Action |
|---|---|---|---|---|
| SH-AC-01 | skeleton: roles/tags, inventory, files, personal key | <1 s | KEEP | Keep the cheap structural part; drop the "personal key" file-presence part if it is not still needed |
| SH-AC-01L | yamllint, ansible-lint, syntax-check | 21 s | DEDUPE | `validate (ops-de-wahlberger-dev)` runs the same tools |
| SH-AC-17 | vars wiring and vault.yml.example | <1 s | KEEP | |
| SH-AC-17v | decrypted vault keys | SKIPPED | LOCAL | Needs vault. Never runs in CI |
| SH-AC-23 | key lists per BR-10, `from=` option, no private key | <1 s | KEEP | Security policy |
| SH-AC-27 | README content | <1 s | DELETE | Documentation check |
| SH-AC-30 | restic timer/script/excludes (source grep) | <1 s | MOVE | Molecule `restic_backup` verify covers the same facts |
| SH-AC-30r | restic templates rendered | SKIPPED in this job | DEDUPE | The render step runs it |
| SH-AC-43 | repository clean after PR E | SKIPPED | DELETE | Migration stage E |
| SH-AC-44 | revoked-keys input; `ssh_authorized_keys` identical in nas, cloud, ops | <1 s | KEEP | Cross-host policy. No molecule run sees it |
| SH-AC-45 | sshd validated before apply | <1 s | MOVE | Add an `assert`/`validate` task in the security role, verified by molecule |
| SH-AC-56 | handler reloads; firewall never reloads; only rebootmgrctl reboots | <1 s | MOVE | Molecule verify on security/firewall roles |
| SH-AC-60 | Renovate freeze rules for the stage | <1 s | DELETE | Stage-specific |
| SH-AC-62a | guard test cloudflare_dns (own run) | 32 s | MOVE | Molecule scenario for cloudflare_dns, parallel job |
| SH-AC-62b | guard test caddy (own run) | 27 s | MOVE | Molecule scenario for caddy |
| SH-R6 | guard test firewall (zone tasks gated) | ~1 s | MOVE | Molecule firewall verify |
| SH-GUARDS | all other offline guards in `tests/guards.d` | 18 s | SPLIT | Each guard: MOVE if a role has molecule, else KEEP |
| SH-GUARDS-C | container guards: restic_backup, semaphore, security_check_mode | 184 s | MOVE | Largest cost. These are container tests already. Move into the molecule job; if it stays, run it nightly, not per PR |
| SH-AC-63 | vm_zt_ip/vm_zt_iface and flow-rule record | <1 s | DELETE | Fixture bookkeeping |
| SH-FR-97 | pi directory untouched until step 7 | <1 s | DELETE | Migration; PR E removes the Pi directory |
| SH-FR-205 | no ZeroTier Central token in the repo | <1 s | KEEP | Secret-leak grep, cheap, unique |
| SH-BR-16 | PR boundary (STATIC_CHECKS_PR) | SKIPPED | DELETE | Opt-in diff check for PR branches; migration |
| UNIT | pytest tests/unit | 35 s | SPLIT | Tests of `static-checks.sh` itself go with the deleted checks. Tests of `tools/` went with the migration tooling (removed in chore/remove-retired-hosts-tooling) |

## nas-de-int-wahlberger-dev (`tests/static-checks.sh`)
| ID | What | CI time | Class | Action |
|---|---|---|---|---|
| AC-01 | yamllint, ansible-lint, syntax-check (nas + cloud) | <1 s | DEDUPE | `validate` job |
| AC-02 | no noqa / skip_list / warn_list added | <1 s | KEEP | Lint-policy grep on the diff |
| AC-04 | destructive operations unreachable from site.yml | <1 s | KEEP | Safety |
| GS-AC-74 | garage role runs no layout/bucket/key/lifecycle command | <1 s | KEEP | Safety: the user runs those steps, not Ansible |
| AC-05 | role order and tags (`--list-tasks`) | 7 s | KEEP | Cheap, unique ordering check. Consider running only on `site.yml` changes |
| AC-06 | defaults vs argument_specs | <1 s | KEEP | Molecule does not check this |
| AC-07 | render check (default and spindown 120) | in render step | DEDUPE | Run once, in the render step |
| AC-08 | rest-server image Renovate-detectable | <1 s | KEEP | Protects `renovate.json` regex coverage |
| AC-09 | vars, flags and vault.yml.example wiring | <1 s | KEEP | |
| AC-09v | decrypted vault keys and BD-BR-09 equalities | SKIPPED | LOCAL | Needs vault |
| AC-10 | restic_backup role gone | <1 s | DELETE | Migration done |
| AC-11 | Pi untouched and never contacted | <1 s | DELETE | Migration |
| AC-14 | no NAS doc describes the old job as deployed | <1 s | DELETE | Documentation check |
| AC-15 | snapper role untouched | <1 s | DELETE | Diff-based one-off |
| AC-16 | VM fixture inventory shape | <1 s | DELETE | Fixture bookkeeping |
| AC-16v | no production vault value in inventories/vm | SKIPPED | LOCAL | Needs vault |
| UNIT | pytest tests/unit | 46 s | SPLIT | Tests of the deleted checks go. Tests of tools stay |

## Known failures blocking merges (2026-11-23)
- **nas-backup-static** fails on PR #61 in the render step: the assertion
  `^Image=docker\.io/dxflrs/garage:v2\.4\.1@sha256:...` is hardcoded. Renovate's bump to
  `v2.5.0` breaks it. **Version pins hardcoded in assertions break every Renovate bump.**
  Use a pattern (`v2\.[0-9.]+`) or read the expected value from the role defaults.
- **ops-static** fails on PR #61 in the render step on the Semaphore image assertion
  (`v2\.19\.[0-9]+`). PR #61 does not change `semaphore_image`, so the cause is not yet traced.

## Speed plan (proposed order, biggest win first)
1. Move SH-GUARDS-C (184 s) to molecule or nightly. Largest single saving.
2. Remove the duplicate lint in SH-AC-01L and AC-01 (21 s, plus the same in NAS).
3. Run the render check once per job, not in two steps.
4. Cache `ansible-galaxy` collections and roles (the "Install collection" steps take about 1 min).
5. Replace version-pinned assertions with patterns, so Renovate PRs stop failing on them.
6. DELETE the migration and documentation checks once the migration ends.
