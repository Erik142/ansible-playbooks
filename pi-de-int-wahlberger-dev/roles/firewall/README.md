# firewall

Host firewall via **ufw**. Sets a default-deny inbound policy and allows only
the public service ports. SSH is allowed before ufw is enabled, so applying
this role can't lock you out.

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
**FORWARD** chain, not **INPUT**. `firewall_forward_policy` must stay `ACCEPT`,
or published ports (Caddy on 80/443) get dropped. This host firewall does
**not** filter container published ports at all — since this Pi has no public
inbound port to begin with (reached only via LAN/ZeroTier), that's an
acceptable tradeoff here, unlike a public VM.

## Inspect on the host

```sh
sudo ufw status verbose
```
