# n8n

[n8n](https://n8n.io/) workflow automation, **phase 1 of the AI incident
remediation pipeline**: the editor only, no workflows. Rootful Podman Quadlet
joined to `caddy.network`, reverse-proxied by the `caddy` role at
`n8n.de.int.wahlberger.dev`. LAN/ZeroTier only (no public inbound port).

Decision record: [`PLAN-n8n.md`](../../PLAN-n8n.md) (host, phases, verified
facts). ADR: [`architecture/ai-incident-remediation-pipeline.md`](../../../architecture/ai-incident-remediation-pipeline.md).

## Units

| Unit | Image | Role |
|------|-------|------|
| `n8n.service` | `docker.io/n8nio/n8n:2.47.4` (pinned) | Editor and workflow engine, SQLite, port 5678 on `caddy.network`, no published ports |
| `oauth2-proxy.service` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.5` | Pocket ID login for the editor (Caddy `forward_auth`) |

Limits on `n8n.service`: `MemoryMax=2G`, `CPUQuota=200%`.

## Routing (Caddy vhost)

| Path | Behaviour |
|------|-----------|
| `/webhook/hush` | Reverse-proxied to n8n with no Pocket ID check. Authentication is the HMAC check in the workflow (phase 2). |
| `/oauth2/*` | oauth2-proxy |
| everything else | `forward_auth` to oauth2-proxy, then n8n. Unauthenticated requests redirect to sign-in. |

The vhost is defined in `inventories/production/group_vars/all/vars.yml` (`caddy_sites_base`).

## Data and secrets

- `/mnt/containers/n8n/data` (mounted at `/home/node/.n8n`, owner `1000:1000`).
  Covered by `btrbk` and snapper like the other `/mnt/containers` services.
- `/mnt/containers/n8n/n8n.env` (root, 0600): `N8N_ENCRYPTION_KEY`.
- `/mnt/containers/n8n/oauth2-proxy.env` (root, 0600): OIDC client secret, cookie secret.

Vault keys (see `vault.yml.example`):

| Key | Purpose |
|-----|---------|
| `vault_n8n_encryption_key` | Encrypts all n8n credentials. **Back up in 1Password as well as the vault.** Losing it loses every stored credential. |
| `vault_n8n_oidc_client_secret` | Pocket ID client secret for the editor |
| `vault_n8n_oauth2_cookie_secret` | oauth2-proxy cookie secret (16, 24 or 32 bytes) |

The owner account is created in the first-run UI, behind Pocket ID. No owner
password is stored in the vault.

## Manual steps before the first deploy

1. Register a Pocket ID client with redirect URI
   `https://n8n.de.int.wahlberger.dev/oauth2/callback`.
2. Put its UUID in `n8n_oidc_client_id` (`vars.yml`) and its secret in
   `vault_n8n_oidc_client_secret`. The role's assert fails until both are set.
3. After the first deploy, sign in through Pocket ID, then create the n8n owner in the setup screen.

## Not covered yet (later phases)

- `db_dump` coverage: not added. btrfs snapshots are crash-consistent, but a
  logical dump would be cleaner. Decide in phase 2.
- Hush webhook secret, remediation reply secret, diag SSH key, GitHub token,
  Anthropic key: phase 2.
- `N8N_PUBLIC_API_DISABLED`: not set. Its documented meaning contradicts its name; verify on 2.47.4 first.
- `N8N_RESTRICT_FILE_ACCESS_TO`: set to the data dir. Verify on the running version (subdirectory handling is reported as fiddly).
