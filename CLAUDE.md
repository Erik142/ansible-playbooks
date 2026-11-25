# ansible-playbooks (repo root)

This file covers rules for the whole repo. Host details live in the collection
README (`collections/homelab/README.md`) and the inventory's `group_vars`.
`playbooks/cloud-wahlberger-dev/` keeps its own `CLAUDE.md`.

## Layout

- `collections/homelab/`: the `wahlberger.homelab` collection. Roles live in
  `roles/`, playbooks in `playbooks/` (`nas`, `ops`, `ci`). See its `README.md`.
- `inventories/<host>/`: host inventory and `group_vars` (Vault-encrypted
  secrets, non-secret settings). Hosts: `nas`, `ops`, `ci`.
- `ansible.cfg`, `requirements.yml`, `.vault_pass.sh`, `.vault_pass_nas.sh`,
  `.vault_pass_ops.sh`: shared config at the root. Vault ids: `ci` and `ops`
  have their own password script (`vault_identity_list`); unlabelled files use
  `.vault_pass.sh` (the NAS password).
- `playbooks/cloud-wahlberger-dev/`: the one host not yet in the collection, with its own
  playbook and `CLAUDE.md`.
- `docs/`: architecture notes (flat, no subdirectories).

## Running a host

```sh
ansible-galaxy collection install -r requirements.yml -p collections --force
ansible-playbook wahlberger.homelab.<host> --check --diff   # always first
ansible-playbook wahlberger.homelab.<host>
```

`<host>` is `nas`, `ops` or `ci`. The vault passwords come from 1Password
through the scripts above. Unlock 1Password before running.

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

## CI testing

- Always use `act` (nektos/act) to test changes to `.github/workflows/`. Run the affected jobs locally before pushing, e.g. `act pull_request -W .github/workflows/ci.yml -j ops-static`. Simulated runs (calling the scripts directly) are not a substitute: `act` runs the real workflow YAML, including step order, `if:` conditions, cache steps and job dependencies.
- Report what `act` could not reproduce (runner image differences, missing secrets, GitHub-only contexts) instead of hiding it.

## Hush recovery lists (mandatory)

`inventories/<host>/group_vars/all/hush_recovery.yml` (`hush_recovery_units`) must list every long-running unit that has `OnFailure=notify-failure@%n.service`. Without the entry, Hush gets the failure but never the recovery, so the problem stays open and escalates on every cycle.

- **Whenever a service is added, removed, renamed or its unit name changes**, update this list in the same change. Check with `grep -rl "OnFailure=notify-failure" collections/homelab/roles` against the host's list. Services that do not run on a host must not be listed for it: the NAS roles also ship units that only the NAS runs.
- One-shot units (timers, backup and check jobs) are not listed. A drop-in restarts the unit, which is wrong for them.
- On ops, `caddy.service` and `semaphore.service` are covered by `hush_systemd_watched_units` in the `hush` role. Do not duplicate them here.
- Deploying a changed list restarts the listed units whose drop-in changed. For `zerotier.service`, that briefly drops ZeroTier connectivity, so run it in a window where that is acceptable.
