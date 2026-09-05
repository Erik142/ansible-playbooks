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
