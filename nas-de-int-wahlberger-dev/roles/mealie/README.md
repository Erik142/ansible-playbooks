# mealie

[Mealie](https://mealie.io/) recipe manager, deployed as a Podman Quadlet on
the shared `caddy.network` and reverse-proxied by the `caddy` role. Logs in
via the Pocket ID instance at `pocket_id_app_url` (served by
cloud-wahlberger-dev).

## Role variables

See `defaults/main.yml` for the full list with inline documentation. The
required ones (no usable default) are `mealie_url` and `mealie_oidc_client_id`
— set them in `group_vars`, and provide `vault_mealie_oidc_client_secret` in
Ansible Vault.

## Register the OIDC client in Pocket ID

Create an OIDC client in the Pocket ID dashboard with redirect URI
`{{ mealie_url }}/login`, then set `mealie_oidc_client_id` in group_vars and
`vault_mealie_oidc_client_secret` in Vault to the values Pocket ID gives you.

If migrating from an existing Mealie instance at the same hostname (e.g.
rpi-karlsruhe's), reuse its existing client_id/secret instead of registering a
new app — the callback URL is unchanged.
