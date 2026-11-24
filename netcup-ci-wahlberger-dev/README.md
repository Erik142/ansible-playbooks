# netcup-ci-wahlberger-dev

Ansible playbook for the netcup VPS `ci.de.wahlberger.dev` (openSUSE Tumbleweed,
KIWI image from `ops-de-wahlberger-dev/netcup-image/`). It runs a rootless Forgejo
Actions runner for the NAS Forgejo instance. Layout and conventions follow
`ops-de-wahlberger-dev`; roles are copied, not shared.

## Status

Live and verified (2026-10-17): static network, hardened sshd, firewall (public
SSH closed, ZeroTier zone live), common, Beszel agent, ZeroTier, and the runner
(`forgejo_runner`), with the job image built and CI jobs running.

Open items are tracked in the PR and the feature branch, not here.

## Run

The host has no public SSH. Address it over ZeroTier:

```sh
ansible-playbook -i inventories/production/hosts.yml site.yml --check --diff -e ansible_host=10.243.73.1
ansible-playbook -i inventories/production/hosts.yml site.yml -e ansible_host=10.243.73.1
```

A run without `ansible_host` connects to the public name, which is closed.

## Roles

`common`, `netcup_network`, `notify_failure`, `disk_space`, `ssh_authorized_keys`,
`security`, `reboot_notify`, `firewall`, `podman`, `zerotier`, `beszel_agent`,
`forgejo_runner`. `container` is a helper. Not included: `restic_backup`,
`semaphore`, `caddy`, `cloudflare_dns`.

## Runner

- **Account:** `forgejo-runner` (system user, no login shell), rootless Podman,
  lingering. Subordinate IDs in `/etc/subuid` and `/etc/subgid`.
- **Quadlet:** `~forgejo-runner/.config/containers/systemd/forgejo-runner.container`.
  It runs `/bin/forgejo-runner daemon` as `0:0` inside the rootless namespace, which
  is the `forgejo-runner` host user. The Podman API is the user's socket only; no
  root socket is mounted.
- **Concurrency:** `capacity: 3`. Jobs are uncapped: job containers are created
  through the socket and sit outside the unit's cgroup, so `MemoryMax`/`CPUQuota`
  (4G / 200%) cover only the daemon. Decision recorded in the PR.
- **Labels:** `ubuntu-latest` and `ubuntu-24.04` (`localhost/ci-ubuntu-hosted:1`,
  GitHub-hosted look-alike with a populated tool cache), `ubuntu-node` (the older
  node-only image), `python`, `node` (node-capable images, pinned by digest) and
  `podman` (`localhost/ci-podman-node:1`, built on the host).
- **Hosted-style image:** Ubuntu 24.04, `RUNNER_TOOL_CACHE=/opt/hostedtoolcache`
  with Python 3.10–3.13, Node 20/22/24 and the newest stable Go. `setup-*` actions
  find these locally. Built from `templates/Containerfile.ubuntu-hosted.j2`, the
  base is not yet pinned by digest.
- **Job image `podman`:** `quay.io/podman/stable` plus node and git, with the
  `vfs` storage driver. `fuse-overlayfs` needs `/dev/fuse`, which job containers
  do not get. `vfs` builds are slower and use more disk.
- **Image pruning:** the user timer `forgejo-runner-image-prune.timer` runs
  `files/forgejo-runner-image-prune.sh` weekly. It removes dangling images, and
  tagged images that are unused, not in `forgejo_runner_keep_images`, and created
  more than `forgejo_runner_prune_max_age_days` (14) ago.
- **Registration:** `.runner` in the state dir, created once. Labels are read from
  `config.yaml` at daemon start, so changing them does not need re-registration.
  Changing the registration token does: delete `.runner` and the runner in Forgejo.

## Build cache

`/srv/ci-cache` is a nested btrfs subvolume of `@/srv`. Snapper's root config
does not cover it, and restic does not back it up. It is rebuildable. No sstate
mirror is configured yet.

## SELinux

The runner container runs with `SecurityLabelDisable=true`. A confined container
cannot connect to the user's Podman API (AVC `connectto`), and relabelling the
socket does not help. Job containers keep their default labels. Decision recorded
in the PR.

## ZeroTier flow rules

`docs/zerotier-flow-rules.md` holds the default rule set, the rules in force on the
network (the ops VM's rules), and the netcup rules entered in Central. The netcup
drop for the ops VM (`10.243.25.185`) must sit above the ops member accepts.

## Verify

```sh
/opt/homebrew/bin/yamllint .
ANSIBLE_CONFIG=<scratch>/ansible.cfg pipx run ansible-lint --profile production
ANSIBLE_CONFIG=<scratch>/ansible.cfg ansible-playbook -i inventories/production/hosts.yml site.yml --syntax-check
ANSIBLE_CONFIG=<scratch>/ansible.cfg molecule test -s default          # shared roles
ANSIBLE_CONFIG=<scratch>/ansible.cfg molecule test -s forgejo_runner   # runner rendering
```

Firewall idempotence is not covered by molecule (firewalld does not run in a
container). It is checked on the live host with `--check --diff --tags firewall`.
