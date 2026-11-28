# pocket_id

Pocket ID, a passkey OIDC provider, as a Podman Quadlet behind Caddy. It is the
OIDC issuer for the NAS, ops and the edge services (FreshRSS, Beszel, Uptime Kuma).

## Layout on the host

| Path | Content | Backed up by |
|------|---------|--------------|
| `/opt/podman/pocket-id/encryption.key` | Data-encryption key (0644, mounted read-only) | `restic_backup` (`/opt/podman`) |
| `/opt/podman/pocket-id/data/` | SQLite DB and uploads, bind-mounted at `/app/data` | `restic_backup` (sqlite `.backup` copy, see `edge` inventory) |

The data directory was a named volume on the old Debian host. Named volumes live
under `/var/lib/containers/storage`, outside the backed-up paths, which is why
they are bind mounts here.

## Role variables

See `defaults/main.yml`. Required: `pocket_id_app_url`, `pocket_id_encryption_key`
(from Vault, vault id of the host).

- `pocket_id_data_uid`/`gid` (default 1000): owner of `data/`, as verified on the live
  host. The container runs as root.

## Migration note

The encryption key must be the existing value. Do not generate a new one for a
migrated instance.
