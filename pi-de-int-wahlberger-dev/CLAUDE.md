# pi-de-int-wahlberger-dev Ansible Playbook

Single-host playbook targeting `pi.de.int.wahlberger.dev`, a Raspberry Pi at
home running Raspberry Pi OS (Debian 13 "Trixie"). Runs Semaphore UI, the
automation host that runs `ansible-playbook` against this host,
`nas-de-int-wahlberger-dev`, and `cloud-wahlberger-dev`.

## Entry point & commands

- Playbook: `site.yml` (top-level). Default inventory is set in `ansible.cfg`.
- Run: `ansible-playbook site.yml` (add `--check --diff` for a dry run). The vault password comes from 1Password automatically via `.vault_pass.sh` (`ansible.cfg`'s `vault_password_file`) — no `--ask-vault-pass` needed.
- Install deps first: `ansible-galaxy collection install -r requirements.yml` then `ansible-galaxy role install -r requirements.yml`.
- Validate: `yamllint .`, `ansible-lint`, `ansible-playbook site.yml --syntax-check`.

## Conventions (keep these when extending)

- **FQCN for every module** (`ansible.builtin.*`, `community.general.*`, …).
- **Roles are self-contained**: `defaults/`, `tasks/`, `meta/main.yml`,
  `meta/argument_specs.yml`, `README.md`. User vars go in `defaults/`.
- **Variables are role-prefixed** (`common_*`, `podman_*`, `semaphore_*`, …).
- **No dependencies in `meta/main.yml`** — order roles in `site.yml`.
- **Idempotent**: built-in modules only; restart via change-notified handlers.
- **Lint target**: ansible-lint `production` profile (see `.ansible-lint`).
- **Debian, like cloud-wahlberger-dev**: `ansible.builtin.apt`, `ufw`,
  `geerlingguy.security` — NOT the NAS's openSUSE conventions
  (`zypper`/`firewalld`/hand-rolled hardening). Only `caddy` is copied from
  the NAS, because network position (home LAN, no public port) matters more
  here than OS family.
- Local control machine runs **ansible-core 2.16**, so use
  `ansible.builtin.systemd` (the `systemd_service` module name needs 2.17+).

## Stack

| Role | Purpose |
|------|---------|
| `common` | apt update/upgrade, baseline packages, timezone |
| `notify_failure` | Emails via Resend when a monitored systemd unit's OnFailure= fires. |
| `disk_space` | Periodic disk usage check (systemd timer), emailing via `notify_failure` on a new threshold crossing. |
| `ssh_authorized_keys` | Authorizes your personal SSH key plus Semaphore's dedicated automation key (both also authorized on cloud-wahlberger-dev and the NAS) |
| `geerlingguy.security` (external) | SSH hardening, fail2ban, unattended-upgrades. Also grants `erikwahlberger` passwordless sudo (`security_sudoers_passwordless`) — Semaphore can't type an interactive sudo password |
| `reboot_notify` | Emails a heads-up (reusing `notify_failure`'s Resend credentials; its own notification class, not a failure alert) right before an unattended-upgrades-triggered reboot. Installs `needrestart` to maintain `/var/run/reboot-required`, which Debian has no other source for. |
| `firewall` | ufw host firewall, default-deny inbound, allows 22/80/443 |
| `storage` | Mounts the external USB drive (stable `/dev/disk/by-id/...` path, `nofail` in fstab) at `/mnt/data`; does NOT format it — `storage_fstype` must be set to what's already on it |
| `podman` | Podman + Quadlet support, `/mnt/data/containers` data dir (inside the `storage` mount), `podman.socket` |
| `cloudflare_dns` | Ensures this host's A record + a CNAME per `caddy_sites` entry exist in Cloudflare |
| `caddy` | Caddy reverse proxy, **custom-built image** (Cloudflare DNS module via xcaddy — copied from the NAS's role, not cloud-wahlberger-dev's); auto HTTPS via **DNS-01** (this Pi has no public inbound port, same reasoning as the NAS); creates the shared `caddy.network` |
| `semaphore` | Semaphore UI (self-hosted Ansible runner), SQLite backend, Pocket ID OIDC login with a kept-deliberately local admin fallback |
| `restic_server` | restic REST server — the backup target nas-de-int-wahlberger-dev's `restic_backup` pushes to nightly. LAN/ZeroTier-only, never proxied through Caddy |
| `container` | Generic helper: renders one `.container` Quadlet template and restarts on change. Included by service roles, not listed in `site.yml`. |

## Why this host exists (the CI/CD reachability problem)

`cloud-wahlberger-dev` has a public IP; the NAS and this Pi are home-LAN-only
(reachable via ZeroTier). GitHub-hosted CI runners can't reach the latter
two. Rather than exposing anything inbound, Semaphore runs *inside* the
network it manages (on this already-idle Pi) and reaches all three hosts
over SSH using its own dedicated key. This also keeps the credentials that
can reach everything off the one machine most exposed to the internet
(`cloud-wahlberger-dev`) — see the top-level README's "Why this host exists"
for the full reasoning.

Prefer Semaphore's own internal polling/schedule over a git webhook trigger
— a webhook needs GitHub to reach *in* to this Pi (port-forwarding), which
defeats the point.

## Cross-host SSH keys

`ssh_authorized_keys_list` in `vars.yml` here must contain the exact same two
entries as in `cloud-wahlberger-dev`'s and the NAS's `vars.yml` — your
personal key (manual access) and Semaphore's dedicated automation keypair,
kept separate on purpose (see `roles/ssh_authorized_keys/README.md`). The
automation key's private half is never stored in any of these playbooks or
in Vault; it's pasted directly into Semaphore's Key Store after this
playbook deploys it (see `roles/semaphore/README.md`).

## Data & secrets

- `/mnt/data/containers/<service>/` — container data, on the external USB
  drive the `storage` role mounts (unlike cloud-wahlberger-dev's simple
  `/opt/podman`, this Pi has one). The drive holds unrelated existing data
  outside `containers/`, which `storage` never touches. Not asserted-only
  like the NAS's mounts — this role actually performs the mount + fstab entry
  itself, since the user explicitly wants it auto-mounted on boot.
- Secrets: encrypted `inventories/production/group_vars/all/vault.yml`,
  exposed via `{{ vault_* }}` indirection in `vars.yml`. Never commit
  plaintext secrets. Five secrets exist here: the Cloudflare DNS token,
  Semaphore's admin password, its access-key encryption key (MUST stay
  stable — rotating it orphans previously stored SSH keys/vault passwords in
  Semaphore's own database), its cookie keys, and its OIDC client secret.
- `ssh_authorized_keys_list` entries are NOT secrets (public keys) — they're a
  plain `vars.yml` value, duplicated identically across all three playbooks.

## Adding a containerized service

Create `roles/<svc>/` (underscore, not hyphen — ansible-lint), put a
templated unit at `roles/<svc>/templates/<svc>.container.j2`, then
`include_role: container` with `container_name` and `container_quadlet_src`.
Add `- role: <svc>` to `site.yml`. See `roles/container/README.md`.
