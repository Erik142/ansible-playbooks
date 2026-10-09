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
| `firewall_rich_rules` | `[]` | firewalld rich rule strings applied to `firewall_zone` (permanent + immediate), after services/ports. |

Source-restricted ports belong in `firewall_rich_rules`, never in `firewall_allowed_ports`, which allows every source.
Example: `rule family="ipv4" source address="10.10.0.0/16" port port="8000" protocol="tcp" accept`.

The role only ever **adds** rich rules (found on the VM, BD-AC-45): dropping a CIDR from
`firewall_rich_rules` (for example from `restic_server_allowed_sources`) does not remove its
rule. Remove it by hand: `firewall-cmd --permanent --zone=<zone> --remove-rich-rule='<rule>'`, then
`firewall-cmd --reload`.

Container networks are not covered by these rules: netavark puts each Podman network's subnet
into the firewalld zone `trusted` (verified on the VM with the default `podman` network and a
custom one), so a container on any Podman network reaches a host-networked listener such as
rest-server regardless of the rich rules. Only authentication (htpasswd) stands in the way.

## Podman caveat (important)

Rootful Podman publishes container ports via DNAT, which crosses firewalld's
**FORWARD**/NAT path, not a plain INPUT filter. `masquerade` must stay enabled
on the configured zone or Caddy's published 80/443 stop working. tandoor and
paperless-ngx are **not** published to the host at all — they're reached only
through Caddy on the shared `caddy.network` — so they need no firewall rule of
their own. Forgejo's git-over-SSH is the exception: it publishes host port
2222, allowed via `firewall_allowed_ports` in `group_vars`.

## Inspect on the host

```sh
sudo firewall-cmd --list-all --zone=public
```
