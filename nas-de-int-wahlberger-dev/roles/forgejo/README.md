# forgejo

[Forgejo](https://forgejo.org/) git forge with its **built-in OCI container
registry**: one rootless container (SQLite, no separate DB), a Podman Quadlet
joined to the shared `caddy.network` and reverse-proxied by the `caddy` role
at `git.de.int.wahlberger.dev`. LAN/ZeroTier only (this host has no public
inbound port). Logs in via the Pocket ID instance at `pocket_id_app_url`.

- Image: `codeberg.org/forgejo/forgejo:15-rootless` (LTS series; Renovate
  proposes minor/patch bumps, majors need a manual PR merge).
- Web UI and registry (`/v2/`) share one vhost; Caddy needs no special
  config for large layer uploads (no request body limit, no upstream
  timeouts by default).
- Git over SSH: Forgejo's built-in SSH server, published on host port
  **2222** (`forgejo_ssh_port`), opened in firewalld via `firewall_allowed_ports`.
  Host sshd stays on 22, no clash.
- Data: `/mnt/containers/forgejo/volume` (repos, SQLite DB, package blobs,
  built-in SSH host keys, `custom/conf/app.ini`), owned by uid/gid 1000.

## Role variables

See `defaults/main.yml`. Required: `forgejo_url` and `forgejo_oidc_client_id`
(group_vars) plus six Vault secrets (see `vault.yml.example`):
`vault_forgejo_secret_key`, `_internal_token`, `_oauth2_jwt_secret`,
`_lfs_jwt_secret`, `_admin_password`, `_oidc_client_secret`. All secrets reach
the container through a root-only env file (`FORGEJO__<section>__<KEY>`,
applied to `app.ini` by the image on every start), never the Quadlet unit.

## Register the OIDC client in Pocket ID (manual, before first run)

Create a new OIDC client in the Pocket ID dashboard with redirect URI:

```text
https://git.de.int.wahlberger.dev/user/oauth2/pocket-id/callback
```

Put its ID in `forgejo_oidc_client_id` (group_vars) and its secret in
`vault_forgejo_oidc_client_secret`. Restrict who may sign in via the client's
**allowed user groups**; Forgejo has no allow-list of its own. Sign-up is
closed (`DISABLE_REGISTRATION=true`) but OIDC auto-registration is on, so
anyone Pocket ID lets through gets an account on first login (username from
`preferred_username`). The role registers the authentication source itself
(`forgejo admin auth add-oauth`) and re-applies it when client id/secret/URL
change.

## Admin

A local admin (`forgejo_admin_username`, default `forgejo-admin`; `admin` is a
reserved name) is created on first run with `vault_forgejo_admin_password`;
changing the vault value later re-applies it. Use it only to promote your
Pocket ID user to admin (Site administration -> User accounts) and for
break-glass; day-to-day login is Pocket ID.

## Container registry: login, push, pull

The registry needs **personal access tokens**, not your Pocket ID credentials
(OIDC users have no password). In Forgejo: Settings -> Applications ->
generate a token with scopes `read:package` (pull) and `write:package` (push).

```sh
podman login git.de.int.wahlberger.dev -u <your-forgejo-username>   # token as password
podman tag myimage:1.0 git.de.int.wahlberger.dev/<owner>/myimage:1.0
podman push git.de.int.wahlberger.dev/<owner>/myimage:1.0
podman pull git.de.int.wahlberger.dev/<owner>/myimage:1.0
```

`<owner>` is a Forgejo user or organization (lowercase). The image then shows
up under that owner's Packages tab. The vhost has a Let's Encrypt certificate
(DNS-01), so no `--tls-verify=false` is needed.

## Package cleanup

The global cron `cleanup_packages` is enabled (`forgejo_packages_cleanup_*`,
nightly): it purges unreferenced package data (blobs of deleted versions,
stale upload sessions) older than 24h. Deleting *old versions* is per owner
and lives in the UI, not in config: Settings (user or organization) ->
Packages -> Cleanup rules, e.g. "keep the newest 10 versions, keep versions
matching `latest|stable`, remove versions older than 90 days". Create one rule
per owner and package type (Container); use the preview before saving.

## Git over SSH

Add your public key under Settings -> SSH/GPG keys, then:

```sh
git remote add origin ssh://git@git.de.int.wahlberger.dev:2222/<owner>/<repo>.git
git push -u origin main
# or in ~/.ssh/config:  Host git.de.int.wahlberger.dev / Port 2222 / User git
```

HTTPS remotes (`https://git.de.int.wahlberger.dev/<owner>/<repo>.git`) work
with a personal access token (scope `write:repository`) as password.

Firewalld's `public` zone is host-wide, so 2222/tcp is open to whatever can
reach the host at all. That is LAN/ZeroTier here. fail2ban only watches
host sshd, not Forgejo's SSH server.

## Backup and restore

`/mnt/containers` (including `forgejo/volume`) is covered by `restic_backup`.
The live SQLite file is excluded and replaced by a consistent
`sqlite3 .backup` copy (`forgejo.db` in `restic_backup_staging_dir`), made on
the host each night before `restic backup`. Restore: stop `forgejo.service`,
restore the tree, copy `forgejo.db` over
`/mnt/containers/forgejo/volume/data/forgejo.db` (owner uid 1000), start it.
The database is kept in rollback-journal mode on purpose; do not switch it to
WAL without adapting the backup script.

## Provisioning notes

The admin account and Pocket ID source live in Forgejo's database, so they
are created through its CLI inside the container (`podman exec`), with
secrets passed via a root-only env file. Marker files in
`/mnt/containers/forgejo/state/` (hashes only) detect secret changes. These
CLI steps are skipped under `--check`.
