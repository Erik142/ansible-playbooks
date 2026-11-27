# firewall

Host firewall via **firewalld** for the ops VM: the public zone accepts SSH
only, and the ZeroTier interface is bound by name to its own zone that serves
the Semaphore UI (HTTPS) and the Beszel agent port. This is the effective gate
for host-networked Caddy (SH-FR-06, SH-FR-08, SH-FR-09, SH-FR-128, SH-CC-15).

## Zone model

| Zone | Bound to | Allows |
|------|----------|--------|
| `public` (`firewall_zone`) | the public interface (firewalld default zone) | service `ssh` only; masquerade stays on for Podman |
| `zerotier` (`firewall_zerotier_zone`) | `firewall_zerotier_interface` (= `vm_zt_iface`), bound by name in the permanent configuration | services `ssh` and `https`; `45876/tcp` from `firewall_cloud_zt_ip` only (rich rule) |
| `trusted` | every Podman network (netavark adds each subnet) | everything |

The role changes rules as **permanent plus immediate** and never asks firewalld
to re-read or bounce its configuration (SH-FR-189, SH-AC-56), because the
Semaphore self-run reaches the VM over ZeroTier and a bounce would cut it.
Order inside the role keeps SSH reachable at every step: public `ssh` first,
extras removed after, the ZeroTier zone's `ssh` before the interface binding.

## Role variables

| Variable | Default | Description |
|----------|---------|-------------|
| `firewall_zone` | `public` | Zone of the public interface. |
| `firewall_allowed_services` | `[ssh]` | Services the public zone allows. |
| `firewall_public_removed_services` | `[dhcpv6-client, mdns, samba, http, https, cockpit]` | Disabled in the public zone if present, so it offers `ssh` only. Entries also in `firewall_allowed_services` are kept. |
| `firewall_allowed_ports` | `[]` | Extra `"port/proto"` entries in the public zone; admit every source. |
| `firewall_rich_rules` | `[]` | Rich rules for the public zone, applied after services/ports. |
| `firewall_zerotier_interface` | `""` | ZeroTier interface name (`vm_zt_iface`). Empty: ZeroTier binding and rules are skipped, with a message naming `vm_zt_iface` (SH-FR-194). |
| `firewall_zerotier_zone` | `zerotier` | Zone name for the ZeroTier interface. |
| `firewall_zerotier_services` | `[ssh, https]` | Services the ZeroTier zone allows. |
| `firewall_zerotier_agent_port` | `45876` | Beszel agent port, allowed in the ZeroTier zone from `firewall_cloud_zt_ip` only. |
| `firewall_cloud_zt_ip` | `""` | cloud's ZeroTier IPv4 (`cloud_zt_ip` in group_vars). Required whenever the interface is set; the role fails before any change if it is not an IPv4 address, and if the interface name is not a valid Linux name. |

`group_vars` must feed `firewall_cloud_zt_ip: "{{ cloud_zt_ip }}"` next to the
existing `firewall_zerotier_interface: "{{ vm_zt_iface }}"`.

The role only ever **adds** rich rules (found on the VM, BD-AC-45): dropping an
entry from `firewall_rich_rules` does not remove its rule. Remove it by hand with
`firewall-cmd --permanent --zone=<zone> --remove-rich-rule='<rule>'` and the
same command without `--permanent`.

## First run of the ZeroTier zone

firewalld only knows a newly created zone at runtime after it re-reads its
permanent configuration, which this role does not trigger. On the run that
creates the zone, the role therefore writes the zone, services, rich rule and
interface binding to the **permanent** configuration only, and prints a message
saying so. Until the operator makes firewalld re-read it (runbook step, see
`<vm-dir>/README.md`), or the host boots, ZeroTier traffic still falls in the
public zone. The next role run finds the zone active and converges the runtime
state too. The permanent binding by name also covers an interface that appears
after firewalld has started (SH-FR-185).

### `--check --diff` on a fresh host

Check mode only simulates creating the zone, so `firewalld` has no `zerotier`
zone to change and the module would fail with `INVALID_ZONE`. The role sets
`firewall_zerotier_zone_ready` (always true in a real run; in check mode only
when the permanent configuration already holds the zone) and gates the three
zone-dependent tasks on it: services in the zone, the Beszel agent rich rule and
the interface binding. On a fresh host a `--check` run therefore **skips those
three tasks and cannot validate them**; the first real run (or a `--check` after
the zone exists) does. The operator must not read their absence as success
(runbook step 2 and 4). `tests/guards.d/firewall.yml` fails if a zone task loses
the gate.

## Container traffic bypasses these rules

netavark puts each Podman network's subnet into zone `trusted`, so a container
on any Podman network reaches a host-networked listener such as Caddy
regardless of the zone rules above. Only the listener's own controls
(Caddy's bind address and `remote_ip` allowlist, authentication) stand in the
way. Zone rules gate traffic from outside the host.

## Podman caveat

Rootful Podman publishes container ports via DNAT, which crosses firewalld's
FORWARD/NAT path, not a plain INPUT filter. `masquerade` must stay enabled on
the public zone or published ports stop working.

## Tests

Not provable in a container (firewalld needs nftables). `tests/guards.d/firewall.yml`
(`tests/guard-tests.sh firewall`) is a static guard: `firewall_zerotier_zone_ready`
is defined, depends on `ansible_check_mode`, and every zone-dependent task in
`tasks/zerotier.yml` is gated on it. The zone behaviour itself is checked on the
fixture VM (`tests/vm`) and live.

## Inspect on the host

```sh
sudo firewall-cmd --permanent --zone=zerotier --list-all
sudo firewall-cmd --get-zone-of-interface=<zt-iface>
sudo firewall-cmd --permanent --zone=public --list-services
```
