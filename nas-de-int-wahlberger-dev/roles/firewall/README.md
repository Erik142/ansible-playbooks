# firewall

Host firewall via **firewalld**, openSUSE Tumbleweed's default. Allows SSH,
Samba, and HTTP/HTTPS (Caddy) inbound in the target zone, and enables
masquerading for Podman's published container ports.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `firewall_zone` | `public` | firewalld zone to configure. |
| `firewall_allowed_services` | `[ssh, samba, http, https]` | Predefined firewalld services to allow. |
| `firewall_allowed_ports` | `[]` | Extra `"port/proto"` entries with no predefined firewalld service. |

## Podman caveat (important)

Rootful Podman publishes container ports via DNAT, which crosses firewalld's
**FORWARD**/NAT path, not a plain INPUT filter. `masquerade` must stay enabled
on the configured zone or Caddy's published 80/443 stop working. mealie and
paperless-ngx are **not** published to the host at all — they're reached only
through Caddy on the shared `caddy.network` — so they need no firewall rule of
their own.

## Inspect on the host

```sh
sudo firewall-cmd --list-all --zone=public
```
