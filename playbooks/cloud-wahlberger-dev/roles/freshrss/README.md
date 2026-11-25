# freshrss

Runs [FreshRSS](https://freshrss.org) — a self-hosted RSS/Atom aggregator — as a
Podman Quadlet. It listens on **80** internally, is **not** published to the
host, and is reached only via the `caddy` reverse proxy over the shared
`systemd-caddy` network. Login is delegated to **Pocket ID** via OpenID Connect.

## How auth is wired

OIDC happens at the **Apache** layer via `mod_auth_openidc` (enabled by the
image when `OIDC_ENABLED` is set), *not* inside FreshRSS. Apache performs the
Pocket ID round-trip and passes the authenticated identity to FreshRSS as
`REMOTE_USER`. FreshRSS only trusts that if its login method is **HTTP
Authentication** — hence `FRESHRSS_INSTALL` sets `--auth-type http_auth`. Without
it FreshRSS installs in `form` mode and you get a *second* login form after the
Pocket ID login (it ignores `REMOTE_USER`).

Two more constraints:

- **FreshRSS does not auto-create users from OIDC.** The username must equal the
  OIDC `preferred_username` claim **exactly** (lowercase), so the entrypoint
  pre-creates an admin named `freshrss_admin_user` — which must be your Pocket ID
  username.
- **`--auth-type` is only applied on a *fresh* install.** The entrypoint runs
  `do-install` once; changing it later requires either the FreshRSS UI
  (Settings → Authentication → HTTP) or wiping the `freshrss` volume to
  reinstall.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `freshrss_image` | `docker.io/freshrss/freshrss:1.29.1` | Image (pinned). |
| `freshrss_volume` | `freshrss` | Named volume at `/var/www/FreshRSS/data`. |
| `freshrss_data_dir` | `/opt/podman/freshrss` | Host dir for the 0600 env file. |
| `freshrss_app_url` | _(required)_ | Public `https://` URL; set in `group_vars`. |
| `freshrss_admin_user` | _(required)_ | Admin user = your Pocket ID username (lowercase). |
| `freshrss_admin_email` | `""` | Optional email on the admin account. |
| `freshrss_language` | `en` | UI/install language. |
| `freshrss_timezone` | `Europe/Stockholm` | Container `TZ`. |
| `freshrss_cron_min` | `13,43` | Feed-refresh cron minutes; `""` disables. |
| `freshrss_trusted_proxy` | `10.88.0.0/16 10.89.0.0/16` | CIDR(s) trusted as the proxy. |
| `freshrss_oidc_provider_metadata_url` | `{{ pocket_id_app_url }}/.well-known/openid-configuration` | OIDC discovery URL. |
| `freshrss_oidc_client_id` | _(required)_ | Client ID from Pocket ID. |
| `freshrss_oidc_scopes` | `openid email profile` | Requested scopes. |
| `freshrss_oidc_remote_user_claim` | `preferred_username` | Claim → FreshRSS username. |
| `freshrss_oidc_x_forwarded_headers` | `X-Forwarded-Proto X-Forwarded-Host` | Trusted forwarded headers. |

## Secrets

Three secrets feed the 0600 env file at `{{ freshrss_data_dir }}/freshrss.env`,
all kept in **Ansible Vault** (`group_vars/all/vault.yml`, structure in
`vault.yml.example`) and surfaced in `vars.yml`:

- `vault_freshrss_oidc_client_secret` — issued by Pocket ID; copy it from the
  admin UI after registering the FreshRSS client.
- `vault_freshrss_oidc_crypto_key` — internal key. `openssl rand -hex 32`.
- `vault_freshrss_admin_password` — break-glass admin password (alphanumeric).

The role asserts these (plus `freshrss_admin_user` / `freshrss_oidc_client_id`)
are non-empty and fails with guidance otherwise. On the host they only ever
exist in the root-only `0600` env file.

## One-time setup (operator)

1. **DNS**: point `freshrss_app_url`'s host at the VM, **DNS-only (grey cloud)**,
   so Caddy can issue the cert over HTTP-01.
2. **Pocket ID**: register an OIDC client (name `FreshRSS`, callback
   `https://<host>/i/oidc/`). Copy the **Client ID** → `freshrss_oidc_client_id`
   in `group_vars`; copy the **Client Secret** → `vault_freshrss_oidc_client_secret`
   in Vault. If the client is **restricted to a group**, add your Pocket ID user
   to that group, or login fails before it ever reaches FreshRSS.
3. **Username**: set `freshrss_admin_user` to your **lowercase** Pocket ID
   username.
4. **Vault**: add the crypto key and admin password (see `vault.yml.example`).

Then `ansible-playbook site.yml --tags caddy,freshrss --ask-vault-pass`, open
`freshrss_app_url`, and log in with Pocket ID.

## Break-glass login

If OIDC ever breaks (Pocket ID down, claim mismatch), the local admin password
(`vault_freshrss_admin_password`) still works at `https://<host>/i/?c=auth` —
recover, fix, and recreate.

## Feed refresh

Auto-refresh is **off in the image by default** and is enabled here via
`CRON_MIN` (`freshrss_cron_min`, default `13,43` → twice an hour). Two layers
decide how fresh feeds are:

- **`freshrss_cron_min`** — how often the container's cron *checks* for feeds due
  to refresh (the upper bound). A change only needs `--tags freshrss` (it's read
  at container start, not tied to install).
- **Per-feed / global minimum interval** — set in the FreshRSS UI
  (Settings → Archiving, and each feed's settings). A feed is not pulled more
  often than its own interval, regardless of how often cron runs.

You can always refresh on demand with the UI's "Actualize" button.

## Data & backups

The `freshrss` named volume holds the **SQLite database and `config.php`** —
that is the thing to back up.

## Depends on

The `caddy` role must run first (creates the shared network + terminates TLS),
and `pocket_id` must be reachable at `pocket_id_app_url` for the OIDC discovery
URL to resolve.
