# uptime_kuma

Uptime Kuma as an external watcher of the homelab, behind Caddy. Access goes through
`oauth2-proxy`, which uses Pocket ID for login. Caddy's `forward_auth` on the site
calls `oauth2-proxy` on `/oauth2/auth`, and only after that does Caddy proxy to Uptime
Kuma. The edge host's `caddy_sites` entry for the status host has only an `extra`
block, and the role's Caddy site definition is in the inventory.

## Layout on the host

| Path | Content | Backed up by |
|------|---------|--------------|
| `/opt/podman/uptime-kuma/oauth2-proxy.env` | oauth2-proxy config and secrets (0600) | `restic_backup` |
| `/opt/podman/uptime-kuma/data/` | SQLite DB (`kuma.db`) and icons, bind-mounted at `/app/data` | `restic_backup` (sqlite `.backup` copy, see `edge` inventory) |

The data directory was a named volume on the old Debian host. See the `pocket_id`
README for why it is a bind mount now.

## Role variables

See `defaults/main.yml`. Required: `uptime_kuma_url`, `uptime_kuma_oidc_client_id`,
`pocket_id_app_url`, and the Vault secrets `uptime_kuma_oidc_client_secret` and
`uptime_kuma_cookie_secret`.

- `uptime_kuma_data_uid`/`gid` (default 1000): owner of `data/`, as verified on the live
  host. The container runs as root.
