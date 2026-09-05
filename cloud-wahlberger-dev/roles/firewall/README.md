# firewall

Host firewall via **ufw** (which uses the nftables backend on Debian 13). Sets a
default-deny inbound policy and allows only the public service ports. SSH is
allowed before ufw is enabled, so applying this role can't lock you out.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `firewall_allowed_tcp_ports` | `[22, 80, 443]` | Inbound TCP ports to allow. |
| `firewall_default_incoming` | `deny` | Default inbound policy. |
| `firewall_default_outgoing` | `allow` | Default outbound policy. |
| `firewall_forward_policy` | `ACCEPT` | `/etc/default/ufw` forward policy. |
| `firewall_logging` | `low` | ufw logging level. |

## Podman caveat (important)

Rootful Podman publishes container ports via DNAT, so that traffic crosses the
**FORWARD** chain, not **INPUT**. Two consequences:

1. `firewall_forward_policy` must stay `ACCEPT`, or published ports (e.g. Traefik
   on 80/443) get dropped. The INPUT default-deny still protects host services
   such as SSH.
2. This host firewall does **not** actually filter container published ports —
   whatever a container publishes is reachable from the network. Treat the
   **Hetzner Cloud Firewall** (edge) as the authoritative ingress control for
   22/80/443.

## Inspect on the host

```sh
sudo ufw status verbose
```
