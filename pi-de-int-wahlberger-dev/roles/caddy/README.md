# caddy

Reverse proxy with automatic HTTPS via **DNS-01** (Cloudflare), not HTTP-01:
this host has no public inbound port (it's a Raspberry Pi at home reached
over ZeroTier/LAN, not a public VM like cloud-wahlberger-dev), so Let's
Encrypt can't reach it on port 80 to validate a certificate. DNS-01 only needs
outbound access to Cloudflare's API and Let's Encrypt, which the host already
has. It also creates the shared `caddy.network` Podman network that backend
services (`semaphore`) attach to.

## Why a custom-built image

The **official** `caddy:2` image has no DNS provider plugins compiled in —
DNS-01 requires the `caddy-dns/cloudflare` Caddy module, which only ships via
a custom build. `files/Containerfile` builds one with `xcaddy`
(`caddy:2-builder` → `github.com/caddy-dns/cloudflare` → copied onto stock
`caddy:2`), and the role builds it locally with `containers.podman.podman_image`
before deploying the container — no external/third-party image required.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `caddy_image` | `localhost/caddy-cloudflare:2` | Tag of the locally built image. |
| `caddy_data_dir` | `{{ podman_data_dir }}/caddy` | Host dir for the build context, Caddyfile, and state (certs in `data/`) — on the external drive the `storage` role mounts. |
| `caddy_build_dir` | `{{ caddy_data_dir }}/build` | Host dir holding the Containerfile build context. |
| `caddy_http_port` | `80` | Host port → container 80. |
| `caddy_https_port` | `443` | Host port → container 443. |
| `caddy_acme_email` | `""` | Let's Encrypt account email (optional). |
| `caddy_sites` | `[]` | List of `{ host, upstream, extra? }` to serve. |

Cloudflare API token: set `vault_cloudflare_dns_api_token` in Ansible Vault,
surfaced as `cloudflare_dns_api_token` in `vars.yml` — a scoped token with
`Zone:DNS:Edit` on the `wahlberger.dev` zone (needs no other permission). If
migrating from rpi-karlsruhe, reuse its existing token instead of minting a
new one — same zone, same purpose.

## Adding a site

Add an entry to `caddy_sites` (in `group_vars`) and re-run — no host edits:

```yaml
caddy_sites:
  - host: semaphore.de.int.wahlberger.dev
    upstream: "semaphore:3000"
```

Each `host` needs a DNS **A/AAAA record** pointing at wherever clients
actually reach this host (its LAN or ZeroTier IP) — DNS-01 doesn't require it
to resolve to a public IP, unlike HTTP-01. Certificates persist in
`{{ caddy_data_dir }}/data` — back that up.

## Changing `files/caddy.network` (e.g. the `DNS=` lines)

`DNS=10.10.0.1`/`DNS=10.10.10.1` are the LAN resolvers, so that containers on
`caddy.network` (Caddy, Semaphore) can resolve internal-only records like
`nas.de.int.wahlberger.dev`, not just public hostnames — Semaphore needs this
to SSH into the other two hosts. They also forward public lookups fine, so
Caddy's own ACME/Cloudflare calls are unaffected.

Re-running the playbook after editing this file is **not enough** on its
own: Quadlet's generated `caddy-network.service` creates the Podman network
with `--ignore`, which no-ops if it already exists — Podman does not
retroactively apply new settings to a live network. After re-running,
recreate it by hand and restart everything attached to it:

```sh
sudo podman stop semaphore caddy
sudo podman network rm caddy
sudo systemctl restart caddy-network.service
sudo systemctl restart caddy.service semaphore.service
```
