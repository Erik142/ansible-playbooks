# infra-homelab (repo root)

Layout: Ansible lives in `ansible/`. Run every Ansible command and script from `ansible/`;
the paths below are relative to it. The root holds `README.md`, `CLAUDE.md`, `docs/`,
`renovate.json` and `.github/` (CI reads only the root `.github/`). `tofu/` will hold the
Hetzner OpenTofu code later.

This file covers rules for the whole repo. Host details live in the collection
README (`collections/homelab/README.md`) and the inventory's `group_vars`.

## Layout

- `collections/homelab/`: the `wahlberger.homelab` collection. Roles live in
  `roles/`, playbooks in `playbooks/` (`nas`, `ops`, `ci`, `edge`). See its `README.md`.
- `inventories/<host>/`: host inventory and `group_vars` (Vault-encrypted
  secrets, non-secret settings). Hosts: `nas`, `ops`, `ci`, `edge`.
- `ansible.cfg`, `requirements.yml`, `.vault_pass.sh`, `.vault_pass_nas.sh`,
  `.vault_pass_ops.sh`, `.vault_pass_ci.sh`, `.vault_pass_edge.sh`: shared config at
  the root. Vault ids: `ci`, `ops` and `edge` have their own password script
  (`vault_identity_list`); unlabelled files use `.vault_pass.sh` (the NAS password).
- `scripts/`: `lint.sh` (lint and syntax checks), `molecule.sh` (one molecule
  scenario), `molecule-inventory.py` (renders the real non-secret group_vars for the
  molecule scenarios).
- `collections/homelab/extensions/molecule/`: molecule scenarios and `coverage.yml`.
- `docs/`: architecture notes (flat, no subdirectories).

## Running a host

```sh
ansible-galaxy collection install -r requirements.yml -p collections --force
ansible-playbook wahlberger.homelab.<host> --check --diff   # always first
ansible-playbook wahlberger.homelab.<host>
```

`<host>` is `nas`, `ops`, `ci` or `edge`. The vault passwords come from 1Password
through the scripts above. Unlock 1Password before running.

## Linting and molecule tests

- `scripts/lint.sh`: yamllint, ansible-lint, the role coverage check and
  syntax-check of each host playbook. It is also the CI lint job.
- `scripts/molecule.sh <scenario>`: one molecule scenario (`base`, `playbook-nas`,
  `playbook-ops`, `playbook-ci`, `playbook-edge`). It is also the CI molecule job.
  The first run builds the test image: `docker build -t homelab-molecule:tumbleweed collections/homelab/extensions/molecule/build`.
- Do not run `ansible-lint` or `ansible-playbook` bare for checks: `ansible.cfg` loads every
  `vault_identity_list` script at startup, so each run calls `op` (1Password) four times.
  `lint.sh` and `molecule.sh` override the vault env vars so no 1Password call happens.
- Playbook scenarios use the real non-secret group_vars, rendered by
  `scripts/molecule-inventory.py`. Vault values are a generated stub. The encrypted
  vault is never read. Container-only overrides go in the scenario's `inventory/host_vars`.

## Collection rules

- **FQCN for every module** (`ansible.builtin.*`, `community.general.*`, ...).
- **Roles are self-contained**: `defaults/`, `tasks/`, `meta/argument_specs.yml`,
  `README.md`.
- **Variables are role-prefixed** (`caddy_*`, `podman_*`, ...).
- **No dependencies in `meta/main.yml`**. Order roles in the playbook.
- **Idempotent**: built-in modules only; restart through change-notified handlers.
- **openSUSE only**: package installs use `community.general.zypper`.
- **Facts**: read them as `ansible_facts['x']`. Top-level fact injection is off.
- **Adding a containerized service**: create `roles/<svc>/`, put a templated unit
  at `roles/<svc>/templates/<svc>.container.j2`, then `include_role: container` with
  `container_name` and `container_quadlet_src`. Add the role to the host's playbook
  (`collections/homelab/playbooks/<host>.yml`) in the right dependency position. If the service has a web UI, add it to
  `roles/homepage/templates/services.yaml.j2` in the same change.
- **Every role has a molecule entry**: `collections/homelab/extensions/molecule/coverage.yml`
  maps it to the scenario that runs it, or to an `exclude:` reason. `scripts/lint.sh`
  fails when a role has neither.

## CI testing

- Always use `act` (nektos/act) to test changes to `.github/workflows/`. Run the affected jobs locally before pushing, e.g. `act pull_request -W .github/workflows/ci.yml -j lint`. Simulated runs (calling the scripts directly) are not a substitute: `act` runs the real workflow YAML, including step order, `if:` conditions, cache steps and job dependencies.
- Report what `act` could not reproduce (runner image differences, missing secrets, GitHub-only contexts) instead of hiding it.

## Hush recovery lists (mandatory)

`inventories/<host>/group_vars/all/hush_recovery.yml` (`hush_recovery_units`) must list every long-running unit that has an `OnFailure=notify-failure@%n.service` or `OnFailure=notify-failure-immediate@%n.service` hook (the second is used by samba's smb and nmb units). Without the entry, Hush gets the failure but never the recovery, so the problem stays open and escalates on every cycle.

- **Whenever a service is added, removed, renamed or its unit name changes**, update this list in the same change. Check with `grep -rl "OnFailure=notify-failure" collections/homelab/roles` against the host's list. Services that do not run on a host must not be listed for it: the NAS roles also ship units that only the NAS runs.
- One-shot units (timers, backup and check jobs) are not listed. A drop-in restarts the unit, which is wrong for them.
- On ops, `caddy.service` and `semaphore.service` are covered by `hush_systemd_watched_units` in the `hush` role. Do not duplicate them here.
- Deploying a changed list restarts the listed units whose drop-in changed. For `zerotier.service`, that briefly drops ZeroTier connectivity, so run it in a window where that is acceptable.
