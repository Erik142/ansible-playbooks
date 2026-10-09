# Spike T-04: firewalld rich rules vs Podman-published port (BD-A-05)

Status: **desk study, evidence UNVERIFIED.** No VM with real firewalld + nftables was
run (not possible in a container, see `CLAUDE.md`; the only local Lima VM `podman` is
a stopped Podman-machine VM, not an openSUSE NAS twin). The confirming test is
BD-AC-45 in T-29.

## Question
Do zone rich rules (`public`, source CIDR + `port 8000/tcp accept`) filter traffic to
`restic-server` when Podman publishes the port (`PublishPort=8000:8000`)? Allowed
sources: `10.10.0.0/16` and `10.243.0.0/16` (list `restic_server_allowed_sources`).

## Analysis
- Published port, rootful Podman: netavark installs a DNAT rule in nat PREROUTING
  (and OUTPUT for localhost). After DNAT the packet's destination is the container
  IP, so it takes the **FORWARD** path, not INPUT. firewalld zone rich rules and
  zone ports are INPUT rules (`filter_IN_<zone>_allow`); they are never consulted
  for DNATed traffic. Whether FORWARD admits it depends on netavark's own forward
  rules / firewalld forward policy, not on the zone's rich rules. This is the
  mechanism already documented in `roles/firewall/README.md` ("Podman caveat") and
  the reason cloud needs `firewall_forward_policy: ACCEPT`. Consequence: with
  `PublishPort`, an outside source can reach 8000 even with no 8000/tcp zone entry
  (and the rich rules cannot restrict it) -> BD-FR-111 likely FAILS. (Inference
  from documented behaviour; not measured.)
- Host networking (`Network=host`): rest-server listens in the host namespace, no
  DNAT; traffic is INPUT and is matched by the zone: an allowed rich rule accepts,
  everything else hits the zone default (reject/drop). BD-FR-111 holds by
  construction for external sources.
- Residual risk (both modes, unverified): traffic from a local Podman bridge to the
  host IP is INPUT on the bridge interface. If netavark/firewalld puts the bridge
  into a permissive zone (trusted/libpod-type), the default `podman` network would
  be accepted regardless of the public-zone rich rules, giving 200/401 instead of
  `000` for case (c). The source for case (b) `ac45-allowed` is the container's
  bridge IP (no masquerade on container->host traffic), so the rich rule on the CIDR
  only works if the bridge is in `firewall_zone`.

## Decision (T-14 input)
Use **host networking** for `restic-server`:
```
Network=host
Exec=... --listen :{{ restic_server_port }}   # rest-server flag --listen; no PublishPort
```
- No `PublishPort=` line. Do not add `8000/tcp` to `firewall_allowed_ports` or any
  service (BD-FR-110); access only via `firewall_rich_rules` (BD-FR-109, one
  `rule family="ipv4" source address="<CIDR>" port port="8000" protocol="tcp" accept`
  per `restic_server_allowed_sources` entry, built by T-20).
- Do not join `caddy.network` (host mode excludes it; rest-server needs none).
- `--listen` binds all interfaces: the port is reachable on any host interface, so
  firewalld is the only gate; a bind to a specific LAN IP is optional hardening.
- Idempotent: static Quadlet template, a single `Network=host`; no runtime
  firewalld/Podman state edits by the role. Ports below 1024 would need no change
  (8000 is fine for UID != 0).
- Consequences: container-to-host-port isolation is lost (rest-server shares the host
  network namespace; it still runs non-root, no caps); `podman port`/`ip:port`
  mapping is absent; the listener appears in `ss -ltnp` as host process.

## Not verified / for T-29 (BD-AC-45)
Commands (on the VM, expected): from VM-network client
`curl -s -m 5 -o /dev/null -w '%{http_code}' http://<VM IP>:8000/` -> 401;
`podman run --rm --network ac45-allowed curlimages/curl ...` -> 401;
`podman run --rm --network podman ...` -> `000`. If the last returns 401 the bridge
is in a permissive zone: reopen T-04/T-14 (move bridge to `firewall_zone` or add a
reject rich rule) and record per-mode HTTP codes here. Also run once with
`PublishPort` to confirm the bypass (outside source gets 401 with no rich rule).
Sources: roles/firewall/README.md (Podman caveat); BD-A-05 in
reqs/backup-overview.md; PLAN-backup.md T-04 and line 22.
