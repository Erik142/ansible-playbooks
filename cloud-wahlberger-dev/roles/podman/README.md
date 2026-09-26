# podman

Installs Podman with Docker-compat CLI and Quadlet support, creates the
persistent data directory, ensures the Quadlet unit directory exists, and
(optionally) enables the Podman API socket.

Containers themselves are **not** defined here — they are deployed as Quadlet
`.container` units by service roles via the generic [`container`](../container)
role.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `podman_packages` | `[podman, podman-docker]` | Packages to install. |
| `podman_data_dir` | `/opt/podman` | Root for persistent container data. |
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

## IPv4 forwarding

Published ports on rootful Podman need `net.ipv4.ip_forward=1`. netavark only
sets it at runtime, so a package upgrade re-applying sysctl defaults turns it
off and routed connections to published ports (e.g. Caddy's 80/443) hang while
the containers still show "Up". The role persists it in
`/etc/sysctl.d/99-podman-ip-forward.conf`.

## Container /etc/hosts

`podman_base_hosts_file` (default `image`) sets containers.conf's
`base_hosts_file`, so containers no longer inherit the host's `/etc/hosts`.
Otherwise a host that maps its own FQDN to `127.0.1.1` (cloud-init's
`manage_etc_hosts` does this on the Pi at every boot) makes any container that
resolves that name connect to its own loopback — e.g. Semaphore SSHing to its
own host. Applies to containers created after the change; restart the Quadlet
service to recreate one.
