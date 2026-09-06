# cloud-wahlberger-dev Ansible Playbook

Single-host playbook targeting the Hetzner Cloud VM `cloud.wahlberger.dev`
(Debian 13). Runs a container stack on **Podman Quadlets** (not Docker, no
docker-compose); the main service is **Pocket ID** (passkey OIDC) behind a
**Caddy** reverse proxy. Built as the **reference design** for the other
playbooks in this repo — prefer copying its patterns over the older `rpi-*` ones.

## Entry point & commands

- Playbook: `site.yml` (top-level). Default inventory is set in `ansible.cfg`.
- Run: `ansible-playbook site.yml` (add `--check --diff` for a dry run). The vault password comes from 1Password automatically via `.vault_pass.sh` (`ansible.cfg`'s `vault_password_file`) — no `--ask-vault-pass` needed.
- Install deps first: `ansible-galaxy collection install -r requirements.yml` then `ansible-galaxy role install -r requirements.yml`.
- Validate: `yamllint .`, `ansible-lint`, `ansible-playbook site.yml --syntax-check`.

## Conventions (keep these when extending)

- **FQCN for every module** (`ansible.builtin.*`, `community.general.*`, …).
- **Roles are self-contained**: `defaults/`, `tasks/`, `meta/main.yml`,
  `meta/argument_specs.yml`, `README.md`. User vars go in `defaults/`.
- **Variables are role-prefixed** (`common_*`, `podman_*`, `container_*`).
- **No dependencies in `meta/main.yml`** — order roles in `site.yml`.
- **Idempotent**: built-in modules only; restart via change-notified handlers.
- **Lint target**: ansible-lint `production` profile (see `.ansible-lint`).
- **External roles**: pinned in `requirements.yml`, installed to `~/.ansible/roles`.
  `roles_path` is left at its default so local *and* galaxy roles both resolve.
- **ufw + Podman**: keep `firewall_forward_policy: ACCEPT` — rootful Podman
  published ports cross FORWARD, not INPUT, so the host firewall mainly guards
  host services; use the Hetzner Cloud Firewall for real ingress control.
- **Proxied web services**: add a `{ host, upstream }` entry to `caddy_sites`
  (group_vars) and re-run — routes live in Git, not container labels.
- Note: local control machine runs **ansible-core 2.16**, so use
  `ansible.builtin.systemd` (the `systemd_service` module name needs 2.17+).

## Stack

| Role | Purpose |
|------|---------|
| `common` | apt update/upgrade, baseline packages, timezone |
| `notify_failure` | Emails via Resend when a monitored systemd unit's OnFailure= fires. |
| `disk_space` | Periodic disk usage check (systemd timer), emailing via `notify_failure` on a new threshold crossing. |
| `ssh_authorized_keys` | Authorizes your personal SSH key plus Semaphore's dedicated automation key (both also authorized on the NAS and the Pi) |
| `geerlingguy.security` (external) | SSH hardening, fail2ban, unattended-upgrades. Tuned via `security_*` in group_vars; installed from Galaxy. |
| `reboot_notify` | Emails a heads-up (reusing `notify_failure`'s Resend credentials; its own notification class, not a failure alert) right before an unattended-upgrades-triggered reboot. Installs `needrestart` to maintain `/var/run/reboot-required`, which Debian has no other source for. |
| `firewall` | ufw host firewall, default-deny inbound, allows 22/80/443. |
| `podman` | Podman + Quadlet support, `/opt/podman` data dir, `podman.socket` |
| `cloudflare_dns` | Brings this host's already-existing Cloudflare records under Ansible management |
| `caddy` | Official Caddy reverse proxy; auto HTTPS (HTTP-01); creates the shared `systemd-caddy` network; routes from `caddy_sites`. |
| `pocket_id` | Pocket ID OIDC provider (image pinned). Internal only (1411); data in the `pocket-id` named volume (`/app/data`). |
| `freshrss` | FreshRSS RSS aggregator (image pinned). Internal only (80); login via Pocket ID OIDC; data in the `freshrss` named volume (`/var/www/FreshRSS/data`). |
| `container` | Generic helper: renders one `.container` Quadlet template and restarts on change. Included by service roles, not listed in `site.yml`. |

## Adding a service

Create `roles/<svc>/` (underscore, not hyphen — ansible-lint), put a templated
unit at `roles/<svc>/templates/<svc>.container.j2`, then `include_role: container`
with `container_name` and `container_quadlet_src`. Add `- role: <svc>` to
`site.yml`. See `roles/container/README.md`.

## Data & secrets

- Persistent container data: `/opt/podman/<service>/`.
- Secrets: encrypted `inventories/production/group_vars/all/vault.yml`, exposed
  via `{{ vault_* }}` indirection in `vars.yml`. Never commit plaintext secrets.
