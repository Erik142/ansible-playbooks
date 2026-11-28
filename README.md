# infra-homelab

[![CI](https://github.com/Erik142/infra-homelab/actions/workflows/ci.yml/badge.svg)](https://github.com/Erik142/infra-homelab/actions/workflows/ci.yml)

Infrastructure-as-code for Erik's homelab. Four hosts share the
`wahlberger.homelab` collection (roles and playbooks in
`ansible/collections/homelab/`, host data in `ansible/inventories/<host>/`).

## Playbooks

| Playbook | Host | What it runs |
|----------|------|---------------|
| `wahlberger.homelab.edge` | `edge.de.wahlberger.dev` (Hetzner, openSUSE Tumbleweed) | Pocket ID (passkey OIDC) + FreshRSS + Beszel hub + Uptime Kuma behind Caddy (HTTP-01). Inventory `ansible/inventories/edge/`. |
| `wahlberger.homelab.nas` | `nas.de.int.wahlberger.dev` (home NAS, openSUSE Tumbleweed) | Native Samba file share, Tandoor + Paperless-ngx + Immich behind Caddy (DNS-01), a Homepage dashboard. Inventory `ansible/inventories/nas/`. |
| `wahlberger.homelab.ops` | `ops.de.wahlberger.dev` (Hetzner CX23, openSUSE Tumbleweed) | Semaphore UI (over ZeroTier only), Caddy, Hush alerting; runs the other playbooks (see [Automated runs](#automated-runs)). Inventory `ansible/inventories/ops/`. |
| `wahlberger.homelab.ci` | `ci.de.wahlberger.dev` (netcup VPS, openSUSE) | Forgejo Actions runner for the NAS Forgejo, over ZeroTier. Inventory `ansible/inventories/ci/`. |

The collection's README is [`ansible/collections/homelab/README.md`](ansible/collections/homelab/README.md),
and the repo-wide rules are in [`CLAUDE.md`](CLAUDE.md).

## Automated runs

Playbooks aren't run by hand or by GitHub-hosted CI: the NAS and ci hosts are
reachable only over the LAN or ZeroTier, which GitHub's runners cannot reach.
Instead, **Semaphore UI** runs on the ops host (reachable only over ZeroTier),
inside the network it manages, and applies the playbooks over SSH with its own
dedicated automation key, restricted by `from=` to the ops host's addresses.
See [`ansible/collections/homelab/README.md`](ansible/collections/homelab/README.md) and the ops
host's inventory in `ansible/inventories/ops/`.

## Design philosophy

Roles in the `wahlberger.homelab` collection are shared by the NAS, ops, ci and
edge playbooks, and each host differs only in its inventory and vault. A fix to
a shared role applies to every host that uses it, so check each host's check
run after changing one.

## Running a playbook

The collection hosts run from `ansible/`, against the collection:

```sh
ansible-galaxy collection install -r requirements.yml -p collections --force
ansible-playbook wahlberger.homelab.nas --check --diff   # always first
ansible-playbook wahlberger.homelab.nas
```

Replace `nas` with `ops`, `ci` or `edge` for those hosts (ci needs its ZeroTier address,
see `ansible/inventories/ci/`).

## CI and tests

`.github/workflows/ci.yml` runs on every pull request and on pushes to `master`:

- **lint**: `ansible/scripts/lint.sh` runs yamllint, ansible-lint (production profile), a
  check that every role has a molecule scenario or a recorded exclusion, and
  `--syntax-check` for each host playbook. A separate step checks that every
  committed `vault.yml` is Ansible-Vault encrypted.
- **molecule**: one leg per scenario (`base`, and one per host playbook). Each leg
  runs `ansible/scripts/molecule.sh <scenario>`: converge, a second converge that must change
  nothing, and verify. The shared test image is built from
  `ansible/collections/homelab/extensions/molecule/build/`.
- **gate**: the one check required on `master`. It fails if lint fails, or if code
  changed and a molecule leg failed. Docs-only changes skip molecule.

The same scripts run locally. Lint: `ansible/scripts/lint.sh`. One scenario:
`ansible/scripts/molecule.sh playbook-nas`. The CI tooling is pinned in `ansible/requirements-ci.txt`.

CI never decrypts real secrets: it uses a dummy vault password and fake values for
everything the scenarios need. The real hosts are not reachable from GitHub's
runners, so real applies stay Semaphore's job (see [Automated runs](#automated-runs)).
