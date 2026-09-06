# snapper

Manages [snapper](https://snapper.io/) btrfs snapshot configs for the two
subvolumes the [`storage`](../storage/README.md) role mounts, plus
registering them in `/etc/sysconfig/snapper` and enabling the timeline
(hourly snapshot creation) and cleanup timers. Codifies configs that were
already hand-set-up on the host with `snapper -c <name> create-config
<subvolume>`.

## What this role does NOT do

`snapper create-config` also creates a `.snapshots` subvolume nested inside
the target subvolume — a one-time, host-specific btrfs write this role
deliberately does not automate (same reasoning as `storage` not formatting
a device). It only manages `/etc/snapper/configs/<name>` (a plain text
file) and the sysconfig registration. If `.snapshots` doesn't already
exist, the role fails fast with the exact `create-config` command to run
first, rather than deploying a config snapper can't use.

## Retention differs per subvolume, on purpose

`containers` keeps hourly snapshots (fast-changing container data,
recent-recovery-focused: 6 hourly + 5 daily, nothing longer). `data` skips
hourly entirely but keeps a much longer tail (7 daily, 4 weekly, 12
monthly, 2 yearly) — this is the Samba share and Paperless-ngx documents,
where "what did this file look like 6 months ago" matters more than
minute-to-minute churn. See `defaults/main.yml` for the exact numbers if
you want to tune either.

## Role variables

See `defaults/main.yml`. `snapper_configs` is the list of subvolumes to
manage; `snapper_preexisting_configs` (default `["root"]`) lists config
names this role must never remove from `SNAPPER_CONFIGS=`, since openSUSE's
own installer manages the root filesystem's config independently of this
role.

## Inspect on the host

```sh
sudo snapper list-configs
sudo snapper -c data list
sudo systemctl list-timers snapper-*
```
