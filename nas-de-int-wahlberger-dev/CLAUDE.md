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
- Idempotency + deprecation-warning check (CI, and locally with Docker):
  `molecule test`. Converges `common`, `notify_failure`, `disk_space`,
  `ssh_authorized_keys`, `security` twice against a disposable openSUSE
  Tumbleweed + systemd container (custom `molecule/default/Dockerfile.j2`)
  and fails on any `changed` the second time or any ansible-core
  deprecation warning. Deliberately excludes roles needing real mounted
  drives, Podman-in-Docker, or a real firewalld backend (firewalld's
  nftables integration doesn't work inside any container, host-independent)
  — see `molecule/default/converge.yml`. It also excludes `backup_disk`, `btrbk`,
  `db_dump` and `restic_server` (need a real block device, btrfs
  subvolumes, Podman, firewalld); those are proven on the VM fixture. It does
  converge `restic_backup_decommission` (no-op path).
- Render check: `tests/render-check.sh [-e k=v ...]` renders templates
  (registered in `tests/render.d/NN-<name>.yml`) with the `inventories/vm`
  fixture overrides and verifies them in a disposable Tumbleweed container
  (`btrbk config print`, `systemd-analyze verify`); needs docker or podman.
  `tests/syntax-check-role.sh <role>` syntax-checks an unwired role.
- VM fixture: `inventories/vm` (one host, fake secrets only), e.g.
  `ansible-playbook -i inventories/vm --list-hosts site.yml`; see its README.
- Requirements live in `reqs/` (one file per feature, `reqs/index.md` first);
  backup feature IDs are prefixed `BD-`. Plans: `PLAN.md`, `PLAN-backup.md`.

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
| `common` | zypper update, baseline packages, timezone, persistent systemd journal |
| `notify_failure` | Emails via Resend when a monitored systemd unit's OnFailure= fires. Wired (`OnFailure=notify-failure-immediate@%n`) to `btrbk.service`, `db-dump.service`, `restic-server-maintenance.service`, `backup-disk-health.service` (and `restic-server.service` via the flap-limited `notify-failure@%n`), plus the smartd hook (`backup-disk-smartd-notify.sh`, uses its Resend env file) |
| `smartd` | Shared smartd setup: smartmontools, Resend mail hook (`/usr/local/bin/smartd-notify.sh`), `smartd.service`, and one `smartd.conf` line per `smartd_devices` entry before `DEVICESCAN` (default: main data HDD). Ungated; `backup_disk` reuses the hook and adds its own line. |
| `disk_space` | Periodic disk usage check (systemd timer), emailing via `notify_failure` on a new threshold crossing. |
| `security` | SSH hardening, fail2ban, weekly `zypper patch` timer, automatic reboot via rebootmgr when needed (hand-rolled; no openSUSE geerlingguy.security) |
| `reboot_notify` | Emails a heads-up (reusing `notify_failure`'s Resend credentials; its own notification class, not a failure alert) as soon as a rebootmgr-triggered reboot is known to be needed. |
| `firewall` | firewalld, default-deny inbound, allows ssh/samba/http/https + the beszel_agent port |
| `storage` | Mounts the two existing btrfs subvolumes (`/mnt/containers`, `/mnt/data`) by UUID, persisted in `/etc/fstab`. Does NOT format/create them |
| `snapper` | Btrfs snapshot configs for those same two subvolumes (hourly/daily/weekly/monthly/yearly retention), timeline + cleanup timers |
| `podman` | Podman + Quadlet support, `/mnt/containers` data dir (a separately mounted disk), `podman.socket` |
| `beszel_agent` | Beszel monitoring agent — native systemd service (not a container), reports to `beszel_hub` on cloud-wahlberger-dev |
| `cloudflare_dns` | Ensures this host's A record + a CNAME per `caddy_sites` entry exist in Cloudflare |
| `caddy` | Caddy reverse proxy, **custom-built image** (Cloudflare DNS module baked in via xcaddy, see `roles/caddy/files/Containerfile`); auto HTTPS via **DNS-01** (this host has no public inbound port for HTTP-01); creates the shared `caddy.network` |
| `samba` | **Native** Samba (`smbd`/`nmbd`), guest-only share at `/mnt/data/samba` (the `samba/` subdirectory of the `/mnt/data` mount) — deliberately NOT a Podman container, unlike rpi-karlsruhe's `dockurr/samba` image |
| `tandoor` | Tandoor recipe manager (Postgres + app, image pinned). Pocket ID OIDC login |
| `paperless_ngx` | Paperless-ngx (Redis + PostgreSQL + app, image pinned). Pocket ID OIDC login; inbox inside the Samba share |
| `immich` | Immich photo/video backup (Valkey + PostgreSQL/vectorchord + machine learning + app). Pocket ID OIDC login via a config file (not env vars); QuickSync/OpenVINO hardware acceleration on the host's iGPU |
| `forgejo` | Forgejo git forge + built-in OCI registry (rootless image, SQLite, image pinned). Pocket ID OIDC login; git SSH on published port 2222; DB dumped via host `sqlite3 .backup` by `db_dump` |
| `homepage` | Homepage dashboard behind Caddy — static grouped links + ping status, no API keys, no Podman socket exposed. Links cloud-wahlberger-dev's services too (Pocket ID, FreshRSS); rpi-karlsruhe excluded (legacy) |
| `backup_disk` | Local 6 TB backup disk (btrfs, subvolume `@btrbk` mounted at `/mnt/backup/btrbk`): mount, scrub, smartd + hook, daily health check. **Never formats**; only `backup_disk_init.yml` does. Gated by `backup_disk_enabled` |
| `btrbk` | Daily btrbk snapshots of `/mnt/data` (incl. the restic repos) and `/mnt/containers`, replicated to the backup disk; pinned, fingerprint-checked OBS repo; a weekly `btrbk-key-refresh.timer` renews the repo signing key and emails when it nears expiry or the fingerprint changes. Gated by `backup_disk_enabled` |
| `db_dump` | Pre-btrbk consistent dumps (`pg_dump` per Postgres container, `sqlite3 .backup` for Forgejo) into `/mnt/containers/db-dumps/`. Gated by `backup_disk_enabled` |
| `restic_server` | restic `rest-server` Quadlet at `/mnt/data/restic-repos`, append-only, quota, firewalld-restricted to `restic_server_allowed_sources`; daily maintenance run at 06:00, RandomizedDelaySec=5min (forget/prune/check, prune guard). The cloud host backs up to it. Gated by `backup_disk_enabled` |
| `restic_backup_decommission` | Idempotently removes the old NAS-to-Pi restic job (replaces the former `restic_backup` role). Gated by `restic_backup_decommission_enabled` |
| `container` | Generic helper: renders one `.container` Quadlet template and restarts on change. Included by service roles, not listed in `site.yml`. |

No `zerotier` role: ZeroTier is configured transparently for the whole LAN at
the router, so this host doesn't need its own client.

## Continuity with rpi-karlsruhe

This playbook **replaces** rpi-karlsruhe's `mealie` and `paperless-ngx` roles
at the **same hostnames** (`recipes.de.int.wahlberger.dev`,
`docs.de.int.wahlberger.dev`). Paperless-ngx kept the **same Pocket ID OIDC
client registration** — `vars.yml` hardcodes the same `client_id` on purpose.
The recipe manager at `recipes.de.int.wahlberger.dev` has since moved from
Mealie to Tandoor (see `roles/tandoor/README.md`), which deliberately
registers a **new** Pocket ID client rather than reusing Mealie's. When
migrating Paperless-ngx:

- Reuse rpi-karlsruhe's `vault_paperless_ngx_db_password`,
  `vault_paperless_ngx_oidc_client_secret`, and
  `vault_cloudflare_dns_api_token` values verbatim — new ones won't
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
  plaintext secrets. Secrets here: DB passwords, OIDC client secrets,
  Tandoor's Django secret key, Forgejo's four generated keys and admin
  password, `vault_restic_server_cloud_htpasswd_password` and
  `vault_restic_server_cloud_repo_password` (must equal cloud's
  `vault_restic_backup_rest_server_password` / `vault_restic_backup_repo_password`),
  and the Cloudflare DNS API token — Samba itself needs none, being guest-only.
  `vault_restic_backup_repo_password` and `vault_restic_backup_rest_server_password`
  are **restore-only**, kept to read the Pi's frozen `nas` restic repository; no
  role uses them.
- Backup disk (third disk): `@btrbk` mounted at `/mnt/backup/btrbk`.
  **Only `backup_disk_init.yml` formats the backup disk** (separate
  playbook, never imported by `site.yml`, needs `-e backup_disk_init_confirm=<by-id path>`).
  Restic repositories live on `/mnt/data/restic-repos`, so btrbk covers them.
- Cut-over flags in `inventories/production/group_vars/all/vars.yml`, both
  default `false`, applied as `when:` in `site.yml`: `backup_disk_enabled`
  (backup_disk, btrbk, db_dump, restic_server) and
  `restic_backup_decommission_enabled`. Runbook: README "Backups".

## Adding a containerized service

Create `roles/<svc>/` (underscore, not hyphen — ansible-lint), put a
templated unit at `roles/<svc>/templates/<svc>.container.j2`, then
`include_role: container` with `container_name` and `container_quadlet_src`.
Add `- role: <svc>` to `site.yml`. See `roles/container/README.md`.
