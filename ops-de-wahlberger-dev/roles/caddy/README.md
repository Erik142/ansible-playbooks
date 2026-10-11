# caddy

Reverse proxy for the Semaphore UI on the ops VM. It is reachable over
ZeroTier only: Caddy listens on the VM's ZeroTier address (`vm_zt_ip`), serves
HTTPS on 443, and answers **403** to every client outside
`caddy_allowed_sources`. Certificates come from **DNS-01** through Cloudflare,
so no public inbound port is needed.

What is deliberately absent: no listener on port 80 (`auto_https
disable_redirects`; DNS-01 needs none) and no admin endpoint (`admin off`,
port 2019). The global options were validated on `caddy:2` and on the locally
built image in spike A-33 (`docs/spikes/A-33-caddy-global-options.md`).

## Designs (`caddy_design`, fed by `vm_proxy_design`)

| | `primary` (default) | `bridge_fallback` |
|---|---|---|
| Quadlet network | `Network=host`, no `PublishPort` | `Network=caddy.network`, `PublishPort=<vm_zt_ip>:443:443` |
| Bind | `default_bind <caddy_bind_address>` in the Caddyfile | none in the Caddyfile (inside the container the ZeroTier address does not exist); the port publish restricts it to `vm_zt_ip` |
| Upstream | `127.0.0.1:3000` (Semaphore published on loopback) | `semaphore:3000` (same network) |
| `caddy.network` Quadlet | not deployed | deployed (shared with Semaphore) |

In the fallback a site whose upstream is a loopback address (`127.0.0.1:` or
`localhost:`) is mapped to `caddy_upstream_fallback`, so `caddy_sites` does not
change between designs. The fallback's limitation (SH-R-04) is that Caddy may
see a bridge address instead of the client; the `remote_ip` allow list then
answers 403 to everyone (fails closed). Whether the client address survives is
tested at step 3 (SH-AC-51) in the design in use.

## Fails closed while `vm_zt_ip` is empty

The first tasks assert that `caddy_bind_address` (= `vm_zt_ip`) is a plain
IPv4 address (not empty, not `0.0.0.0`) and fail naming `vm_zt_ip` before any
file is touched (SH-FR-193, SH-AC-62). They also check `caddy_design` and
`caddy_allowed_sources`. Run alone with `site.yml --tags caddy`.

## Boot order and restarts

`default_bind` makes Caddy exit if the address does not exist yet (boot, or a
ZeroTier restart). The Quadlet orders the unit after `zerotier.service`, and
`Restart=always` with `RestartSec=10` makes systemd retry until the address is
there (SH-E-33). `RestartSec` matters: with systemd's 100 ms default the start
limit would be hit within seconds and the unit would stay failed.
`OnFailure=notify-failure@%n.service` sends the alert email.

## Why a custom-built image

The official `caddy:2` image has no DNS provider plugins. `files/Containerfile`
builds one with `xcaddy` and the `caddy-dns/cloudflare` module; the role builds
it locally with `containers.podman.podman_image` (no third-party image).
Base images (version + digest), Caddy and the module are pinned in the
Containerfile (security review F-02); the header comment there says how to bump
them by hand. A changed Containerfile forces a rebuild and restarts Caddy.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `caddy_design` | `primary` | `primary` or `bridge_fallback`. |
| `caddy_image` | `localhost/caddy-cloudflare:2` | Tag of the locally built image. |
| `caddy_data_dir` | `/opt/podman/caddy` | Host dir for the build context, Caddyfile, `caddy.env` and state (certs in `data/`; back it up). |
| `caddy_build_dir` | `{{ caddy_data_dir }}/build` | Containerfile build context. |
| `caddy_network_subnet` | `""` | Fixed subnet of `caddy.network` (fallback only); production = `semaphore_network_subnet` so the fail2ban/`from=` subnet matches (F-05). Empty omits `Subnet=`. |
| `caddy_bind_address` | `""` | Listen address (`vm_zt_ip`). Empty fails the role. |
| `caddy_allowed_sources` | `10.243.0.0/16`, `10.10.0.0/16` | IPv4 CIDRs allowed; others get 403. Must not be empty. |
| `caddy_upstream_primary` | `127.0.0.1:3000` | Upstream of a site that names none. |
| `caddy_upstream_fallback` | `semaphore:3000` | Upstream used instead of a loopback one in the fallback. |
| `caddy_acme_email` | `""` | Let's Encrypt account email (optional). |
| `caddy_sites` | `[]` | List of `{ host, upstream?, extra? }`. |

Access log: every request to a site writes one JSON line to the container's
stdout (`journalctl -u caddy`), including the client address (SH-FR-196).

## Secrets

The Cloudflare token (`vault_cloudflare_dns_api_token`, surfaced as
`cloudflare_dns_api_token`) is rendered to `<caddy_data_dir>/caddy.env`, mode
`0600`, owner root, and read through `EnvironmentFile=`. The task has
`no_log: true`, so `--diff` does not print it. Use a scoped token with
`Zone:DNS:Edit` on `wahlberger.dev`.

## Tests

- `tests/render-check.sh` renders both designs (`-e caddy_design=bridge_fallback`
  renders everything as the fallback) and checks the Quadlets with
  `systemd-analyze verify`.
- `ansible-playbook -i localhost, tests/guards.d/caddy.yml` runs the guard
  cases (separate from the `cloudflare_dns` guard, SH-AC-62).
