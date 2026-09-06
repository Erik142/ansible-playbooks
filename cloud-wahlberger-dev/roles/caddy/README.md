# caddy

Reverse proxy using the **official Caddy image** with automatic HTTPS
(Let's Encrypt via HTTP-01). It also creates the shared `systemd-caddy` Podman
network that backend services (e.g. `pocket_id`) attach to.

> We deliberately use the official `caddy` image, not a third-party build like
> `caddy-docker-proxy`. Routes are declared in `caddy_sites` (in Git) and
> rendered into a Caddyfile — no Podman socket is exposed to the proxy.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `caddy_image` | `docker.io/library/caddy:2` | Official Caddy image. |
| `caddy_data_dir` | `/opt/podman/caddy` | Host dir for Caddyfile + state (certs in `data/`). |
| `caddy_http_port` | `80` | Host port → container 80. |
| `caddy_https_port` | `443` | Host port → container 443. |
| `caddy_acme_email` | `""` | Let's Encrypt account email (optional). |
| `caddy_sites` | `[]` | List of `{ host, upstream?, extra? }` to serve. |

## Adding a site

Add an entry to `caddy_sites` (in `group_vars`) and re-run — no host edits:

```yaml
caddy_sites:
  - host: id.wahlberger.dev
    upstream: "pocket-id:1411"
  - host: grafana.wahlberger.dev
    upstream: "grafana:3000"
    extra: |
      basic_auth {
        admin <hashed-password>
      }
```

`upstream` is optional — omit it for a site whose whole body needs to be
custom, e.g. an auth-gated site where `reverse_proxy` isn't the top-level
directive at all (see `uptime_kuma`'s `forward_auth`/`handle` block, which
`extra` alone provides):

```yaml
caddy_sites:
  - host: status.wahlberger.dev
    extra: |
      handle /oauth2/* {
        reverse_proxy oauth2-proxy:4180
      }
      handle {
        forward_auth oauth2-proxy:4180 {
          uri /oauth2/auth
          @error status 401
          handle_response @error {
            redir * /oauth2/sign_in?rd={scheme}://{host}{uri}
          }
        }
        reverse_proxy uptime-kuma:3001
      }
```

Each `host` must resolve to this VM (DNS-only / grey-cloud in Cloudflare) for
HTTP-01 certificates to issue. Certificates persist in `/opt/podman/caddy/data` —
back that up.
