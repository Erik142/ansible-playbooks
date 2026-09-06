# pi-de-int-wahlberger-dev

Ansible playbook for **`pi.de.int.wahlberger.dev`**, a Raspberry Pi at home
running **Raspberry Pi OS** (Debian 13 "Trixie" base). Its one job is running
**Semaphore UI** — a self-hosted web UI for running Ansible playbooks — behind
a **Caddy** reverse proxy with Pocket ID single sign-on.

Built by copying the conventions of [`cloud-wahlberger-dev`](../cloud-wahlberger-dev),
this repo's reference design — same Debian base, so this mirrors it almost
directly: `apt`, `ufw`, `geerlingguy.security`. The `caddy` role is copied
from [`nas-de-int-wahlberger-dev`](../nas-de-int-wahlberger-dev) instead,
because this Pi shares the NAS's network position (a home LAN device with no
public inbound port), not the cloud VM's.

## Why this host exists

Running `ansible-playbook` by hand from a laptop doesn't scale, but a
CI-triggered pipeline hits a homelab-specific snag: `cloud-wahlberger-dev`,
the NAS, and this Pi aren't all reachable the same way. `cloud-wahlberger-dev`
has a public IP; the NAS and this Pi only exist on the home
LAN/ZeroTier network — GitHub's hosted runners have no route to them.

The fix is to put the thing that *runs* playbooks **inside** the network they
target, rather than trying to reach in from outside. This Pi (already idle
hardware) is that machine. It also means the SSH keys and vault passwords for
your entire infrastructure live on the box that's hardest to reach from the
internet, not the easiest — putting Semaphore on `cloud-wahlberger-dev`
instead would mean your most exposed machine also holds the master keys to
everything else.

**Trigger model:** prefer configuring Semaphore's own internal
polling/schedule over a git webhook. A webhook needs GitHub to reach *in* to
this Pi, which means port-forwarding — the same problem this whole
architecture exists to avoid. Polling every few minutes only needs *outbound*
connections, and for a homelab that's responsive enough.

## Layout

```text
pi-de-int-wahlberger-dev/
├── ansible.cfg                  # project-local Ansible settings
├── site.yml                     # top-level playbook (entry point)
├── requirements.yml             # Galaxy collections + roles to install
├── .ansible-lint                # lint config (production profile)
├── .yamllint                    # YAML style config
├── README.md / CLAUDE.md        # docs (human / AI agent)
├── inventories/
│   └── production/
│       ├── hosts.yml            # host & group *structure* only
│       └── group_vars/
│           └── all/
│               └── vars.yml     # variables for all hosts (vault.yml sits here too)
└── roles/
    ├── common/                  # baseline OS setup (apt, packages, timezone)
    ├── ssh_authorized_keys/     # authorizes your personal + Semaphore's automation SSH keys
    ├── firewall/                # ufw host firewall (default-deny inbound)
    ├── storage/                 # mounts the external USB drive for container data
    ├── podman/                  # Podman + Quadlet runtime
    ├── caddy/                   # reverse proxy + automatic HTTPS via DNS-01 (shared network)
    ├── semaphore/                # Semaphore UI, Pocket ID OIDC login
    └── container/                # generic Quadlet (.container) deployer (helper)
# Plus external role geerlingguy.security (SSH hardening, fail2ban, auto-updates),
# installed from Galaxy via requirements.yml.
```

## Prerequisites

- Ansible (ansible-core ≥ 2.15) on the control machine.
- SSH access to `pi.de.int.wahlberger.dev` as `erikwahlberger` with `sudo`
  rights — escalation is enabled in `site.yml`. **Key-based SSH must work**:
  the `geerlingguy.security` role disables password authentication.
- The external USB drive already plugged in and holding its existing data —
  this playbook does **not** partition/format it, only mounts it (see
  "Data layout" below).
- Galaxy collections and roles installed:

  ```sh
  ansible-galaxy collection install -r requirements.yml
  ansible-galaxy role install -r requirements.yml
  ```

## Usage

```sh
# Dry run — show what would change, with diffs.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml --check --diff

# Apply everything.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml

# Only one role.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml --tags semaphore
```

The vault password is fetched automatically from 1Password (see `.vault_pass.sh`
and "Secrets with Ansible Vault" below) — no `--ask-vault-pass` needed.

`ansible.cfg` sets `inventories/production/hosts.yml` as the default
inventory, so `-i` is optional.

## Hardening

Baseline hardening runs on every play, before the container runtime — same
as `cloud-wahlberger-dev`: automatic security updates, fail2ban, SSH
hardening (root login and password auth disabled), and `ufw` allowing only
22/80/443. See that playbook's README for the full rationale; it's identical
here.

**Passwordless sudo for `erikwahlberger`** is also enabled
(`security_sudoers_passwordless`) — required so Semaphore can run playbooks
against this host (and the other two) without a human typing a sudo
password. This is a deliberate tradeoff specific to being the automation
host; the other playbooks only enable it because Semaphore needs to reach
them, not by default.

## Services

| Service | How | Notes |
|---------|-----|-------|
| Caddy | Podman Quadlet, custom-built image | Automatic HTTPS via **DNS-01** (Cloudflare) — same reasoning as the NAS. See [`roles/caddy/README.md`](roles/caddy/README.md). |
| Semaphore UI | Podman Quadlet, behind Caddy | Runs Ansible playbooks against this host, the NAS, and cloud-wahlberger-dev. Pocket ID OIDC login (with caveats — see [`roles/semaphore/README.md`](roles/semaphore/README.md)). |

**Before the first run:** point `semaphore.de.int.wahlberger.dev` at
wherever clients actually reach this host (its LAN or ZeroTier IP) —
DNS-01 doesn't need a public IP, unlike HTTP-01.

## Data layout

The external USB drive (`storage_device`, a stable `/dev/disk/by-id/...`
path) already holds unrelated data. The `storage` role mounts it at
`storage_mount_path` (`/mnt/data`) — persisted in `/etc/fstab` with `nofail`
so a missing/unplugged drive can't block the whole boot — and only ever
touches its `containers/` subdirectory, which `podman_data_dir` points into.
You must set `storage_fstype` in `vars.yml` yourself (check with
`sudo blkid <device>` or `lsblk -f` on the Pi) — this role does not format
the device, so guessing wrong just fails the mount loudly rather than
risking the existing data.

## Cross-host SSH keys

`ssh_authorized_keys_list` (the SAME two entries) is authorized on this host,
`cloud-wahlberger-dev`, and the NAS: your personal key, for manual access,
and a dedicated keypair for Semaphore's unattended runs, kept separate on
purpose. The automation key's *private* half never touches any of these
playbooks or Ansible Vault; it's pasted directly into Semaphore's own Key
Store after deployment (see `roles/semaphore/README.md`).

## On shared roles across playbooks

`ssh_authorized_keys`, and the pattern used by `caddy`/`container`, are
duplicated verbatim across `cloud-wahlberger-dev`, `nas-de-int-wahlberger-dev`,
and this playbook, rather than extracted into a shared external role. That's
deliberate, not an oversight: each playbook stays fully self-contained and
readable on its own, matching this repo's existing reference-design
philosophy (copy the pattern, don't centrally share). If duplication across
these three ever becomes genuinely painful to keep in sync, the natural next
step is a small role in its own git repo, consumed via `requirements.yml`'s
`roles:` — exactly how `geerlingguy.security` already works.

## Adding a containerized service

Same pattern as `cloud-wahlberger-dev`/`nas-de-int-wahlberger-dev`: create
`roles/<svc>/` (underscore, not hyphen — ansible-lint), put a templated unit
at `roles/<svc>/templates/<svc>.container.j2`, then `include_role: container`
with `container_name` and `container_quadlet_src`. Add `- role: <svc>` to
`site.yml`. See [`roles/container/README.md`](roles/container/README.md).

## Secrets with Ansible Vault

Never commit plaintext secrets. Keep them in an encrypted file alongside the
non-secret vars:

```sh
ansible-vault create inventories/production/group_vars/all/vault.yml
ansible-vault edit   inventories/production/group_vars/all/vault.yml
```

Inside `vault.yml`, name everything with a `vault_` prefix — see
`vault.yml.example` for the exact keys this playbook needs (the Cloudflare
DNS token, Semaphore's admin password, its database encryption key and
cookie keys, and its OIDC client secret). Surface each under a friendly name
in `vars.yml` (already done). By default the vault password is fetched from
1Password automatically — see `.vault_pass.sh` (requires the `op` CLI signed
in and the desktop app unlocked). Without 1Password, fall back to:

```sh
ansible-playbook site.yml --ask-vault-pass
# or: echo 'my-vault-password' > .vault_pass && ansible-playbook site.yml --vault-password-file .vault_pass
```

**Reusing the Cloudflare token?** `vault_cloudflare_dns_api_token` should be
the SAME token already used by the NAS's Caddy and rpi-karlsruhe's Traefik —
same `wahlberger.dev` zone, no reason to mint a new one.

## Linting & validation

```sh
yamllint .
ansible-lint
ansible-playbook site.yml --syntax-check
```

## References

- [Ansible — sample directory layout & best practices](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)
- [ansible-lint profiles](https://ansible.readthedocs.io/projects/lint/profiles/)
- [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [Semaphore UI documentation](https://semaphoreui.com/docs)
- [Semaphore UI + Pocket ID integration guide](https://pocket-id.org/docs/client-examples/semaphore-ui)
