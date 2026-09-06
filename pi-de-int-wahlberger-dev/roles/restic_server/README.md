# restic_server

[restic](https://restic.net/)'s own REST server — a backup target
`nas-de-int-wahlberger-dev` pushes nightly backups to, running as a Podman
Quadlet. This is meant to become the *permanent* home for the NAS's backups
(not just a stopgap), until a Hetzner Storage Box is added as a second
target.

## Why rest-server over SFTP

restic supports several backends; rest-server was chosen over the simpler
SFTP option because it supports `--private-repos` (each htpasswd user
confined to their own subdirectory — see below) and `--append-only` (not
enabled yet, see below), neither of which SFTP + plain SSH gives you for
free. It's also the officially recommended backend for serving restic to
multiple clients.

## Why no TLS

The data restic sends is already encrypted client-side by the *repository*
password before it ever leaves the NAS — rest-server only ever sees
encrypted blobs. The only thing plain HTTP exposes here is the htpasswd
credential, and this server is deliberately never reachable outside the home
LAN/ZeroTier range (see `restic_server_allowed_src`, enforced in this role's
own ufw rule, not `firewall_allowed_tcp_ports` — that list is for
services meant to be open to the whole internet, like Caddy's 80/443, which
this explicitly is not). Given that, plain HTTP over a trusted LAN was judged
not worth the extra moving part (self-signed cert management) — revisit if
this server is ever exposed beyond the LAN.

## Role variables

See `defaults/main.yml`. `restic_server_htpasswd_password` is required and
is a **shared secret**: `vault_restic_server_htpasswd_password` here must
hold the exact same value as
`nas-de-int-wahlberger-dev`'s `vault_restic_backup_rest_server_password`.
Generate it once, put it in both playbooks' Vaults.

## Adding a second backup client later

With `--private-repos` enabled, each htpasswd user's repository is confined
to `{{ restic_server_data_dir }}/<username>/`. Adding a client (another
host, or a future Hetzner Storage Box relay) is just another
`community.general.htpasswd` entry — no other reconfiguration.

## Not yet done: `--append-only`

rest-server supports `--append-only`, which would stop a compromised NAS
from being able to delete or tamper with existing backups via the REST API
— real defense in depth, since the NAS holds a guest-accessible Samba
share. It's not enabled here because it also blocks `restic forget --prune`
over the same API, which the NAS's nightly job relies on for retention;
using it well needs a separate, more careful prune workflow. Worth adding
once this setup is proven out.
