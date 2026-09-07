# ansible-playbooks

[![CI](https://github.com/Erik142/ansible-playbooks/actions/workflows/ci.yml/badge.svg)](https://github.com/Erik142/ansible-playbooks/actions/workflows/ci.yml)

Infrastructure-as-code for Erik's homelab: one self-contained Ansible
playbook per host, each with its own roles, inventory, and Vault-encrypted
secrets. No shared/external roles repo on purpose — see
[Design philosophy](#design-philosophy) below.

## Playbooks

| Playbook | Host | What it runs |
|----------|------|---------------|
| [`cloud-wahlberger-dev`](cloud-wahlberger-dev) | `cloud.wahlberger.dev` (Hetzner Cloud VM, Debian) | **Reference design** for this repo. Pocket ID (passkey OIDC) + FreshRSS behind Caddy (HTTP-01). |
| [`nas-de-int-wahlberger-dev`](nas-de-int-wahlberger-dev) | `nas.de.int.wahlberger.dev` (home NAS, openSUSE Tumbleweed) | Native Samba file share, Mealie + Paperless-ngx + Immich behind Caddy (DNS-01), a Homepage dashboard. |
| [`pi-de-int-wahlberger-dev`](pi-de-int-wahlberger-dev) | `pi.de.int.wahlberger.dev` (Raspberry Pi at home, Raspberry Pi OS) | Semaphore UI — runs all the playbooks in this repo (see [Automated runs](#automated-runs)). |
| [`rpi-boras`](rpi-boras) | Raspberry Pi in Borås | Legacy: bind9 + isc-kea DHCP with dynamic DNS updates. No CI lint config yet. |
| [`dns-server`](dns-server) | — | Skeleton/in-progress: bind9 + Pi-hole. No CI lint config yet. |

`cloud-wahlberger-dev`, `nas-de-int-wahlberger-dev`, and
`pi-de-int-wahlberger-dev` each have their own `README.md` and `CLAUDE.md`
with the full picture: layout, role variables, secrets, and the reasoning
behind non-obvious decisions.

## Automated runs

Playbooks aren't run by hand or by GitHub-hosted CI — `nas` and `pi` are
LAN-only and unreachable from GitHub's runners. Instead, **Semaphore UI**
(`pi-de-int-wahlberger-dev`) runs inside the network it manages and applies
all three playbooks over SSH with its own dedicated automation key. See
[`pi-de-int-wahlberger-dev/roles/semaphore/README.md`](pi-de-int-wahlberger-dev/roles/semaphore/README.md).

## Design philosophy

Roles are duplicated across playbooks (e.g. `caddy`, `container`,
`cloudflare_dns`) rather than factored into a shared roles repo. At three
hosts, each with real differences (openSUSE vs. Debian, HTTP-01 vs. DNS-01),
a shared role would need conditionals to serve cases any single playbook
doesn't actually have — the premature abstraction each playbook's
`CLAUDE.md` explicitly warns against. The cost is real (a fix has to be
copied to each copy), but it's cheap at this scale, and every playbook stays
readable start to finish without hopping repos. Revisit if duplication ever
becomes the actual pain point.

## Running a playbook

Each playbook is fully self-contained — `cd` into it and follow its own
`README.md`. In short:

```sh
cd cloud-wahlberger-dev  # or nas-de-int-wahlberger-dev, pi-de-int-wahlberger-dev
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role install -r requirements.yml
ansible-playbook site.yml --ask-vault-pass
```

## CI

`.github/workflows/ci.yml` validates every directory with an `ansible.cfg`
on each pull request: `yamllint`/`ansible-lint` (for playbooks that opt in
with a `.yamllint`/`.ansible-lint` config), `ansible-galaxy` dependency
resolution, `ansible-playbook --syntax-check`, and a repo-wide check that
every committed `vault.yml` is actually Vault-encrypted. It only validates
code — GitHub's runners can't reach the LAN-only hosts, so real applies stay
Semaphore's job (see [Automated runs](#automated-runs)).
