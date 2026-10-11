# zerotier

Joins this host to the home ZeroTier overlay network — the same network your
router already bridges the whole home LAN into, and that the TrueNAS
instance in Sweden is already a member of. Runs as a Podman Quadlet using
the official [`zerotier/zerotier`](https://hub.docker.com/r/zerotier/zerotier)
image.

## Why this host needs it at all

`cloud-wahlberger-dev` is a public Hetzner VM with no other path into the
home network. Every `*.de.int.wahlberger.dev` hostname resolves (via the
`cloudflare_dns` role) to a private LAN IP — fine for hosts already on that
LAN or on ZeroTier, but from cloud's public-internet vantage point those
addresses are simply unroutable. `uptime_kuma` needs this role to be able to
reach `nas.de.int.wahlberger.dev`/`pi.de.int.wahlberger.dev` at all — see
`roles/uptime_kuma/README.md`.

## Why `Network=host`, not `caddy.network`

A container's network namespace is isolated by default — if ZeroTier ran on
`caddy.network` like everything else here, its tunnel would only be usable
by the ZeroTier container itself, not by sibling containers like
`uptime-kuma`. The whole point is giving the **host** a route into the home
LAN, so anything that NATs through the host's own network stack — which is
exactly what a bridge-networked container like `uptime-kuma` does for
outbound traffic — can use it too. That only works with host networking.

## Persisting the identity

`zerotier_data_dir` is bind-mounted to `/var/lib/zerotier-one` inside the
container, where ZeroTier keeps its identity keys. This **must** survive
container restarts — recreating it means a brand new identity, indistinguishable
to ZeroTier Central from a totally different device, needing to be
re-authorized from scratch.

## One manual step this role can't do for you

Joining a network still requires the network's owner to **authorize the new
device** — a deliberate ZeroTier design choice, not something an API token
in this role could (or should) bypass. After the first deploy:

1. Check `sudo podman exec zerotier zerotier-cli listnetworks` — it should
   show the network in a "REQUESTING_CONFIGURATION" or similar
   not-yet-authorized state at first.
2. Go to [ZeroTier Central](https://my.zerotier.com/) (or your router's
   controller UI) and authorize the new member — it'll show up under the
   same network ID, with a device name/ID but not yet checked.
3. Re-run `zerotier-cli listnetworks` — it should now show `OK` and an
   assigned IP in the LAN's range.

## Role variables

See `defaults/main.yml`. `zerotier_network_id` is required — the 16-character
network ID, not secret, but membership always needs separate authorization
regardless of who knows it.
