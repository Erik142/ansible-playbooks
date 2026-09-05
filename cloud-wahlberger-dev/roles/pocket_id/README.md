# pocket_id

Runs [Pocket ID](https://pocket-id.org) — an OIDC provider with passkey
authentication — as a Podman Quadlet. It listens on **1411**, is **not**
published to the host, and is reached only via the `caddy` reverse proxy over the
shared `systemd-caddy` network. HTTPS is mandatory (WebAuthn requires a secure
context).

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `pocket_id_image` | `ghcr.io/pocket-id/pocket-id:v2.8.0` | Image (pinned). |
| `pocket_id_volume` | `pocket-id` | Named volume at `/app/data` (DB + key). |
| `pocket_id_app_url` | _(required)_ | Public `https://` URL; set in `group_vars`. |
| `pocket_id_trust_proxy` | `true` | Trust `X-Forwarded-*` from the proxy. |
| `pocket_id_encryption_key` | _(required)_ | Data-encryption key, from Vault. |

## Encryption key (Vault)

`pocket_id_encryption_key` comes from Ansible Vault
(`vault_pocket_id_encryption_key`, surfaced in `group_vars`) and is written to a
root-owned `encryption.key` the container mounts read-only. **It must stay
constant** — a different value makes existing encrypted data unrecoverable.

Migrating from the earlier auto-generated `secret_files/` key? Put that exact
value into Vault first:

```sh
cat secret_files/pocket_id_encryption.key   # copy this into vault.yml
ansible-vault edit inventories/production/group_vars/all/vault.yml
```

Only after confirming Pocket ID still works should you delete the old
`secret_files/pocket_id_encryption.key`.

## Data & backups

The `pocket-id` named volume (`/app/data`) holds the **SQLite database and the
encryption key** — that is the thing to back up. Losing the key makes encrypted
data unrecoverable.

## First run

After the play, open the `pocket_id_app_url` in a browser and complete the
initial admin setup.

## Depends on

The `caddy` role must run first — it creates the shared `systemd-caddy` network
and terminates TLS for `pocket_id_app_url`.
