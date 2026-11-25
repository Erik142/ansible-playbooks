# cloudflare_dns

Ensures this host's public DNS records actually exist in Cloudflare, rather
than relying on someone having clicked them into place by hand: one **A**
record for the host itself (`inventory_hostname` → `cloudflare_dns_ip`), plus
one **CNAME** per `caddy_sites` entry pointing back at that A record. Runs
before the `caddy` role, using `community.general.cloudflare_dns` — no new
collection, `community.general` is already a dependency.

## Why CNAMEs, not a separate A record per site

Matches this host's own existing hand-set-up records (`id.wahlberger.dev`
and `rss.wahlberger.dev` both CNAME to `cloud.wahlberger.dev`) — one place
holds the real IP, every service name just points at the host. Change the
host's IP once and every site follows, instead of updating N A records. This
role brings those already-working records under Ansible management rather
than changing them.

## Why `proxied: false` on every record

Confirmed via `dig`: the existing records already resolve straight to this
host's own public IP, not a Cloudflare edge IP, so they're DNS-only
(grey-cloud) today — keep it that way. This host issues its own TLS
certificates via HTTP-01, so there's no reason to route traffic through
Cloudflare's proxy, and doing so would break Let's Encrypt's HTTP-01
validation (it needs to reach this host directly on port 80).

## Role variables

See `defaults/main.yml`. `cloudflare_dns_api_token` is required — this is a
**new** secret for this playbook (cloud-wahlberger-dev doesn't otherwise need
Cloudflare, since it uses HTTP-01, not DNS-01). Reuse the exact same token
already set up for nas-de-int-wahlberger-dev/pi-de-int-wahlberger-dev instead
of minting a new one — same zone, same scoped Zone:DNS:Edit permission.
`cloudflare_dns_ip` defaults to `ansible_default_ipv4.address`, so it can't
drift out of sync with the host's actual address.

## What this does NOT do

This only *adds/updates* records (`state: present`, and never `solo: true`,
which would delete any other unrelated record sharing that name) — it never
deletes a record.
