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

## Data layout

`podman_data_dir` is expected to be a separately mounted disk (this NAS splits
Samba data and container data across two different storage media — see the
top-level README). The role asserts it's an actual mountpoint before creating
anything under it, so a missing mount fails loudly instead of silently writing
container data onto the root filesystem.
