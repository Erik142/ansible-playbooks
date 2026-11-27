# netcup_network

Codifies the static IPv4 NetworkManager profile of the netcup VPS. The profile
was written by hand from the rescue system; this role owns it from now on.

- Writes `/etc/NetworkManager/system-connections/<name>.nmconnection` (0600) from
  `templates/static.nmconnection.j2`.
- Reloads NetworkManager's connection files on change. It never activates or
  deactivates the connection, so a run cannot drop SSH by itself.
- All values come from group_vars (interface, connection name, address,
  gateway, DNS). Nothing is hardcoded.

**Before the first apply:** diff the template against the live file
(`/etc/NetworkManager/system-connections/*.nmconnection`). The format must stay
the one that works now; the template is a standard keyfile and the IPv6 block is
an assumption until that diff is done.
