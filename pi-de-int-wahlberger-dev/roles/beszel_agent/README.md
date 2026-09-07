# beszel_agent

[Beszel](https://beszel.dev/) monitoring agent: reports CPU, memory, disk,
network, temperature, and Podman container stats to the `beszel_hub` role
running on cloud-wahlberger-dev.

## Native, not a container — deliberately

Unlike almost everything else in this repo, the agent runs as a plain
systemd service, not a Podman Quadlet. Beszel needs fairly deep host access
to report meaningful metrics — `/proc`, `/sys`, raw block devices for
S.M.A.R.T., temperature/fan sensors, and the Podman API socket — and this
repo has already hit real container-boundary friction getting a *container*
that kind of host access right elsewhere (see the NAS playbook's
`roles/samba/README.md` SELinux section and `roles/immich/README.md`'s
hardware-acceleration section). A native binary just has normal host access
without any of that, and Beszel ships a static binary specifically for this.

## Depends on `beszel_hub`

`beszel_agent_hub_key` is **required** and has no usable default — it's the
hub's own SSH public key, which only exists after the hub's first boot
(it's generated then, not something Ansible/Vault can pre-seed). Workflow:

1. Deploy `beszel_hub` on cloud-wahlberger-dev first.
2. Log into the hub's web UI, add this host as a "System" — either the UI
   surface for adding a system or its Settings page shows the hub's own SSH
   public key (a `ssh-ed25519 ...` line). Copy it.
3. Set `beszel_agent_hub_key` to that value in this playbook's `group_vars`
   and re-run.

The hub connects **to** this agent (not the other way around) — see
`roles/beszel_hub/README.md` for why. That means `beszel_agent_port`
(default `45876`) must be reachable from cloud-wahlberger-dev, which for
this host means adding it to `firewall_allowed_tcp_ports` in `group_vars`
(already done — see `inventories/production/group_vars/all/vars.yml`).

## Podman container stats without running as root

Beszel auto-detects a Docker-compatible API and reports container stats
through it — but our Podman socket (`roles/podman`) is rootful and
group-owned by `root` (mode `0660`), and this role deliberately runs the
agent as its own unprivileged `beszel` user rather than root. Adding
`beszel` to the `root` group to reach the socket would have been far
broader access than intended, so this role instead:

1. Creates a narrowly-scoped `beszel_agent_podman_group` group (default
   `podman`), used for nothing else.
2. Drops in a `podman.socket.d` override setting `SocketGroup=podman`.
3. Adds the `beszel` user to that group.

This changes who *can* use the Podman socket, not who's in it by default —
existing Quadlet-managed containers are entirely unaffected, since they
never talk to the socket to begin with.

### The socket file's group alone isn't enough

Discovered live (Beszel showed metrics but no container stats even after
the above, on nas-de-int-wahlberger-dev/cloud-wahlberger-dev): reaching a
socket file at all requires *search* permission on every directory
component of its path, not just the right group on the file itself.
`podman.socket` creates `/run/podman` itself on activation, and its
default mode isn't guaranteed the same across hosts or Podman versions —
`0700 root:root` on those two hosts (blocking `beszel_agent_user` outright,
regardless of the socket file's own group), `0755` here. This role now
also forces `/run/podman` to `0755`, group `beszel_agent_podman_group`,
unconditionally — not relying on this host's current mode staying that way
across a future Podman package upgrade. Since `/run` is tmpfs and gets
recreated every boot (undoing a plain one-off `chmod`), a `tmpfiles.d` rule
reapplies it automatically on every future boot too, before regular
services (including `podman.socket`) start.

## Verifying the download

`beszel_agent_checksum` is looked up at run time from Beszel's own published
`beszel_<version>_checksums.txt` for this host's exact architecture, then
passed to `ansible.builtin.get_url`'s `checksum` parameter — the same
verification Beszel's own install script performs, just re-implemented as
idempotent Ansible tasks instead of a curl-pipe-sh script.
