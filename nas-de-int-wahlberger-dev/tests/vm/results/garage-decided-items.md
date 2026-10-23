# Garage decided items (security findings 1, 6, 7): VM run 2026-10-19

VM fixture (FIXTURE_VM_DIR=~/.cache/nas-fixture-vm-garage), `tests/vm/ans.sh`, V3/V4 state kept.

## Role run
- `ansible-playbook site.yml --tags garage --check --diff`: exit 0, changed=2 (garage.network, garage.container).
- Real run: exit 0, changed=4 (network Quadlet, container Quadlet, two restart handlers). Second run: changed=0.
- `podman inspect garage`: ImageName `docker.io/dxflrs/garage@sha256:9c96caa2...d020` (index digest of v2.4.1,
  pulled by digest), network `systemd-garage` only; `podman ps` healthy.
- First attempt failed on `container_quadlet_dir` undefined in the new task (the variable belongs to the
  container role); fixed by using /etc/containers/systemd like the caddy role.

## Reachability (stand-in Caddy = caddy:2 on garage.network with the production O-6 body incl. the new headers)
| Check | Result |
|---|---|
| API route via Caddy (anonymous GET /) | 403 (Garage answers) |
| Web route via Caddy (GET /sstate/x) | 404 from Garage, headers `Content-Security-Policy: sandbox`, `X-Content-Type-Options: nosniff` present |
| garage:3900 / garage:3902 from garage.network | 403 / 404 (reachable) |
| Container on caddy.network (systemd-caddy), garage:3900 and :3902 by name | `Could not resolve host: garage` |
| Same, by garage's garage.network IP 10.89.1.3, ports 3900 and 3902 | connection timed out (dropped) |
| Host listeners on 3900-3903 | none |

Note: from caddy.network the result is not "connection refused": the name does not resolve and a direct IP
connection is dropped (timeout), which is stronger than refused.
