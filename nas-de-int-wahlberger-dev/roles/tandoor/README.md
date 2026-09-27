# tandoor

[Tandoor Recipes](https://docs.tandoor.dev/) recipe manager: PostgreSQL + the
app itself, each a separate Podman Quadlet on a private `tandoor` network,
with the app additionally joined to the shared `caddy.network` and
reverse-proxied by the `caddy` role. Replaces the `mealie` role at the same
hostname (`recipes.de.int.wahlberger.dev`). Logs in via the Pocket ID
instance at `pocket_id_app_url` (served by cloud-wahlberger-dev).

## Role variables

See `defaults/main.yml` for the full list with inline documentation. The
required ones (no usable default) are `tandoor_url` and
`tandoor_oidc_client_id` — set them in `group_vars`, and provide
`vault_tandoor_db_password` and `vault_tandoor_oidc_client_secret` in Ansible
Vault.

Tandoor's app container also sets `ENABLE_SIGNUP=0` and
`SOCIALACCOUNT_ONLY=1`, closing local username/password account creation and
sign-in — Pocket ID is the only way to sign in once the setup below is done.

## Register the OIDC client in Pocket ID

Register a **new** OIDC client dedicated to Tandoor in the Pocket ID
dashboard — do **not** reuse Mealie's old client
(`93041358-e45e-4e44-b838-3c758cfe4681`; see "Retire Mealie" below).

Redirect URI:

```text
https://recipes.de.int.wahlberger.dev/accounts/oidc/pocket-id/login/callback/
```

Then set `tandoor_oidc_client_id` in group_vars and
`vault_tandoor_oidc_client_secret` in Vault to the values Pocket ID gives you.

Also set the client's **allowed user groups** in the Pocket ID dashboard.
Tandoor itself has no user allow-list — restricting who can sign in happens
entirely at the Pocket ID client, by scoping which Pocket ID groups are
allowed to use this client. Anyone in an allowed group who signs in gets a
Tandoor account created for them automatically (see below).

## First sign-in: create the household space before anyone else signs in

Tandoor requires a "space" (household) to exist before recipes can be
created, and the **first** user to ever sign in through Pocket ID becomes
that space's owner. Sign in as the intended owner first and create the space
before inviting or allowing any other household member to sign in — a user
who signs in before the space exists gets an account with no space to join
and no way to create one themselves.

If a household member already signed in before the space existed (leaving
them without a space), don't have them sign in again and expect it to work:
have the space owner generate an invite link from Tandoor's space settings
and send it to that user instead — the invite link attaches their existing
account to the space.

## Admin recovery

If the owner account is locked out (e.g. lost Pocket ID access) and no other
space admin is available, create a local superuser directly via Django's
management command, run inside the running app container:

```console
$ podman exec -it tandoor python manage.py createsuperuser
```

This works regardless of `SOCIALACCOUNT_ONLY=1`, since it bypasses the web
login flow entirely and creates the account straight in the database. Use
the resulting local account only to fix the space/user configuration, then
go back to signing in via Pocket ID.

Note: the `/setup/` page (Tandoor's own unauthenticated superuser-creation
flow) is blocked at the Caddy layer, not via a Tandoor setting — Tandoor has
no config flag to close it. See the `caddy` role for that block.

## Rotating the DB password

`POSTGRES_PASSWORD` only takes effect when the database cluster is first
initialised, so the role password inside the running `tandoor-db` container
must be changed *before* `vault_tandoor_db_password`, not after — updating
Vault first (or re-running the role first) would restart `tandoor` with a
password Postgres doesn't recognize yet (BR-04).

1. Change the role password inside `tandoor-db` first:

   ```console
   $ podman exec -it tandoor-db psql -U tandoor -c \
       "ALTER USER tandoor WITH PASSWORD '<new password>';"
   ```

2. Update `vault_tandoor_db_password` in Vault to the same new password.
3. Run `ansible-playbook site.yml --tags tandoor,restic_backup` — tagging
   `restic_backup` too is required so `tandoor-pgpass.env` is re-rendered
   with the new password before the next backup, not just the `tandoor` app
   container.

## Changing the Django secret key

`vault_tandoor_secret_key` signs Tandoor's session cookies. Rotating it
invalidates every existing session — all signed-in users (including the
owner) are logged out and have to sign in again via Pocket ID. It does not
affect stored data (recipes, spaces, users) — only active sessions.

## Postgres major-version upgrades

Bumping `tandoor_db_image` across a Postgres major version (e.g. 16 → 17) is
**not** a simple tag bump — the on-disk cluster format isn't compatible
across major versions. Dump from the old version and restore into the new
one (or run `pg_upgrade` with both binaries present) before switching the
image tag. Renovate is deliberately configured *not* to propose Postgres
major-version bumps automatically for this role — only minor/patch updates —
so this only comes up when deliberately choosing to upgrade.

## Retire Mealie

Only once BR-01 is met — (a) every acceptance scenario verifying a `[Must]`
FR, plus AC-46, has passed on the production host (except AC-36, the
deletion itself, and AC-47, the failure drill), and (b) the owner has
confirmed both former Mealie recipes exist in Tandoor — retire the old
deployment by hand — neither step is an Ansible task:

1. Delete the old data on disk: `rm -rf /mnt/containers/mealie` on the host.
2. Delete Mealie's old OIDC client (`93041358-e45e-4e44-b838-3c758cfe4681`) in
   the Pocket ID admin UI.
