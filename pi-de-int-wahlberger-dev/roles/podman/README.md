# podman

Installs Podman with Docker-compat CLI and Quadlet support, creates the
persistent data directory, ensures the Quadlet unit directory exists, and
enables the Podman API socket.

Containers themselves are **not** defined here — they are deployed as Quadlet
`.container` units by service roles via the generic [`container`](../container)
role.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `podman_packages` | `[podman, podman-docker]` | Packages to install. |
| `podman_data_dir` | `/mnt/data/containers` | Root for persistent container data — a subdirectory of the external drive the `storage` role mounts. |
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
