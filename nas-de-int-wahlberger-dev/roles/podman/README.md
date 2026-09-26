# podman

Installs Podman with Docker-compat CLI and Quadlet support, verifies the
persistent data directory is on its own mounted filesystem, creates it, and
ensures the Quadlet unit directory exists.

Containers themselves are **not** defined here — they are deployed as Quadlet
`.container` units by service roles via the generic [`container`](../container)
role.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `podman_packages` | `[podman, podman-docker]` | Packages to install. |
| `podman_data_dir` | `/mnt/containers` | Root for persistent container data — must already be a mountpoint. |
| `podman_quadlet_dir` | `/etc/containers/systemd` | Where systemd reads Quadlet units. |
| `podman_enable_socket` | `true` | Enable/start `podman.socket`. |
| `podman_image_prune_enabled` | `true` | Install/enable the weekly image-prune timer. |
| `podman_image_prune_on_calendar` | `weekly` | `OnCalendar` expression for the timer. |
| `podman_image_prune_min_age` | `168h` | Only prune unused images older than this. |

## Image pruning

`podman-image-prune.timer` runs `podman image prune --all --force --filter
until=<min_age>` on a schedule. Images used by any container (running or
stopped) are never removed, and named volumes are untouched, so this only
reclaims space from replaced image versions. Check with
`systemctl list-timers podman-image-prune.timer` and
`journalctl -u podman-image-prune.service`.

## Data layout

`podman_data_dir` is expected to be a separately mounted disk (this NAS splits
Samba data and container data across two different storage media — see the
top-level README). The role asserts it's an actual mountpoint before creating
anything under it, so a missing mount fails loudly instead of silently writing
container data onto the root filesystem.

## IPv4 forwarding

Published ports on rootful Podman need `net.ipv4.ip_forward=1`. netavark only
sets it at runtime, so a package upgrade re-applying sysctl defaults turns it
off and routed connections to published ports (e.g. Caddy's 80/443) hang while
the containers still show "Up". The role persists it in
`/etc/sysctl.d/99-podman-ip-forward.conf`.
