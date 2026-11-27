# cloudflare_dns

Ensures this host's DNS records actually exist in Cloudflare, rather than
relying on someone having clicked them into place by hand. For the Semaphore
VM that is:

1. **A record for the host itself** (`inventory_hostname` →
   `cloudflare_dns_ip`, the VM's public IPv4) — SH-FR-36.
2. **Extra A records** from `cloudflare_dns_extra_a_records`. Production sets
   one: `ops.de.int.wahlberger.dev` → `vm_zt_ip`, the VM's ZeroTier address —
   SH-FR-131. This is the name the UI is reached by.
3. **One CNAME per `caddy_sites` entry** (today
   `semaphore.de.int.wahlberger.dev`) → `cloudflare_dns_cname_target`
   (`ops.de.int.wahlberger.dev`), **only while `cloudflare_dns_cnames_enabled`
   is true** — SH-FR-37, SH-FR-38.

Runs before the `caddy` role, using `community.general.cloudflare_dns` (no
new collection).

## The CNAME gate (why a flag, not "just run it")

`semaphore.de.int.wahlberger.dev` points at the Pi until the cut-over.
Production wires `cloudflare_dns_cnames_enabled` to
`semaphore_dns_cutover_enabled` (default `false`), so every run before
pull request D leaves that record alone — it is neither created nor
changed. Pull request D flips the one flag and the next run points the CNAME
at the VM. While the flag is false the CNAME task loops over an empty list, so
it also does not need `caddy_sites` to be defined.

If the CNAME already exists with a different type or value, Cloudflare
rejects creating a second record and the task fails with the API error
(SH-E-12). Fix the record by hand once, re-run, and confirm `changed=0`.
Whether the in-place update works is only checkable live (`--check --diff`
at the cut-over, SH-A-06).

## Guards (fail before any change)

The first tasks are asserts, ahead of every Cloudflare call:

- `vm_zt_ip` empty → fails naming `vm_zt_ip` (SH-FR-193, SH-AC-62). Checked
  first and independent of the token, so it fires in step 2 where the token
  exists but the ZeroTier address does not yet.
- `cloudflare_dns_api_token` empty → fails naming the Vault secret.
- `cloudflare_dns_extra_a_records` empty, or an entry with an empty `record`
  or `value` → fails (SH-CC-08).

## Why `proxied: false` on every record

The ZeroTier and LAN addresses are private, so Cloudflare's proxy (orange
cloud) cannot reach them; and this host issues its own TLS certificates
via DNS-01, so there is no reason to route traffic through Cloudflare's
edge. `proxied: true` would break resolution.

## Role variables

See `defaults/main.yml` and `meta/argument_specs.yml`. The token is the same
`vault_cloudflare_dns_api_token` the `caddy` role needs for DNS-01 (same
zone, same Zone:DNS:Edit token), not a new secret. `cloudflare_dns_ip`
defaults to `ansible_facts.default_ipv4.address`, which on Hetzner Cloud is
the public IPv4 (SH-A-19; verified live by SH-AC-14).

The module's `api_token` is `no_log` inside `community.general`, so tasks do
not set `no_log` themselves; that keeps Cloudflare's error text (SH-E-12)
visible.

## What this does NOT do

It only *adds/updates* records (`state: present`, never `solo: true`, which
would delete other records with the same name). It never deletes a record.
Decommissioning the Pi's records is a separate, deliberate step.

## Tests

`tests/guards.d/cloudflare_dns.yml` runs the role against a stub
`community.general.cloudflare_dns` (no network, no Cloudflare) and asserts
the exact calls the role makes for the cut-over off and on, check mode, and
every guard. Run it with `ansible-playbook tests/guards.d/cloudflare_dns.yml`
from the playbook directory (or `tests/guard-tests.sh cloudflare_dns`).
