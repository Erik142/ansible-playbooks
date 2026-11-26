# beszel_hub

Beszel monitoring hub (PocketBase based) as a Podman Quadlet behind Caddy. It
collects metrics from `beszel_agent` on the homelab hosts, including the edge host
itself. Login goes through Pocket ID (OIDC).

## Migration note

`beszel_hub_data_dir` (`/opt/podman/beszel-hub`) holds the hub's SSH keypair. Each
agent trusts the public half through `beszel_agent_hub_key`. Restoring this directory
keeps that key valid, so the agents on ops, ci and NAS need no change.

The superuser account and OIDC login were set up by hand on the old host. They are
stored in the PocketBase database inside this directory, so they survive a restore.
