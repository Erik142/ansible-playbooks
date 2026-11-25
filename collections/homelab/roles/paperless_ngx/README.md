# paperless_ngx

[Paperless-ngx](https://docs.paperless-ngx.com/) document management: Redis +
PostgreSQL + the app itself, each a separate Podman Quadlet on a private
`paperless-ngx` network, with the app additionally joined to the shared
`caddy.network` and reverse-proxied by the `caddy` role. Logs in via the
Pocket ID instance at `pocket_id_app_url` (served by cloud-wahlberger-dev).

## Role variables

See `defaults/main.yml` for the full list with inline documentation. The
required ones (no usable default) are `paperless_ngx_url` and
`paperless_ngx_oidc_client_id` — set them in `group_vars`, and provide
`vault_paperless_ngx_db_password` and `vault_paperless_ngx_oidc_client_secret` in
Ansible Vault.

## Depends on the `samba` role

`paperless_ngx_inbox_dir` defaults to a subdirectory of `samba_share_path` (from
the `samba` role's defaults) — the scan-to-folder inbox lives **inside** the
guest Samba share, so anyone on the LAN can drop a document in for OCR. Run
`samba` before this role in `site.yml` (already the case).

## Register the OIDC client in Pocket ID

Create an OIDC client in the Pocket ID dashboard with redirect URI
`{{ paperless_ngx_url }}/accounts/oidc/{{ paperless_ngx_oidc_provider_id }}/login/callback/`,
then set `paperless_ngx_oidc_client_id` in group_vars and
`vault_paperless_ngx_oidc_client_secret` in Vault to the values Pocket ID gives
you.

If migrating from an existing Paperless instance at the same hostname (e.g.
rpi-karlsruhe's), reuse its existing client_id/secret AND its
`paperless_ngx_db_password` instead of generating new ones — a new DB password
won't authenticate against a restored database dump, and the callback URL is
unchanged.

## SELinux

`paperless_ngx_inbox_dir` lives inside the Samba share and must stay labeled
`samba_share_t` (set by the `samba` role) so smbd can also reach it. Podman's
`:Z`/`:z` volume-mount suffix would relabel it `container_file_t` on every
container start regardless — so this is the one volume in
`paperless-ngx.container.j2` mounted **without** that suffix, and the
container runs with `SecurityLabelDisable=true` so its otherwise-confined
process isn't denied access to that differently-labeled path (there's no
stock policy rule letting a confined container touch Samba's file type). The
other volumes (data/media/export) are exclusively paperless-ngx's own and
keep their normal `:Z` labeling.

Because `samba`'s role runs before this one in `site.yml`, and its
`restorecon` is recursive over the whole Samba data tree, an already-wrong
label left over from before this fix existed corrects itself on the next
full playbook run — no manual `restorecon` needed.

## Postgres major-version upgrades

`paperless_ngx_db_data_dir` (`{{ paperless_ngx_db_data_dir_root }}/pgdata`) mounts to
`/var/lib/postgresql`, and Postgres 18+ images put the cluster in a
version-specific subdirectory (e.g. `pgdata/18/docker`). Bumping
`paperless_ngx_db_image` across a major version is **not** a simple tag bump —
dump from the old version and restore into the new one (or run `pg_upgrade`
with both binaries present).
