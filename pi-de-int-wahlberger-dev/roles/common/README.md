# common

Baseline OS configuration for Debian (Raspberry Pi OS) hosts: refreshes the
apt cache, optionally runs a full upgrade, installs a small baseline package
set, and sets the system timezone.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `common_packages` | `[ca-certificates, curl, gnupg, htop, vim]` | Packages installed on every host. |
| `common_timezone` | `Europe/Berlin` | IANA timezone name. |
| `common_upgrade` | `true` | Run a full `apt upgrade`. |
| `common_apt_cache_valid_time` | `3600` | Seconds the apt cache is considered fresh. |
