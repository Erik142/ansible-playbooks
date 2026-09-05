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
   `SEMAPHORE_ADMIN*` variables below create a real local account — kept
   deliberately as a break-glass fallback into the one system that holds SSH
   keys to your entire infrastructure, not an oversight to lock down later.

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
