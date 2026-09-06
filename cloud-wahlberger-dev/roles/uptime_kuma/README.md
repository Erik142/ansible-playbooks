# uptime_kuma

Runs [Uptime Kuma](https://github.com/louislam/uptime-kuma) as a Podman
Quadlet behind Caddy, gated by [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/)
with Pocket ID as the OIDC provider. This is the external watcher for the
rest of the infrastructure — deliberately on `cloud-wahlberger-dev` (its own
power/network, independent of home), since nothing running *on* a host that
goes dark can report its own death (see `notify_failure`, which only covers
services crashing on a host that's still up).

## Why oauth2-proxy, not Uptime Kuma's own login

Uptime Kuma has no native OIDC/SSO support for its dashboard login (a 2025
PR adding it was rejected by the maintainer for code quality, and the
underlying feature request has been open since 2021). The officially
documented pattern for protecting it with an external identity provider —
recommended directly in Pocket ID's own docs — is: disable Uptime Kuma's
built-in auth entirely, and gate access with a reverse-proxy auth layer
instead. oauth2-proxy was picked over the alternative (`caddy-security`, a
Caddy plugin baking the same capability directly into Caddy) for stability:
it's a mature, independently-versioned project, where `caddy-security` has a
reputation for frequent breaking config changes between releases.

## How the request flow works

Caddy's `forward_auth` doesn't itself speak OIDC — Pocket ID is an identity
*provider*, not a forward-auth gatekeeper — so oauth2-proxy sits in between,
translating one into the other:

1. Browser requests `{{ uptime_kuma_url }}`.
2. Caddy's `forward_auth` (configured via `caddy_sites`' `extra`, see
   `roles/caddy/README.md`) asks oauth2-proxy's `/oauth2/auth` endpoint "is
   this request authenticated?"
3. Not yet → oauth2-proxy returns 401 → Caddy's `handle_response` redirects
   the browser to `/oauth2/sign_in`, which starts the OIDC flow against
   Pocket ID.
4. Pocket ID authenticates the user and redirects back to
   `{{ uptime_kuma_url }}/oauth2/callback` — routed by Caddy straight to
   oauth2-proxy (not through the auth check), which sets a session cookie
   and redirects to the original URL.
5. Now authenticated → Caddy's forward_auth check passes → Caddy proxies the
   request directly to `uptime-kuma:3001` itself. oauth2-proxy's own
   `--upstream` is never actually used for this — see the comment in
   `oauth2-proxy.env.j2`.

## Required manual steps after the first deploy

This role only gets the containers running — it can't drive Uptime Kuma's
own first-run setup wizard or click through its settings UI, so these are
one-time manual steps (same category as Semaphore's own Task Template setup
in `pi-de-int-wahlberger-dev`):

1. **Register the OIDC client in Pocket ID** *before* deploying — name it
   something like "Uptime Kuma (oauth2-proxy)", redirect URI exactly
   `{{ uptime_kuma_url }}/oauth2/callback`. Set the client ID in
   `uptime_kuma_oidc_client_id` (group_vars) and the secret in Vault as
   `vault_uptime_kuma_oidc_client_secret`.
2. **Deploy**, then visit `{{ uptime_kuma_url }}`. You'll hit the Pocket ID
   login first (the gate already works); once through, you'll land on
   Uptime Kuma's own first-run setup screen, since it hasn't been configured
   yet — create a local admin account here. This account becomes a
   break-glass fallback once the next step is done, not the real gate.
3. **Settings → Security → Advanced → Disable Auth** (confirm with the
   password you just set). Pocket ID is the real gate from here on;
   without this step you'd be logging in twice.
4. **Settings → Reverse Proxy → Trust Proxy → Yes**, so Uptime Kuma resolves
   real client IPs from Caddy's `X-Forwarded-For` instead of seeing every
   request as coming from the proxy.
5. **Configure actual monitors** through the UI or its API — this role
   deploys the app, not what it watches.

## Role variables

See `defaults/main.yml`. `uptime_kuma_url`, `uptime_kuma_oidc_client_id`,
`uptime_kuma_oidc_client_secret`, and `uptime_kuma_cookie_secret` are all
required. `uptime_kuma_cookie_secret` must be exactly 32 raw bytes,
base64-encoded — oauth2-proxy uses it as an AES-256 key and rejects any
other length:

```sh
openssl rand -base64 32 | tr -- '+/' '-_'
```
