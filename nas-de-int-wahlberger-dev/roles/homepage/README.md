# homepage

[Homepage](https://gethomepage.dev/) dashboard, deployed as a Podman Quadlet
on the shared `caddy.network` and reverse-proxied by the `caddy` role. A
single landing page linking services from **cloud-wahlberger-dev**, this NAS,
**pi-de-int-wahlberger-dev**, and the **TrueNAS** instance in Sweden (a
separate physical host, not managed by any playbook in this repo) —
`rpi-karlsruhe` is intentionally excluded (legacy, being retired).

Deliberately simple: static grouped links with lightweight `ping`-based
status indicators, no API keys, no Podman socket exposed to the container —
Homepage supports much richer per-app "widgets" (live recipe counts, document
counts, etc.) if you want to add them later, but that means giving it an API
key per app and is out of scope for a first version.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `homepage_image` | `ghcr.io/gethomepage/homepage:latest` | Homepage image — **pin this to a specific tag** once verified (see comment in `defaults/main.yml`). |
| `homepage_data_dir` | `/mnt/containers/homepage` | Host directory for the rendered config. |
| `homepage_title` | `wahlberger.dev` | Dashboard page title. |
| `homepage_url` | `""` (**required**) | Public https:// URL Homepage is served on. |
| `homepage_pocket_id_url` | `{{ pocket_id_app_url }}` | Pocket ID link (cloud-wahlberger-dev). |
| `homepage_freshrss_url` | `https://rss.wahlberger.dev` | FreshRSS link (cloud-wahlberger-dev). |
| `homepage_uptime_kuma_url` | `https://status.wahlberger.dev` | Uptime Kuma link (cloud-wahlberger-dev). |
| `homepage_semaphore_url` | `https://semaphore.de.int.wahlberger.dev` | Semaphore UI link (pi-de-int-wahlberger-dev). |
| `homepage_truenas_url` | `https://truenas.boras.int.wahlberger.dev` | TrueNAS link (separate physical host in Sweden). |

## Adding/removing a service

Edit `roles/homepage/templates/services.yaml.j2` directly — it's a plain
grouped list, each entry an `href` + `description`, optionally a `ping` URL
for a live status dot. No host edits needed beyond a re-run.

**`ping` for a service running on this same NAS: use its internal
`http://<container_name>:<port>` address, not its public hostname.** A
public hostname for a service on this same host resolves (via public DNS) to
this NAS's own LAN IP — Homepage pinging its own host's external address to
reach a sibling container is a NAT hairpin that Podman's default bridge
networking doesn't handle, and the check fails even though the exact same
URL works fine from an actual external client. Since every service here
shares `caddy.network`, the container name resolves directly via Podman's
network-scoped DNS. Only services on a genuinely different host (like
cloud-wahlberger-dev's Pocket ID/FreshRSS) should `ping` their public URL —
see `services.yaml.j2` for both patterns side by side.

## `HOMEPAGE_ALLOWED_HOSTS`

Homepage (a Next.js app) rejects requests for any host not in this
environment variable — the Quadlet sets it from `homepage_url` automatically
(scheme stripped). If you ever see a blank page or a host-mismatch error
after changing `homepage_url` or adding an alternate hostname, check this is
still correct.

## Verify Homepage's icon library before relying on icons

`services.yaml.j2` doesn't set `icon:` per entry (left out deliberately —
guessing filenames that don't exist in Homepage's bundled icon pack renders a
broken image). Check [gethomepage.dev's icon docs](https://gethomepage.dev/configs/services/#icons)
for exact available names if you want to add them.
