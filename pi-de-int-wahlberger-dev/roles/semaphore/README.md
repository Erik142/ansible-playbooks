# semaphore

[Semaphore UI](https://semaphoreui.com/) — a self-hosted web UI for running
Ansible playbooks — deployed as a Podman Quadlet on the shared
`caddy.network` and reverse-proxied by the `caddy` role. SQLite backend, no
separate database container needed at this scale.

## Role variables

See `defaults/main.yml` for the full list. The required ones (no usable
default) are `semaphore_url` and `semaphore_oidc_client_id` — set them in
`group_vars`, and provide `vault_semaphore_admin_password`,
`vault_semaphore_access_key_encryption`, `vault_semaphore_cookie_hash`,
`vault_semaphore_cookie_encryption`, and
`vault_semaphore_oidc_client_secret` in Ansible Vault.

## Pocket ID login — know the two gaps

Confirmed working against Semaphore's own documented Pocket ID integration
(https://pocket-id.org/docs/client-examples/semaphore-ui), but two things
are **not** as seamless as Mealie/Paperless-ngx's Pocket ID integration:

1. **No auto-provisioning of permissions.** Semaphore auto-creates a user
   record on first OIDC login, but that user gets **zero project access** by
   default. After someone logs in with Pocket ID for the first time, the
   local admin (below) has to log in separately and manually grant that user
   a project role.
2. **No way to fully disable local login.** Unlike Paperless's
   `PAPERLESS_DISABLE_REGULAR_LOGIN`, Semaphore has no "OIDC-only" switch. The
   admin account below is a real local account — kept deliberately as a
   break-glass fallback into the one system that holds SSH keys to your
   entire infrastructure, not an oversight to lock down later.

## Why config.json is templated directly, not set via env vars

Semaphore's Docker documentation describes `SEMAPHORE_DB_DIALECT`,
`SEMAPHORE_DB`, `SEMAPHORE_ADMIN*`, `SEMAPHORE_ACCESS_KEY_ENCRYPTION`, and
`SEMAPHORE_COOKIE_*` as env-var-configurable — but empirically, this image's
`server` command (what its default entrypoint runs) does **not** apply them:
on first boot it auto-generates its own `/etc/semaphore/config.json` with its
own random secrets and its own default sqlite path
(`/var/lib/semaphore/database.sqlite`, **not** on any bind-mounted volume),
then never re-reads those env vars again once that file exists — including
never creating an admin user from `SEMAPHORE_ADMIN*`. OIDC is the one setting
this image *does* read fresh from the environment on every boot (confirmed:
Pocket ID login works), so it stays in `semaphore.env.j2`.

The fix: `config.json.j2` renders the real config directly (mounted as a
single file, not a directory — Semaphore never gets the chance to
auto-generate its own), `/var/lib/semaphore` is bind-mounted so the database
persists across restarts, and the admin account is created explicitly via
`semaphore users add` (idempotent — checked with `semaphore users get`
first) rather than relying on env vars that don't do what the docs describe
for this image.

`config.json` is rendered mode `0644`, not root-only — the `semaphore`
process inside the container runs as a non-root user (confirmed: the
image's own auto-generated config.json was owned by a `semaphore` user, not
root), so a root:root `0600` file is unreadable to it. Found this the hard
way: `semaphore users add --config /etc/semaphore/config.json` failed with
the misleading `Cannot Find configuration!` — actually a permission denied
reading the file, not a missing one.

**Rotating `semaphore_admin_password` later won't update an existing
account** — the idempotency check only looks for the user's *existence*, not
whether its password matches the current Vault value. To actually change it,
either delete the user first (`semaphore users delete --config
/etc/semaphore/config.json --login <login>`) and re-run, or run `semaphore
users change-by-login` by hand.

## Register the OIDC client in Pocket ID

Create an OIDC client named "Semaphore UI" in the Pocket ID dashboard with
redirect URI `{{ semaphore_url }}/api/auth/oidc/pocketid/redirect/`, then set
`semaphore_oidc_client_id` in group_vars and
`vault_semaphore_oidc_client_secret` in Vault to the values Pocket ID gives
you.

## What this role does NOT set up

Deploying the Semaphore application is as far as this role goes — wiring it
up to actually manage `cloud-wahlberger-dev`, `nas-de-int-wahlberger-dev`,
and this Pi playbook is a one-time manual setup through Semaphore's own UI
(not something Ansible manages as code, same as Pocket ID's own admin setup
in `cloud-wahlberger-dev`):

1. Log in once as the local admin (`semaphore_admin_username` /
   `vault_semaphore_admin_password`).
2. Add a **Key Store** entry with the *private* half of the dedicated
   automation key in `ssh_authorized_keys_list` (its public half is already
   authorized on all three hosts by the `ssh_authorized_keys` role, alongside
   your own personal key) — this is how Semaphore actually connects over SSH.
3. Add each playbook's git repo, its `inventories/production/hosts.yml` as
   an inventory, and the vault password as an "Environment" secret.
4. Create a **Task Template** per playbook pointing at `site.yml`. Semaphore
   auto-installs a repo's `requirements.yml` (collections/roles) before
   running, so nothing extra is needed there.
5. Log in once with Pocket ID, then use the local admin to grant that new
   user a role on the projects you just created.

## Automatic vs. manual runs

Nothing here wires up a schedule or a git webhook — that's also configured
per Task Template in Semaphore's own UI once the above is set up. See the
top-level README for the reasoning on preferring an internal, polling-based
schedule over exposing a webhook endpoint to the internet.
