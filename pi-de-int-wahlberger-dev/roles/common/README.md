# common

Baseline OS configuration for Debian (Raspberry Pi OS) hosts: refreshes the
apt cache, optionally runs a full upgrade, installs a small baseline package
set, sets the system timezone, and sets the actual OS hostname to
`inventory_hostname` (this host's real FQDN) — not something initial
provisioning necessarily gets right on its own; `/etc/hosts` gets a matching
static fallback entry too, so `sudo` never prints "unable to resolve host"
if DNS is briefly unavailable.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `common_packages` | `[ca-certificates, curl, gnupg, htop, vim]` | Packages installed on every host. |
| `common_timezone` | `Europe/Berlin` | IANA timezone name. |
| `common_upgrade` | `true` | Run a full `apt upgrade`. |
| `common_apt_cache_valid_time` | `3600` | Seconds the apt cache is considered fresh. |
