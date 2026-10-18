# garage

Garage S3 object store as a rootful Podman Quadlet, on two dedicated btrfs
subvolumes (data on `/mnt/data`, metadata on `/mnt/containers`). Spec:
`reqs/garage-sstate.md`; plan: `PLAN-garage.md`. This file is a stub (T-01);
later tasks fill in the sections marked TODO.

## Variables

All inputs are in `defaults/main.yml` and declared in `meta/argument_specs.yml`
(the spec's Inputs table is normative). `garage_enabled` defaults to `false`;
`site.yml` runs the role after `caddy` and before `btrbk` only when it is true.
Enabling needs `backup_disk_enabled: true` (the role fails before any change
naming both flags).

## Runtime-fact contract

`garage_uid` and `garage_gid` are not inputs. `tasks/storage.yml` sets them with
`getent` for `garage_user`; the Quadlet (`templates/garage.container.j2`) and
`tasks/secrets.yml` consume them. The render check supplies fixture values.

## What this role does not do

- It does not publish any Garage port (no `PublishPort=`); Caddy reaches it over
  `caddy.network`.
- It does not create DNS records (`cloudflare_dns` does, from `caddy_sites`).
- It does not generate or rotate keys; Vault is the source of truth.
- It does not remove Garage when `garage_enabled` is set back to `false`.
- It does not touch the btrbk, snapper or Caddy configuration.

## TODO (later tasks)

Restore procedure (GS-FR-77), consumer settings (GS-FR-34), image user
(GS-FR-84), backup-gate and troubleshooting notes.
