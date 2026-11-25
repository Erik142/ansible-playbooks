# ansible-playbooks

[![CI](https://github.com/Erik142/ansible-playbooks/actions/workflows/ci.yml/badge.svg)](https://github.com/Erik142/ansible-playbooks/actions/workflows/ci.yml)

Infrastructure-as-code for Erik's homelab. Three hosts share the
`wahlberger.homelab` collection (roles and playbooks in
`collections/homelab/`, host data in `inventories/<host>/`). The cloud host
still has its own self-contained playbook.

## Playbooks

| Playbook | Host | What it runs |
|----------|------|---------------|
| [`cloud-wahlberger-dev`](cloud-wahlberger-dev) | `cloud.wahlberger.dev` (Hetzner Cloud VM, Debian) | Pocket ID (passkey OIDC) + FreshRSS behind Caddy (HTTP-01). Not yet migrated to the collection. |
| `wahlberger.homelab.nas` | `nas.de.int.wahlberger.dev` (home NAS, openSUSE Tumbleweed) | Native Samba file share, Tandoor + Paperless-ngx + Immich behind Caddy (DNS-01), a Homepage dashboard. Inventory `inventories/nas/`. |
| `wahlberger.homelab.ops` | `ops.de.wahlberger.dev` (Hetzner CX23, openSUSE Tumbleweed) | Semaphore UI (over ZeroTier only), Caddy, Hush alerting; runs the other playbooks (see [Automated runs](#automated-runs)). Inventory `inventories/ops/`. |
| `wahlberger.homelab.ci` | `ci.de.wahlberger.dev` (netcup VPS, openSUSE) | Forgejo Actions runner for the NAS Forgejo, over ZeroTier. Inventory `inventories/ci/`. |

The collection's README is [`collections/homelab/README.md`](collections/homelab/README.md),
and the repo-wide rules are in [`CLAUDE.md`](CLAUDE.md). `cloud-wahlberger-dev`
has its own `README.md` and `CLAUDE.md`.

## Automated runs

Playbooks aren't run by hand or by GitHub-hosted CI: the NAS and ci hosts are
reachable only over the LAN or ZeroTier, which GitHub's runners cannot reach.
Instead, **Semaphore UI** runs on the ops host (reachable only over ZeroTier),
inside the network it manages, and applies the playbooks over SSH with its own
dedicated automation key, restricted by `from=` to the ops host's addresses.
See [`collections/homelab/README.md`](collections/homelab/README.md) and the ops
host's inventory in `inventories/ops/`.

## Design philosophy

Roles in the `wahlberger.homelab` collection are shared by the NAS, ci and ops
playbooks, and each host differs only in its inventory and vault. The cloud
host keeps its own copies of its roles (for example `caddy`, `container`,
`cloudflare_dns`), because it runs Debian with HTTP-01 instead of openSUSE with
DNS-01. A fix to a shared role applies to every host that uses it, so check
each host's check run after changing one.

## Running a playbook

The collection hosts run from the repo root, against the collection:

```sh
ansible-galaxy collection install -r requirements.yml -p collections --force
ansible-playbook wahlberger.homelab.nas --check --diff   # always first
ansible-playbook wahlberger.homelab.nas
```

Replace `nas` with `ops` or `ci` for those hosts (ci needs its ZeroTier address,
see `inventories/ci/`).

The cloud host runs from its own directory:

```sh
cd cloud-wahlberger-dev
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role install -r requirements.yml
ansible-playbook site.yml --ask-vault-pass
```

## CI

`.github/workflows/ci.yml` validates code on each pull request: `yamllint` and
`ansible-lint` (for playbooks that opt in with a `.yamllint`/`.ansible-lint`
config), `ansible-galaxy` dependency resolution, `ansible-playbook --syntax-check`,
and a repo-wide check that every committed `vault.yml` is actually
Vault-encrypted. It only validates code: GitHub's runners can't reach the hosts,
so real applies stay Semaphore's job (see [Automated runs](#automated-runs)).
