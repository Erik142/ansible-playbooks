# hush

Deploys [Hush](https://git.de.int.wahlberger.dev/erikwahlberger/hush), the
homelab alerting service, as a rootful Podman Quadlet on the ops VM.

In `site.yml` after `semaphore`. SH-FR-13 was amended on 2026-10-24 to list it
(`semaphore-migration/reqs/semaphore-to-hetzner.md`). Served over ZeroTier only:
`hush.de.int.wahlberger.dev` is a CNAME to `ops.de.int` (via `caddy_sites` and
`cloudflare_dns`), which resolves to `vm_zt_ip`.

## Inputs

| Variable | Source | Notes |
|---|---|---|
| `hush_forgejo_pull_token` | `vault_hush_forgejo_pull_token` | Forgejo token, `read:package` only. Root's registry login. |
| `hush_secrets` | one `vault_hush_*` per name in `hush_secret_names` | 12 values. Each must be non-empty. |
| `hush_alert_recipient` | group_vars | E-mail address Hush sends to. |
| `hush_heartbeat_url` | Healthchecks.io check | Replaces the REPLACE placeholder. |
| `hush_allowed_groups` | Pocket ID | Groups whose members may log in (`hush_admins`). Must not be empty. |
| `hush_image` | defaults | `git.de.int.wahlberger.dev/erikwahlberger/hush:0.4.2`. |

The role refuses to run while any input is empty or still holds a `REPLACE`
placeholder.

## Layout on the VM

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/opt/podman/hush/data` | 10001 | 0750 | SQLite database, backups |
| `/opt/podman/hush/secrets/<name>` | 10001 | 0400 | Mounted read-only at `/run/secrets/<name>` |
| `/opt/podman/hush/config.yaml` | root:10001 | 0640 | Rendered from `hush_config` |

The container runs as uid 10001 (`Containerfile`). Port 8080 is published on
`127.0.0.1` only.

## Decisions

- **Secrets as files, not `podman secret`.** A Podman secret cannot be updated
  in place, so each run would have to recreate it, and the container would have
  to restart. A file changes only when its content does.
- **Registry login as root** (`podman_login`), because the Quadlet is a
  system unit.
- **Trusted proxy is `127.0.0.1/32`.** Caddy runs on the host network, so hush
  sees Caddy as loopback. The Traefik network in `deploy/hush.container` no
  longer applies.
- **Shadow mode on** (`hush_shadow_mode: true`) for the first week.

## Open points

- **Secrets in Vault.** The twelve `vault_hush_*` keys are in the manifest and the
  scaffold. Nine are generated, three are typed by hand (Anthropic key, Resend key,
  Pocket ID client secret). The real `vault.yml` still has to be rebuilt with
  `tools/populate-vault.sh --force`. Each generated secret also has to be entered in
  its consumer: the Kuma webhook (`vault_hush_source_kuma`), the hook scripts
  (`hooks_*`), restic (`backup_*`) and the maintenance client (`maintenance_ansible`).
- **Placeholders in group_vars.** The Healthchecks URL is now in Vault. The Pocket ID
  access rule is the group `hush_admins` (`hush_allowed_groups`); create that group in
  Pocket ID and add the users who should reach the dashboard.
  The Pocket ID client redirect URI must become
  `https://hush.de.int.wahlberger.dev/auth/callback`.
- **`notify_failure` wiring** on the hush unit is left out until the migration
  step for `notify_failure`.
- **Break-glass.** `vault_hush_break_glass_hash` is a random string, not a password
  hash. It is inert while `break_glass.enabled` is false. Replace it with a real
  hash before enabling break-glass.
