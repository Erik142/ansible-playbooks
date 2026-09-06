# nas-de-int-wahlberger-dev

Ansible playbook for **`nas.de.int.wahlberger.dev`**, Erik's primary NAS in
Germany, running **openSUSE Tumbleweed**. Serves files over **native Samba**
(guest access, no container), and runs a **Podman Quadlet** container stack
for **Mealie** and **Paperless-ngx** behind a **Caddy** reverse proxy with
Pocket ID single sign-on. ZeroTier is configured transparently for the whole
LAN at the router, so this host has no ZeroTier client of its own.

Built by copying the conventions of [`cloud-wahlberger-dev`](../cloud-wahlberger-dev),
this repo's reference design — fully-qualified module names, self-contained
roles with documented variables and input validation, idempotent tasks, and
linting wired up — adapted for openSUSE Tumbleweed (`zypper` instead of
`apt`, `firewalld` instead of `ufw`, hand-rolled SSH/fail2ban hardening
instead of `geerlingguy.security`, which doesn't target openSUSE).

## Why this isn't just added to rpi-karlsruhe

This NAS runs the **same two application containers** (Mealie, Paperless-ngx)
that `rpi-karlsruhe` already serves, at the **same hostnames** — it's meant to
replace those instances, not sit alongside them as a second copy under
different names. Rather than bolt a second, architecturally different host
(different OS, different container tech conventions, native Samba instead of
containerized) onto an existing playbook, it gets its own reference-quality
playbook. When you cut over, retire the corresponding roles in
`rpi-karlsruhe/main.yml` (`samba`, `paperless-ngx`, `mealie`) yourself.

## Layout

```text
nas-de-int-wahlberger-dev/
├── ansible.cfg                  # project-local Ansible settings
├── site.yml                     # top-level playbook (entry point)
├── requirements.yml             # Galaxy collections to install
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
    ├── common/                  # baseline OS setup (zypper, packages, timezone)
    ├── security/                # SSH hardening, fail2ban, automatic patching
    ├── firewall/                # firewalld host firewall (default-deny inbound)
    ├── podman/                  # Podman + Quadlet runtime
    ├── caddy/                   # reverse proxy + automatic HTTPS (shared network)
    ├── samba/                   # NATIVE Samba file server (not a container), guest access
    ├── mealie/                  # Mealie recipe manager, Pocket ID OIDC login
    ├── paperless_ngx/           # Paperless-ngx (Redis + PostgreSQL + app), Pocket ID OIDC login
    ├── homepage/                # dashboard linking this NAS's + cloud-wahlberger-dev's services
    └── container/                # generic Quadlet (.container) deployer (helper)
```

## Prerequisites

- Ansible (ansible-core ≥ 2.15) on the control machine.
- SSH access to `nas.de.int.wahlberger.dev` as `erikwahlberger` with `sudo`
  rights — escalation is enabled in `site.yml`. **Key-based SSH must work**:
  the `security` role disables password authentication.
- Two storage devices already mounted on the host (this playbook does **not**
  partition/format/mount anything — see "Data layout" below):
  - `/mnt/data` — Samba data (only its `samba/` subdirectory is shared).
  - `/mnt/containers` — container data.
- Galaxy collections installed:

  ```sh
  ansible-galaxy collection install -r requirements.yml
  ```

## Usage

```sh
# Dry run — show what would change, with diffs.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml --check --diff

# Apply everything.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml

# Only one role.
/Users/erikwahlberger/.pyenv/versions/ansible-bind9-venv/bin/ansible-playbook site.yml --tags samba
```

The vault password is fetched automatically from 1Password (see `.vault_pass.sh`
and "Secrets with Ansible Vault" below) — no `--ask-vault-pass` needed.

`ansible.cfg` sets `inventories/production/hosts.yml` as the default
inventory, so `-i` is optional.

## Data layout

Persistent data is split across two separately mounted storage devices — each
role **asserts** the mountpoint itself (not a subdirectory of it) is an
actual mountpoint before writing anything, so a missing mount fails loudly
instead of silently landing on the root filesystem:

- `/mnt/data` is the mountpoint; only its `samba/` subdirectory
  (`/mnt/data/samba/`) is shared as the guest Samba share root. Also holds
  Paperless's scan-to-folder inbox at `.../samba/paperless-inbox/`.
- `/mnt/containers/<service>/` — container data (Caddy certs, Mealie data,
  Paperless data/media/export/db/redis).

## Hardening

Baseline hardening runs on every play, before the container runtime:

- **SSH hardening** — root login and password authentication disabled
  (key-only).
- **fail2ban** — bans IPs after repeated failed SSH logins.
- **Automatic patching** — a weekly systemd timer runs `zypper patch`.
  Auto-reboot is **off**; reboot on your own schedule after kernel updates.
- **Host firewall** — `firewalld`, default-deny inbound, allowing only
  SSH / Samba / HTTP / HTTPS. See
  [`roles/firewall/README.md`](roles/firewall/README.md).

See [`roles/security/README.md`](roles/security/README.md) for the
"don't lock yourself out" checklist.

## Services

| Service | How | Notes |
|---------|-----|-------|
| Samba | Native openSUSE service (`smbd`/`nmbd`) | Guest-only share, no user accounts — anyone on the network can read/write. See [`roles/samba/README.md`](roles/samba/README.md). |
| Caddy | Podman Quadlet, custom-built image | Automatic HTTPS via **DNS-01** (Cloudflare) — this host has no public inbound port, so HTTP-01 won't work; creates the shared `caddy.network`. See [`roles/caddy/README.md`](roles/caddy/README.md). |
| Mealie | Podman Quadlet, behind Caddy | Pocket ID OIDC login. |
| Paperless-ngx | Podman Quadlets (app + Redis + PostgreSQL), behind Caddy | Pocket ID OIDC login; inbox lives inside the Samba share. |
| Homepage | Podman Quadlet, behind Caddy | Dashboard linking this NAS's and cloud-wahlberger-dev's services. `rpi-karlsruhe` excluded (legacy). See [`roles/homepage/README.md`](roles/homepage/README.md). |

**Before the first run:** point `recipes.de.int.wahlberger.dev`,
`docs.de.int.wahlberger.dev`, and `www.de.int.wahlberger.dev` at wherever
clients actually reach this host (its LAN IP — reachable transparently over
ZeroTier too, via the router) — DNS-01 doesn't need a public IP, unlike
HTTP-01. If migrating the first two hostnames from `rpi-karlsruhe`, do the DNS
cutover only once this playbook has successfully run and you've verified the
new instances.

## Adding a containerized service

Same pattern as `cloud-wahlberger-dev`: create `roles/<svc>/` (underscore, not
hyphen — ansible-lint), put a templated unit at
`roles/<svc>/templates/<svc>.container.j2`, then `include_role: container`
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
`vault.yml.example` for the exact keys this playbook needs (Paperless's DB
password, both apps' OIDC client secrets, and the Cloudflare DNS API token).
Surface each under a friendly name in `vars.yml` (already done). By default
the vault password is fetched from 1Password automatically — see
`.vault_pass.sh` (requires the `op` CLI signed in and the desktop app
unlocked). Without 1Password, fall back to:

```sh
ansible-playbook site.yml --ask-vault-pass
# or: echo 'my-vault-password' > .vault_pass && ansible-playbook site.yml --vault-password-file .vault_pass
```

**Migrating secrets from rpi-karlsruhe?** Reuse the *existing* values for
`vault_paperless_ngx_db_password`, `vault_paperless_ngx_oidc_client_secret`,
`vault_mealie_oidc_client_secret`, and `vault_cloudflare_dns_api_token` —
these hostnames, their OIDC client registrations in Pocket ID, and the
Cloudflare zone are all unchanged, and a restored Paperless database dump
won't authenticate against a newly generated DB password.

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
- [openSUSE firewalld wiki](https://en.opensuse.org/openSUSE:Firewalld)
- [Samba guest access documentation](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html)
