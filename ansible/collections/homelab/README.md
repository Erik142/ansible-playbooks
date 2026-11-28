# wahlberger.homelab

Roles and playbooks for the homelab hosts. All roles target openSUSE only.

## Layout

- `roles/`: one role per service or host concern. Roles are self-contained
  (`defaults/`, `tasks/`, `meta/argument_specs.yml`, `README.md`).
- `playbooks/nas.yml`: the NAS play (host group `nas`). It picks the roles it
  needs. Other hosts get their own playbook here and use only their subset.
- `playbooks/ops.yml`, `ci.yml`, `edge.yml`: the same for the other hosts.
- `extensions/molecule/`: molecule scenarios. `base` converges the roles that run in a
  container, and each host playbook has a scenario that runs its container-capable
  tags. `coverage.yml` maps every role to its scenario or to a reason it is excluded.
  Run one with `scripts/molecule.sh <scenario>` from the repo root.

Host data (inventory, `group_vars`, Vault) is not in this collection. It lives in
the repo's `inventories/<host>/`.

## Use from the repo

The repo's root `ansible.cfg` and `requirements.yml` install the collection into
`collections/` (gitignored copies):

```sh
ansible-galaxy collection install -r requirements.yml -p collections --force
ansible-playbook wahlberger.homelab.nas
```

Re-run the install after every change to this directory, or the play runs the
old copy.

## Clean-host run

The NAS play is meant to rebuild a freshly installed host in one run. The role
order in `playbooks/nas.yml` follows the dependencies between roles:

- `storage` mounts the existing data disks before anything that writes to them.
- `caddy` creates `caddy.network`. Services that join it come after it.
- `garage` creates `garage.network` before `caddy` joins it.
- `forgejo` runs before `lab_grab`, which pulls its image from the Forgejo registry.
- `hush_recovery` runs last, so every unit it lists exists.

The data disks are not formatted by the play. Their subvolumes and the pinned
account ids (`garage_account_uid/gid`, `restic_server_account_uid/gid`) must
match what is already on them.

Check mode cannot validate a clean-host run: tasks that depend on earlier
tasks' state are skipped under `--check`.
