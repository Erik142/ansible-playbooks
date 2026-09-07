# beszel_hub

[Beszel](https://beszel.dev/) monitoring hub: a single Podman Quadlet
(built on [PocketBase](https://pocketbase.io/)) behind Caddy, collecting
CPU/memory/disk/network/container metrics reported by `beszel_agent` on
every host in this repo (cloud-wahlberger-dev itself, the NAS, and the Pi).

Runs here rather than on the NAS or Pi so it keeps working — and can keep
alerting — even if the entire home site (NAS, Pi, router, ZeroTier) goes
dark. Same reasoning as `uptime_kuma`, which is on this host for the exact
same reason; see `site.yml`'s comments.

## First boot: create the superuser account

Beszel's hub, like any PocketBase app, has no default admin account —
visit `beszel_hub_url` right after the first deploy and follow its own
prompt to create the initial superuser account (email + password). This is
a one-time manual step; there's no env var or config file to pre-seed it,
same situation as `roles/beszel_agent`'s hub-key bootstrap below.

## OIDC provider registration is manual — but a couple of related settings aren't

Unlike Immich (`roles/immich`), Beszel has no `IMMICH_CONFIG_FILE`-style
single config file. The actual OAuth2 *provider* (issuer URL, client
ID/secret) is configured through PocketBase's own Admin UI at
`<beszel_hub_url>/_/` (Collections → `users` → Options → OAuth2), stored in
its database — that part really is a one-time manual step, exactly like
registering the OIDC client itself is a manual step in Pocket ID's
dashboard. There is no `vault_beszel_hub_oidc_client_secret` in this repo —
both halves of *that* integration are manual and live outside Ansible/Vault.

That said, Beszel *does* expose a couple of closely-related settings as
plain hub environment variables — `beszel_hub_oauth_user_creation` and
`beszel_hub_disable_password_auth` below, the equivalent of Immich's
`immich_disable_local_login`. Both are also toggleable via a PocketBase
Admin UI checkbox if you'd rather manage them there instead, but setting
them declaratively here means a fresh deploy reproduces the same
configuration without a manual click.

## Required for OAuth login to actually work at all

`beszel_hub_oauth_user_creation` (default `true`) sets `USER_CREATION=true`.
Without it, the `users` collection's create rule is superusers-only via the
API — which blocks not just brand-new signups but **the very first OAuth
login to an already-existing account** too (Beszel has to create a linking
record between the external identity and the local account the first
time), surfacing as `"Only superusers can perform this action"` on
`POST /api/collections/users/auth-with-oauth2`. Confirmed against Beszel's
own source (`internal/hub/collections.go`): this sets the create rule to
`@request.context = 'oauth2'` — scoped to the OAuth2 flow itself, not
opened up generally. Matches a [closed upstream issue](https://github.com/henrygd/beszel/issues/1578)
about this exact error with Pocket ID specifically — the fix there was the
same env var, just make sure it's set on the **hub**, not `beszel_agent`
(easy to mix up, and the mistake in that issue too).

One related note for whenever family members get their own accounts later:
Beszel's own auto-created accounts need `verified=true` to actually be
allowed to log in (the `users` collection's `authRule`). Whether Pocket ID
reports `email_verified: true` for a given user affects whether their
first-ever OAuth signup succeeds — doesn't affect your own account, which
was already created `verified: true` by the first-boot bootstrap.

## Pocket ID as the only way into the app login

`beszel_hub_disable_password_auth` (default `true`) sets
`DISABLE_PASSWORD_AUTH=true`. Confirmed from source
(`internal/hub/collections.go`) that this only flips
`usersCollection.PasswordAuth.Enabled` — it never touches the separate
`_superusers` collection backing the `/_/` admin panel, which keeps its own
independent email+password login regardless. So this can't lock you out of
emergency access the way it could have with Immich (where disabling local
login really did remove every local-login path) — there's always the `/_/`
panel as a fallback, entirely unaffected by this setting.

## OAuth login uses a full-page redirect, not Beszel's default popup

`beszel_hub_oauth_disable_popup` (default `true`) sets `OAUTH_DISABLE_POPUP=true`
on the container. Beszel's default OAuth flow opens a popup window and has
the PocketBase SDK close that popup itself once login completes — but on
some browsers (Safari on macOS notably; see
[this PocketBase discussion](https://github.com/pocketbase/pocketbase/discussions/2429#discussioncomment-5943061))
that "popup" doesn't actually open as a separate window and ends up being
the user's only tab, so completing login closes their entire browser tab
instead of just a popup. The symptom looks alarming (login appears to
succeed — a green checkmark on Pocket ID's passkey prompt — then the whole
tab vanishes) but it's purely a client-side window-handling quirk, nothing
wrong with the Pocket ID side of the integration. Setting this env var
switches the whole flow to a plain full-page redirect (navigate away to
Pocket ID, then get redirected straight back), avoiding the popup — and
the window-closing bug — entirely.

## Bootstrapping each `beszel_agent`

The hub generates its own SSH keypair on first boot — this can't be
pre-seeded by Ansible/Vault either. After the hub is up:

1. Log in, add a host as a "System." The UI shows the hub's own SSH public
   key (a `ssh-ed25519 ...` line) — copy it.
2. Set `beszel_agent_hub_key` to that value in each of the three playbooks'
   `group_vars`, then run their `beszel_agent` role.

The *same* key value is used for all three agents — it identifies this one
hub, not each individual system.

## Reaching this host's own agent

This host also runs its own `beszel_agent` (see that role's README ->
"The hub reaching its own host"). Register it as a System using host
`host.containers.internal` (not `localhost`) and the agent's configured
port — `AddHost=host.containers.internal:host-gateway` on this container
is what makes that hostname resolve to the actual host from inside the
container's network namespace.
