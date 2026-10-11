# semaphore

[Semaphore UI](https://semaphoreui.com/), a self-hosted web UI for running
Ansible playbooks, deployed on the ops VM as a Podman Quadlet and
reverse-proxied by the `caddy` role. SQLite backend. Adapted from the Pi's
role (SH-CC-07); the VM runs a **migrated database**, so the role never creates
an empty one.

## Role variables

See `defaults/main.yml` and `meta/argument_specs.yml`. Required: `semaphore_url`,
`semaphore_oidc_client_id`, `semaphore_uid`, and in the primary design
`semaphore_network_subnet`. The Vault secrets `vault_semaphore_admin_password`,
`vault_semaphore_access_key_encryption`, `vault_semaphore_cookie_hash`,
`vault_semaphore_cookie_encryption` and `vault_semaphore_oidc_client_secret` are
copied **verbatim** from the Pi (`access_key_encryption` must be identical or
the migrated Key Store cannot be decrypted).

| Variable | Default | Meaning |
|---|---|---|
| `semaphore_design` | `primary` | `primary`: joins `semaphore.network` (fixed `semaphore_network_subnet`), publishes `127.0.0.1:3000` only. `bridge_fallback`: joins `caddy.network`, publishes nothing (Caddy reaches `semaphore:3000`). Wired from `vm_proxy_design`. |
| `semaphore_uid` | empty | UID of the Semaphore process in the image (1001 for v2.19.16, spike A-32). Empty or non-numeric: the role fails **before any change**, naming `semaphore_uid` (SH-FR-210). |
| `semaphore_require_existing_db` | `true` | Fail before any change if `<semaphore_data_dir>/data/database.sqlite` is absent (SH-FR-52). |
| `semaphore_data_dir` | `{{ podman_data_dir }}/semaphore` | Base directory. |
| `semaphore_dns_servers` | `1.1.1.1`, `8.8.8.8` | Container resolvers (SH-FR-41). |
| `semaphore_oidc_provider_url` | `https://id.wahlberger.dev` | Pocket ID issuer (the Pi reads `pocket_id_app_url`, which the VM does not define). |
| `semaphore_image` | `v2.19.16` | Must equal the tag running on the Pi when the database was copied (SH-FR-50). |

## Migration and the missing-database guard

The database is copied from the Pi by the operator (step 4); this role only
adopts it. Order of the role: UID check, input check, database check, then the
first change. With `semaphore_require_existing_db: true` and no
`<semaphore_data_dir>/data/database.sqlite` it fails with a message naming that
path; no directory is created and no container starts (SH-AC-19). The role
never copies or creates `database.sqlite-wal`, `-shm` or `-journal` files
(SH-FR-204); SQLite creates its own while the container runs.

## Files, owners and modes

| Path | Owner | Mode | Requirement |
|---|---|---|---|
| `<semaphore_data_dir>` | root:root | 0755 | holds only individually mounted files |
| `<semaphore_data_dir>/data` | `semaphore_uid`:root | 0700 | SH-FR-168, SH-FR-219 |
| `.../data/database.sqlite` (if present) | `semaphore_uid`:root | 0600 | SH-FR-169, SH-FR-207 |
| `.../config.json` | `semaphore_uid`:root | 0600 | SH-FR-166, SH-FR-215 |
| `.../semaphore.env` | root:root | 0600 | SH-FR-167, SH-FR-216 |

Group `root` is the container process's primary group (gid 0). The Pi uses
`config.json` 0644 root:root; on the VM the secrets are not world readable, so
the owner must be the UID the process runs as (compare with
`podman exec semaphore id -u`, SH-AC-53).

**SELinux label (SH-FR-208).** `database.sqlite` carries `container_file_t`
after the container's first start because both volumes use `:Z`, which makes
Podman relabel the mounted tree recursively. The role sets no label itself (no
`sefcontext`/`restorecon` task): a plain `chcon` would be undone by the `:Z`
relabel anyway. Check with `ls -Z` after the first start (T-16 does so on the
fixture, SH-AC-53 on the VM). `:Z` also means the data directory must not be
shared with another container.

## Network and DNS

Primary: `semaphore.network` is a Quadlet network with the fixed subnet
`semaphore_network_subnet` (SH-FR-127), so the `from=` allowlist of the
automation key can name it. A changed subnet needs the network removed by hand;
a restart does not recreate it. Fallback: the container joins `caddy.network`
(deployed by the `caddy` role, which runs earlier) and publishes nothing.

The container gets `DNS=1.1.1.1` and `8.8.8.8` in its Quadlet. The own host
name resolves to the public IPv4 only because the `podman` role sets
`podman_base_hosts_file: image` (Podman otherwise copies the host's
`/etc/hosts`). `getent hosts` inside the container for the names in
`semaphore_getent_names` must equal `dig +short <name> @1.1.1.1` (SH-AC-16); the
list is rendered into the Quadlet and asserted by `tests/render.d/semaphore.yml`.

## Self-run exclusion

`site.yml` tags the role `semaphore`, and the Semaphore template for this
playbook passes `--skip-tags semaphore,zerotier` (SH-FR-149), so a run started
from this very Semaphore never restarts `semaphore.service` (SH-FR-66). A change to this role's
files therefore has to be applied from the workstation (`--tags semaphore`). The restart handler is skipped in `--check`.

## Tests

`tests/guards.d/semaphore.yml` runs the real role in a container (UID, database
guard, modes/owners, both designs, `--check`, `--skip-tags`, no secret in any
output); `tests/render.d/semaphore.yml` renders and verifies the Quadlets.

## Pocket ID login — know the two gaps

Confirmed working against Semaphore's own documented Pocket ID integration
(https://pocket-id.org/docs/client-examples/semaphore-ui), but two things
are **not** as seamless as Tandoor/Paperless-ngx's Pocket ID integration:

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

`config.json` is rendered mode `0600` owned by `semaphore_uid`: the
`semaphore` process inside the container runs as that non-root user, so a
root-owned `0600` file would be unreadable to it (that shows up as the
misleading `Cannot Find configuration!` from `semaphore users add`, actually a
permission denied). A wrong `semaphore_uid` therefore breaks startup; AC-53
compares it with the container.

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
and this ops playbook is a one-time manual setup through Semaphore's own UI
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
