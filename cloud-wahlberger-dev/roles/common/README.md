# common

Baseline OS configuration for Debian hosts: refreshes the apt cache, optionally
runs a full upgrade, installs a small baseline package set, and sets the system
timezone.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `common_packages` | `[ca-certificates, curl, gnupg, htop, vim]` | Packages installed on every host. |
| `common_timezone` | `Etc/UTC` | IANA timezone name. |
| `common_upgrade` | `true` | Run a full `apt upgrade`. |
| `common_apt_cache_valid_time` | `3600` | Seconds the apt cache is considered fresh. |

## Example

```yaml
- hosts: cloud
  become: true
  roles:
    - role: common
      vars:
        common_timezone: Europe/Stockholm
```
