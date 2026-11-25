## Decision: Where to run the Forgejo Actions runner that builds lab-grab images          date: 2026-10-01   status: proposed

### Context / constraints
Verified in the repos (2026-10-01):
- NAS `nas.de.int.wahlberger.dev`: openSUSE Tumbleweed, x86_64 (Intel Alder Lake-N iGPU, `roles/immich/README.md`), rootful Podman Quadlets, `podman.socket` enabled (`roles/podman`). Already runs Immich (+ML), Paperless, Tandoor, Forgejo, Caddy, Homepage, guest-RW Samba. RAM/core count is **not recorded in the repo**.
- Forgejo: `git.de.int.wahlberger.dev`, LAN/ZeroTier only, `REQUIRE_SIGNIN_VIEW=true`, OIDC auto-registration on, `forgejo_actions_enabled: false` ("no runner exists", `roles/forgejo/defaults/main.yml`). Volume owned by host uid 1000.
- `/mnt/containers` is backed up by restic (`restic_backup_paths`) and snapshotted by snapper. The root fs has a snapper `root` config.
- Hairpin: containers on the NAS cannot reach the NAS's own `*.de.int` hostnames over the Podman bridge (`roles/homepage/README.md`).
- Pi: hosts Semaphore plus every host's SSH key and the vault password (pi README). cloud-wahlberger-dev: public Hetzner VM with Pocket ID, already a ZeroTier member (`roles/zerotier`; each new member needs manual authorization).
- lab-grab: 5 Dockerfiles (Python 3.12/3.14-slim + pip; frontend = Hugo + `node:22-slim` npm ci/tsc/vite -> nginx), build context = repo root, frontend `git clone`s from GitHub at build time. `HEALTHCHECK` is in notification-service, sync-service and ssh-proxy. The target is amd64 (the NAS). The origin remote is already this Forgejo. There are no workflows yet.

### Options considered
1. **(a) NAS, rootless, host-mode runner**: no extra cost, native amd64, local push/pull. Cons: shares a kernel with household data; builds compete with Immich/Paperless.
2. **(c) Dedicated x86 Hetzner VM + ZeroTier** (copy cloud's `zerotier` role): host-level isolation from NAS data. Cons: monthly fee; a ZeroTier member routes to the whole LAN (incl. guest-RW Samba) unless flow rules restrict it; pushes go through the home uplink.
3. **(b) KVM VM on the NAS**: kernel isolation, still local. Cons: a new hypervisor layer (nothing in the repo for libvirt/KVM), a guest OS to patch, RAM taken from a single box that also runs Immich.
4. **(e) Ephemeral cloud runner**: each VM is a new ZeroTier identity needing manual authorization, or Forgejo has to become public. Overkill for one repo.
5. **(d) Pi / cloud VM / rpi-boras**: rejected. The Pi holds the infra master keys, the cloud VM holds the IdP and is internet-facing, rpi-boras is legacy DNS/DHCP. Pi arch is likely arm64, which means QEMU for amd64 (unverified).

### Recommendation
Option (a): forgejo-runner in **host mode** as a dedicated unprivileged user with rootless Podman.
- Flow: runner polls Forgejo outbound (no new ports) -> push to main/tag in lab-grab -> host step `podman build --format docker -f <svc>/Dockerfile .` -> `podman push` with a write:package PAT secret -> the NAS rootful Quadlets pull with a read:package token in a persistent root authfile.
- Why host mode: no job container (which avoids the hairpin), no Podman socket, no DinD, no nested user namespaces. `--format docker` keeps HEALTHCHECK, because the OCI format drops it (general knowledge).
- Hardening:
  - Runner registered at **repo scope** only.
  - Workflows trigger on `push`, not `pull_request`.
  - Runner user ≠ uid 1000, not in wheel.
  - Never mount `/run/podman/podman.sock` (root-equivalent).
  - capacity 1, systemd `MemoryMax`/`CPUQuota`.
  - Storage on its own btrfs subvolume outside `/mnt/containers`, so it stays out of restic and snapper.
  - Own rootless image prune; the rootful prune timer does not cover it.
- Why over (c): lab-grab's runtime code already runs on the NAS once deployed. The extra trust is only the build toolchain + npm devDependencies, run unprivileged.

### Risks / upgrade path
- Unverified: whether a host-netns push to the NAS's own LAN IP works through netavark DNAT. Test `podman push` as the runner user first.
- Unverified: whether Forgejo's automatic Actions token can push packages. Use a PAT until it's confirmed.
- Unverified: host mode needs Node.js on the host for `actions/checkout`, or use a plain `git clone` step instead.
- Renovate (GitHub) cannot see the LAN-only registry, so lab-grab tag bumps stay manual.
- Next step: if builds starve Immich/Paperless or untrusted contributors appear, move to (c) with ZeroTier flow rules allowing only nas:443.
