# n8n

[n8n](https://n8n.io/) workflow automation, **phase 1 of the AI incident
remediation pipeline**: the editor only, no workflows. Rootful Podman Quadlet
joined to `caddy.network`, reverse-proxied by the `caddy` role at
`n8n.de.int.wahlberger.dev`. LAN/ZeroTier only (no public inbound port).

Decision record: `PLAN-n8n.md` (removed; see git history; host, phases, verified
facts). ADR: [`docs/ai-incident-remediation-pipeline.md`](../../../../docs/ai-incident-remediation-pipeline.md).

## Units

| Unit | Image | Role |
|------|-------|------|
| `n8n.service` | `docker.io/n8nio/n8n:2.50.2` (pinned) | Editor and workflow engine, SQLite, port 5678 on `caddy.network`, no published ports |
| `oauth2-proxy.service` | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.5` | Pocket ID login for the editor (Caddy `forward_auth`) |

Limits on `n8n.service`: `MemoryMax=2G`, `CPUQuota=200%`.

## Routing (Caddy vhost)

| Path | Behaviour |
|------|-----------|
| `/webhook/hush` | Reverse-proxied to n8n with no Pocket ID check. Authentication is the HMAC check in the workflow (phase 2). |
| `/oauth2/*` | oauth2-proxy |
| everything else | `forward_auth` to oauth2-proxy, then n8n. Unauthenticated requests redirect to sign-in. |

The vhost is defined in `inventories/nas/group_vars/all/vars.yml` (`caddy_sites_base`).

## Data and secrets

- `/mnt/containers/n8n/data` (mounted at `/home/node/.n8n`, owner `1000:1000`).
  Covered by `btrbk` and snapper like the other `/mnt/containers` services.
- `/mnt/containers/n8n/n8n.env` (root, 0600): `N8N_ENCRYPTION_KEY`.
- `/mnt/containers/n8n/oauth2-proxy.env` (root, 0600): OIDC client secret, cookie secret.

Vault keys (see `inventories/nas/group_vars/all/vault.yml.example`):

| Key | Purpose |
|-----|---------|
| `vault_n8n_encryption_key` | Encrypts all n8n credentials. **Back up in 1Password as well as the vault.** Losing it loses every stored credential. |
| `vault_n8n_oidc_client_secret` | Pocket ID client secret for the editor |
| `vault_n8n_oauth2_cookie_secret` | oauth2-proxy cookie secret (16, 24 or 32 bytes) |

The owner account is created in the first-run UI, behind Pocket ID. No owner
password is stored in the vault.

## Trusted-header login (one login, not two)

Editor login is Pocket ID, then n8n's own session. The trusted-header hook removes the second login:

1. oauth2-proxy admits only the emails in `n8n_allowed_emails` (vars.yml, currently one owner) and sets `X-Auth-Request-Email` on the `/oauth2/auth` response.
2. Caddy (`caddy_sites` entry for n8n) strips any client-supplied `X-Auth-Request-Email`, then copies the value from the oauth2-proxy response into the request.
3. `files/hooks.js` (loaded by `EXTERNAL_HOOK_FILES`) reads that header, finds the n8n user with the same email, and issues n8n's `n8n-auth` cookie. Unknown emails get 401.

Requirements, all enforced by the config above:

- The n8n owner's email must equal `n8n_allowed_emails` and the Pocket ID email. The hook does not create users.
- n8n must not be reachable except through Caddy. It has no published port. Anyone who can send the header directly can log in as that user.
- The hook uses n8n internals (cookie-parser layer, `AuthService.issueJWT/issueCookie`, the `n8n-auth` cookie). It is not a supported n8n feature.

Compatibility: when bumping `n8n_image`, check the hook by hand against the new image (owner setup, header login, unknown user, cookie flow). If the hook stops loading, the hook logs `disabled` or errors, and API calls without the cookie return 401. Nothing gets through by accident.

## Triage workflow (phase 2a)

Design: `docs/n8n-triage-workflow.md`. The workflow is `files/triage-workflow.json`, deployed to `{{ n8n_data_dir }}/triage-workflow.json`. Import is manual, because n8n has no declarative import at boot.

One-time setup on the NAS (after deploy):

1. Create the SSH credential in n8n's CLI import, from the vault key `vault_n8n_diag_ssh_key`, with id `n8ndiagssh01`, name `n8n-diag`, host `nas.de.int.wahlberger.dev`, port 22, user `n8n-diag`, `sshAuthenticateWith: privateKey`. The public half is `n8n_diag_public_key` (vars.yml), already authorised with the forced command.
2. Import and activate the workflow with the n8n CLI in a one-off container on the same volume, with n8n stopped (`import:credentials`, `import:workflow`, `update:workflow --id=n8ntriage01 --active=true`). These steps are manual.
3. Hush: the webhook secret in ops (`hush_n8n_webhook`) must equal `vault_n8n_hush_secret` here. Hush's `notifications.webhook` and `remediation` config are in the spec.

The Anthropic key is `vault_n8n_anthropic_key`. It is a placeholder until replaced.

## Manual steps before the first deploy

1. Register a Pocket ID client with redirect URI
   `https://n8n.de.int.wahlberger.dev/oauth2/callback`.
2. Put its UUID in `n8n_oidc_client_id` (`vars.yml`) and its secret in
   `vault_n8n_oidc_client_secret`. The role's assert fails until both are set.
3. After the first deploy, sign in through Pocket ID, then create the n8n owner in the setup screen.

## Not covered yet (later phases)

- `db_dump` coverage: not added. btrfs snapshots are crash-consistent, but a
  logical dump would be cleaner. Decide in phase 2.
- Hush remediation reply secret (phase 2b, alert handoffs): diag SSH key, GitHub token,
  Anthropic key: phase 2.
- `N8N_PUBLIC_API_DISABLED`: not set. Its documented meaning contradicts its name; verify on 2.47.4 first.
- `N8N_RESTRICT_FILE_ACCESS_TO`: set to the data dir. Verify on the running version (subdirectory handling is reported as fiddly).
