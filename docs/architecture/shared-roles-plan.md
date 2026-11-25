# Plan: shared roles across host playbooks

Status: proposed, 2026-11-24. Scope: step 1 only (shared roles). Collapsing playbooks into one collection is a later decision (see "Open decisions").

## Problem
Sixteen roles exist as copies in several host directories:

| Role | Hosts with a copy |
|---|---|
| `common`, `firewall`, `podman`, `disk_space`, `reboot_notify`, `notify_failure`, `ssh_authorized_keys`, `cloudflare_dns`, `beszel_agent` | 5 |
| `container` | 6 |
| `zerotier`, `caddy`, `hush_recovery` | 4 |
| `security` | 3 |
| `storage`, `semaphore`, `restic_server`, `restic_backup` | 2 |

Every fix has to land in each copy. Copies already drift, and the ops static check SH-AC-44 exists only to keep one file identical across three hosts. Per-host differences are real (hosts run different services), so a copy is not always wrong. The problem is that the shared part is copied by hand.

## Goal
One copy of each shared role, used by every host directory. Each host keeps its own inventory, vault, `site.yml` and host-specific variables.

Non-goals: merging inventories, merging vaults, changing `site.yml` role order, changing the ops spec (SH-FR-13).

## Approach
1. **Location.** `shared/roles/` at the repo root. Each host's `ansible.cfg` gets `roles_path = roles:../shared/roles` (local roles win, so a host can override a shared role during migration).
2. **Only identical roles move first.** A role moves when its copies are byte-identical. Diverged roles are reconciled one at a time, and the diff becomes a host variable or a separate role if it is host-specific.
3. **Role contract stays unchanged.** Shared roles keep their `defaults/`, `meta/argument_specs.yml` and README. Host differences go in `group_vars`, not in the role. Roles still have no `meta` dependencies (repo convention).
4. **Molecule and render checks** point at the shared path, so the same role is tested from one place.

## Verification (per host, before and after the move)
- `ansible-playbook site.yml --check --diff` output is identical before and after the move, apart from the expected changes in the same PR. Captured per host.
- `ansible-lint` production profile passes per host directory.
- Existing static checks still pass. Any check that reads a role's path is updated to the shared path, and the check's intent is kept.
- CI: the per-directory `validate` and `molecule` jobs still run. No job is removed in this step.

## Rollout
1. **Inventory.** Script a table of role copies and whether each is identical (`cmp` per file). Commit it as `architecture/shared-roles-inventory.md`.
2. **Move identical roles** for NAS first, then netcup-ci, cloud, pi, dns-server, and ops last. One PR per host, each with its check-mode proof.
3. **Reconcile diverged roles** in separate PRs, one role at a time.
4. **Lock it in.** Replace SH-AC-44-style "identical file" checks with a single check that the shared role exists once.

Stop rule: if a host's check-mode diff changes unexpectedly after the move, revert that host's PR and investigate before continuing.

## Risks
- **Silent overrides:** a host's local copy shadows the shared one. Mitigation: `roles_path` lists local first, and CI fails if a local copy of a shared role exists after its migration PR.
- **Variable collisions:** two hosts want different defaults for one role. Mitigation: move the difference into `group_vars`.
- **Ops coupling:** ops is the Semaphore host and has its own spec (SH-FR-13) and automation key. Step 2 for ops is optional and needs its own review.

## Open decisions
1. Confirm `shared/roles/` as the location.
2. Include cloud, pi and dns-server in step 2, or only NAS and netcup-ci?
3. Ops: migrate in step 2, or keep its own copies until the Semaphore question is settled?
4. Single collection (merging playbooks, the original idea): decide after step 2, based on how much drift remains.
