# Spike A-33: Caddy global options `admin off`, `auto_https disable_redirects`, `default_bind`

Date 2026-10-10. Spec: SH-A-33 (inputs to SH-FR-183, SH-FR-184, SH-FR-129, task T-08; risk R2). Evidence level: container with its own network namespace ("simulator": it proves the syntax and what the process listens on, not host networking on the x86_64 VM). Nothing touched a real host.

## Images
- `docker.io/library/caddy:2` = v2.11.7 (pulled 2026-10-10).
- NAS-role build: `roles/caddy/files/Containerfile` built unchanged (`docker build -f Containerfile.cf .`, about 90 s) = v2.11.7 with module `dns.providers.cloudflare`.

## Working syntax (validated on both images)
```
{
	admin off
	auto_https disable_redirects
	default_bind 127.0.0.1        # on the VM: {{ caddy_bind_address }} (= vm_zt_ip)
	acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}   # only in the xcaddy image
}
semaphore.example.test {
	@denied not remote_ip 10.243.0.0/16 10.10.0.0/16
	respond @denied 403
	reverse_proxy 127.0.0.1:3000
}
```
Commands: `caddy validate --config /etc/caddy/Caddyfile` -> "Valid configuration" (caddy:2, with `tls internal` in the site because the plain image has no DNS module) and rc=0 (xcaddy image; the cloudflare module rejects a token that is not token-shaped, so the dummy was 40 x `a`).
`caddy adapt` shows: `"admin":{"disabled":true}`, `"listen":["127.0.0.1:443"]`, `"automatic_https":{"disable_redirects":true}`.

## ss-equivalent proof (no 80, no 2019)
`docker run -d` of each image with that Caddyfile, then `docker exec ... netstat -tlnp`:
```
tcp 0 0 127.0.0.1:443 0.0.0.0:* LISTEN 1/caddy        (the only listener, both images)
```
`wget http://127.0.0.1:2019/config/` and `wget http://127.0.0.1:80/` from inside the namespace: connection refused. Log: `admin endpoint disabled`; `automatic HTTP->HTTPS redirects are disabled`.

## 403 matcher (SH-FR-129)
Client at 127.0.0.1 (curl container sharing the netns, `--resolve`): outside the allow list -> `403`. With the list changed to include `127.0.0.0/8` -> `502` (passes the matcher, no upstream). So `not remote_ip` + `respond 403` works. It works on the real peer address only if Caddy sees the real client address (host networking, AC-51); not provable here.

## Notes for T-08
- Global options take no `http_port`/`:80` listener: with `default_bind` + `disable_redirects` there is no port-80 socket. No `auto_https off` needed (it would also disable cert issuance).
- `default_bind <ip>` fails the Caddy start if the IP is not on the host at that moment: the Quadlet must be ordered after the ZeroTier interface/address is up (host networking design), else Caddy exits on boot.
- The existing NAS template's global block has no `admin off`, so the VM template cannot be copied as is.
- `tls internal` is only needed for local tests; production uses `acme_dns cloudflare`.

## Decision
A-33 holds on `caddy:2` and on the xcaddy build; no alternative syntax needed. T-08 uses the block above (admin off, auto_https disable_redirects, default_bind from `caddy_bind_address`). Affects: T-08, T-09 (host-network ordering), AC-51 (still to be proven on the VM).
