# freshrss

FreshRSS feed aggregator as a Podman Quadlet behind Caddy. Login goes through
Pocket ID (OIDC). The admin user is pre-created by the entrypoint, because FreshRSS
does not auto-create OIDC users.

## Layout on the host

| Path | Content | Backed up by |
|------|---------|--------------|
| `/opt/podman/freshrss/freshrss.env` | Config and secrets (0600) | `restic_backup` |
| `/opt/podman/freshrss/data/` | SQLite DB and `config.php`, bind-mounted at `/var/www/FreshRSS/data` | `restic_backup` (sqlite `.backup` copy, see `edge` inventory) |

The data directory was a named volume on the old Debian host. See the `pocket_id`
README for why it is a bind mount now.

## Role variables

See `defaults/main.yml`. Required: `freshrss_app_url`, `freshrss_admin_user`,
`freshrss_oidc_client_id`, and the Vault secrets `freshrss_oidc_client_secret`,
`freshrss_oidc_crypto_key`, `freshrss_admin_password`.

- `freshrss_data_uid`/`gid` (default 0/33): owner of `data/`, as verified on the live
  host. The container runs as root, and the web server runs as www-data (gid 33).
