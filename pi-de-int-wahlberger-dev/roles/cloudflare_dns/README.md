# cloudflare_dns

Ensures this host's public DNS records actually exist in Cloudflare, rather
than relying on someone having clicked them into place by hand: one **A**
record for the host itself (`inventory_hostname` → `cloudflare_dns_ip`), plus
one **CNAME** per `caddy_sites` entry pointing back at that A record. Runs
before the `caddy` role, using `community.general.cloudflare_dns` — no new
collection, `community.general` is already a dependency.

## Why CNAMEs, not a separate A record per site

Matches the pattern already hand-set-up for cloud-wahlberger-dev (e.g.
`id.wahlberger.dev` CNAMEs to `cloud.wahlberger.dev`): one place holds the
real IP, every service name just points at the host. Change the host's IP
once and every site follows, instead of updating N A records.

## Why `proxied: false` on every record

These IPs are private (LAN/ZeroTier), not publicly routable — Cloudflare's
proxy (the orange cloud) can't reach them, and this host issues its own TLS
certificates via DNS-01 anyway, so there's no reason to route traffic through
Cloudflare's edge. `proxied: true` would just break resolution.

## Role variables

See `defaults/main.yml`. `cloudflare_dns_api_token` is required — reuse the
same `vault_cloudflare_dns_api_token` the `caddy` role already needs for
DNS-01 (same zone, same scoped Zone:DNS:Edit token), not a new secret.
`cloudflare_dns_ip` defaults to `ansible_default_ipv4.address`, so it can't
drift out of sync with the host's actual address.

## What this does NOT do

This only *adds/updates* records (`state: present`, and never `solo: true`,
which would delete any other unrelated record sharing that name) — it never
deletes a record, and it doesn't touch the private bind9 servers that
currently also resolve these same hostnames internally. Decommissioning
those is a deliberate separate step, once the public records are confirmed
working end-to-end.
