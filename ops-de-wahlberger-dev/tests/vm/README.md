# Local VM fixture for the ops VM (T-16; qemu, Apple Silicon)

A disposable openSUSE Tumbleweed **aarch64** guest (qemu + HVF) that rehearses
what OP-03 will measure on the real Hetzner VM: firewalld zone binding by
interface name, host-networked Caddy bound to the ZeroTier address, the bridge
fallback, sshd reload, fail2ban with the nftables banaction, the SELinux label of
the database. It is a **simulator**: aarch64 (the VM is x86_64), qemu user-mode
NAT, a veth pair instead of ZeroTier. It is never ops, nas, cloud or pi, holds
no real credential, and only the throwaway ssh key made by `up.sh` can log in.
Everything is derived from `nas-de-int-wahlberger-dev/tests/vm`.

## Use

```sh
cd ops-de-wahlberger-dev
export FIXTURE_VM_DIR=/dir/with/30GB-free      # default ~/.cache/ops-fixture-vm
nohup tests/vm/up.sh >"$FIXTURE_VM_DIR/up.log" 2>&1 &   # first run 10-20 min (builds the image)
tests/vm/scenarios/s00-apply.sh               # --check --diff, real apply, second apply
tests/vm/scenarios/s10-firewall.sh            # zone binding, reload, reboot, public zone
tests/vm/scenarios/s20-caddy.sh               # listeners, https remove/re-add, A-20, client address
tests/vm/scenarios/s40-ssh-fail2ban.sh        # sshd reload, fail2ban ban, rich rules
tests/vm/scenarios/s50-label-updates.sh       # ls -Z, zypper exit 103, rebootmgr
tests/vm/scenarios/s30-fallback.sh            # LAST: switches to the bridge fallback (changes the guest)
tests/vm/down.sh                              # graceful poweroff   (--destroy: delete disk, --purge: also images)
```

Run one scenario at a time; each appends `id<TAB>status<TAB>text` to
`$FIXTURE_VM_DIR/results/results.tsv` and keeps its logs there. SSH:
`ssh -i $FIXTURE_VM_DIR/id_fixture -p 2223 fixture@127.0.0.1`. Ansible only via
`tests/vm/ans.sh ansible-playbook site.yml --tags ...`: it refuses unless the
inventory resolves to 127.0.0.1:2223 with the fixture key and user, uses
`tests/vm/ansible.cfg` (no vault password file, so `.vault_pass.sh` and `op` are
never called), and takes the production **non-secret** `vars.yml` minus the
fixture overrides from `tests/vm/gen-prod-vars.py`. Production `vault.yml` is
never read; the dummy secrets are plain variables in `inventories/vm`.

## What is provisioned (`provision-guest.sh`)

| Item | Value |
|---|---|
| OS | Tumbleweed aarch64 built by `build-root.sh` (btrfs root, systemd, firewalld, podman); 30 GB root |
| User | `fixture`, key-only ssh, passwordless sudo, polkit-allowed |
| `zt0` | veth pair, `zt0` in the host namespace with `198.51.100.10/24` (stand-in `vm_zt_ip`, RFC 5737 TEST-NET-2, never a real ZeroTier address); peer `ztpeer0` in namespace `ztpeer` = the "ZeroTier client" `198.51.100.20` (+ `203.0.113.5`, outside `caddy_allowed_sources`). Created by `fixture-zt0.service`, started **after** `firewalld.service` |
| Caddy | fixture site `semaphore.fixture.invalid` with `tls internal` (local CA): no ACME, no Cloudflare. `/etc/hosts` also blackholes the ACME, Cloudflare and Resend hosts |
| SELinux | targeted policy, **permissive** (`security=selinux selinux=1 enforcing=0`), tree relabelled once with `setfiles`; the label of `:Z` volumes comes from podman |
| Network | qemu user-mode NAT 192.168.122.0/24; ssh on 127.0.0.1:2223; the fixture's own ssh arrives from 192.168.122.2 |

## Deviations and limits

- The image is built, not downloaded (no Tumbleweed aarch64 cloud image exists); the Leap 16.0 cloud image is only the bootstrap host.
- `selinux=0` of the NAS fixture is replaced by permissive SELinux (this fixture needs `container_file_t`). Enforcing mode is **not** tested.
- `s00-apply.sh` applies `security, firewall, podman, caddy, semaphore` (`--tags`). The OP-02 rehearsal (first `--check --diff`, apply, second apply, check on the applied host) of the **whole** `site.yml` also works: `tests/vm/ans.sh ansible-playbook site.yml --skip-tags cloudflare_dns -e zerotier_network_id=deadbeefdeadbeef [--check --diff]`. `cloudflare_dns` is skipped because it calls the real Cloudflare API (hosts blackholed, no real token); `zerotier_network_id` is a dummy so the fixture never asks to join the real network; `ssh_authorized_keys_user` is `fixture`. `notify_failure` is applied but cannot send (Resend blackholed).
- `vm_zt_iface=zt0` is a veth, not a ZeroTier TAP; real ZeroTier creates its interface when `zerotier-one` joins, later than this fixture does.
- Traffic from the host to its own ZeroTier address uses `lo` and never meets a zone rule. All client tests therefore run inside `ztpeer`.
- Whatever a scenario measures holds for aarch64 Tumbleweed of the build day, not for the x86_64 VM image.
