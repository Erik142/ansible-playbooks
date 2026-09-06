# nas-de-int-wahlberger-dev Ansible Playbook

Single-host playbook targeting `nas.de.int.wahlberger.dev`, an **openSUSE
Tumbleweed** NAS. Modeled on the `cloud-wahlberger-dev` reference design, not
copied from `rpi-karlsruhe`'s conventions — see that playbook's CLAUDE.md for
contrast (Debian, `apt`, `ufw`, `geerlingguy.security`, hyphenated role names).

## Entry point & commands

- Playbook: `site.yml` (top-level). Default inventory is set in `ansible.cfg`.
- Run: `ansible-playbook site.yml` (add `--check --diff` for a dry run). The vault password comes from 1Password automatically via `.vault_pass.sh` (`ansible.cfg`'s `vault_password_file`) — no `--ask-vault-pass` needed.
- Install deps first: `ansible-galaxy collection install -r requirements.yml`.
- Validate: `yamllint .`, `ansible-lint`, `ansible-playbook site.yml --syntax-check`.

## Conventions (keep these when extending)

- **FQCN for every module** (`ansible.builtin.*`, `community.general.*`, …).
- **Roles are self-contained**: `defaults/`, `tasks/`, `meta/main.yml`,
  `meta/argument_specs.yml`, `README.md`. User vars go in `defaults/`.
- **Variables are role-prefixed** (`common_*`, `podman_*`, `samba_*`, …).
- **No dependencies in `meta/main.yml`** — order roles in `site.yml`.
- **Idempotent**: built-in modules only; restart via change-notified handlers.
- **Lint target**: ansible-lint `production` profile (see `.ansible-lint`).
- **openSUSE, not Debian**: package installs use `community.general.zypper`,
  not `ansible.builtin.apt`. Service names differ too — sshd is `sshd` (not
  `ssh`), Samba is `smb`/`nmb` (not a single `samba` service).
- **No external Galaxy roles**: `geerlingguy.security` (used by
  cloud-wahlberger-dev) doesn't target openSUSE, so hardening is hand-rolled
  in the `security` role instead.
- **firewalld, not ufw**: rootful Podman's published ports still need
  masquerading enabled on the zone, same underlying reason as
  cloud-wahlberger-dev's `firewall_forward_policy: ACCEPT` — see
  `roles/firewall/README.md`.
- Local control machine runs **ansible-core 2.16**, so use
  `ansible.builtin.systemd` (the `systemd_service` module name needs 2.17+).

## Stack

| Role | Purpose |
|------|---------|
| `common` | zypper update, baseline packages, timezone |
| `notify_failure` | Emails via Resend when a monitored systemd unit's OnFailure= fires. Wired to `restic_backup`'s service |
| `disk_space` | Periodic disk usage check (systemd timer), emailing via `notify_failure` on a new threshold crossing. |
| `security` | SSH hardening, fail2ban, weekly `zypper patch` timer (hand-rolled; no openSUSE geerlingguy.security) |
| `firewall` | firewalld, default-deny inbound, allows ssh/samba/http/https |
| `storage` | Mounts the two existing btrfs subvolumes (`/mnt/containers`, `/mnt/data`) by UUID, persisted in `/etc/fstab`. Does NOT format/create them |
| `snapper` | Btrfs snapshot configs for those same two subvolumes (hourly/daily/weekly/monthly/yearly retention), timeline + cleanup timers |
| `podman` | Podman + Quadlet support, `/mnt/containers` data dir (a separately mounted disk), `podman.socket` |
| `cloudflare_dns` | Ensures this host's A record + a CNAME per `caddy_sites` entry exist in Cloudflare |
| `caddy` | Caddy reverse proxy, **custom-built image** (Cloudflare DNS module baked in via xcaddy, see `roles/caddy/files/Containerfile`); auto HTTPS via **DNS-01** (this host has no public inbound port for HTTP-01); creates the shared `caddy.network` |
| `samba` | **Native** Samba (`smbd`/`nmbd`), guest-only share at `/mnt/data/samba` (the `samba/` subdirectory of the `/mnt/data` mount) — deliberately NOT a Podman container, unlike rpi-karlsruhe's `dockurr/samba` image |
| `mealie` | Mealie recipe manager. Pocket ID OIDC login |
| `paperless_ngx` | Paperless-ngx (Redis + PostgreSQL + app, image pinned). Pocket ID OIDC login; inbox inside the Samba share |
| `homepage` | Homepage dashboard behind Caddy — static grouped links + ping status, no API keys, no Podman socket exposed. Links cloud-wahlberger-dev's services too (Pocket ID, FreshRSS); rpi-karlsruhe excluded (legacy) |
| `restic_backup` | Nightly restic backup of the Samba share and container data to pi-de-int-wahlberger-dev's `restic_server`, via a systemd timer |
| `container` | Generic helper: renders one `.container` Quadlet template and restarts on change. Included by service roles, not listed in `site.yml`. |

No `zerotier` role: ZeroTier is configured transparently for the whole LAN at
the router, so this host doesn't need its own client.

## Continuity with rpi-karlsruhe

This playbook **replaces** rpi-karlsruhe's `mealie` and `paperless-ngx` roles
at the **same hostnames** (`recipes.de.int.wahlberger.dev`,
`docs.de.int.wahlberger.dev`) and the **same Pocket ID OIDC client
registrations** — `vars.yml` hardcodes the same `client_id` values on
purpose. When migrating:

- Reuse rpi-karlsruhe's `vault_paperless_ngx_db_password`,
  `vault_paperless_ngx_oidc_client_secret`, `vault_mealie_oidc_client_secret`,
  and `vault_cloudflare_dns_api_token` values verbatim — new ones won't
  authenticate against a restored DB dump, the existing Pocket ID client, or
  the existing Cloudflare zone token's scope.
- Cut DNS over only after this playbook has run successfully and you've
  verified the new instances.
- Retire the corresponding roles in `rpi-karlsruhe/main.yml` yourself
  afterwards (`samba`, `paperless-ngx`, `mealie`) — this playbook does not
  touch that host.

## Data & secrets

- Two separately mounted btrfs disks, mounted by the `storage` role (which
  does not format them — both already existed) and re-asserted as real
  mountpoints before use in `roles/podman/tasks/main.yml` and
  `roles/samba/tasks/main.yml`: `/mnt/data` (only its `samba/` subdirectory
  is actually shared) and `/mnt/containers/` (everything else). Snapshotted
  by the `snapper` role.
- Secrets: encrypted `inventories/production/group_vars/all/vault.yml`,
  exposed via `{{ vault_* }}` indirection in `vars.yml`. Never commit
  plaintext secrets. Four secrets exist here — DB password, two OIDC client
  secrets, and the Cloudflare DNS API token — Samba itself needs none, being
  guest-only.

## Adding a containerized service

Create `roles/<svc>/` (underscore, not hyphen — ansible-lint), put a
templated unit at `roles/<svc>/templates/<svc>.container.j2`, then
`include_role: container` with `container_name` and `container_quadlet_src`.
Add `- role: <svc>` to `site.yml`. See `roles/container/README.md`.
