#!/usr/bin/env bash
# Runs INSIDE the booted fixture guest as root (piped over ssh by up.sh).
# Idempotent. Prepares what the ops roles expect and what the T-16 scenarios
# need; it does NOT apply any role. Everything here is fake or disposable:
# TEST-NET-2 addresses (RFC 5737) stand in for ZeroTier, nothing real.
set -euxo pipefail

ZT_IP=198.51.100.10     # stand-in for vm_zt_ip   (never a real ZeroTier address)
PEER_IP=198.51.100.20   # stand-in ZeroTier client (inside netns ztpeer)
ALT_IP=203.0.113.5      # second client address, outside caddy_allowed_sources

zypper --non-interactive --gpg-auto-import-keys ref
zypper --non-interactive in --no-recommends firewalld polkit podman sqlite3 curl iproute2 openssh-clients \
  procps util-linux sudo tar
systemctl enable --now firewalld

# Record the stock public-zone service list BEFORE any role ran (dhcpv6-client check).
firewall-cmd --permanent --zone=public --list-services >/var/lib/fixture-baseline-public-services.txt

# --- No pre-made /.snapshots ---------------------------------------------------------
# build-root.sh mounts a @/.snapshots subvolume (copied from the NAS fixture); a
# stock Hetzner image has none, and `snapper create-config /` (security role)
# fails when it already exists. Remove it so the role meets a plain btrfs root.
if mountpoint -q /.snapshots; then umount /.snapshots; fi
sed -i '\#[[:space:]]/\.snapshots[[:space:]]#d' /etc/fstab
mkdir -p /mnt/top && mount -o subvolid=5 "$(findmnt -no SOURCE / | sed 's/\[.*//')" /mnt/top
btrfs subvolume delete /mnt/top/@/.snapshots || true
umount /mnt/top

# --- polkit: fixture user may run firewall-cmd unprivileged ---------------------
install -d /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/50-fixture.rules <<'EOR'
polkit.addRule(function(action, subject) {
  if (subject.user == "fixture") { return polkit.Result.YES; }
});
EOR

# --- zt0: a veth pair standing in for the ZeroTier interface ----------------------
# zt0 lives in the host namespace (the interface the firewall binds by name);
# its peer is in namespace ztpeer and acts as a ZeroTier client, so traffic to
# the stand-in ZT IP really arrives on zt0 (traffic from the host to its own
# address would use lo and never meet the zone rules).
install -d /etc/NetworkManager/conf.d
printf '[keyfile]\nunmanaged-devices=interface-name:zt0;interface-name:ztpeer0\n' >/etc/NetworkManager/conf.d/90-fixture-zt0.conf
cat >/usr/local/sbin/fixture-zt0 <<EOS
#!/bin/sh
# fixture-zt0 up|down : create/remove the fake ZeroTier interface zt0 (+ client namespace)
case "\$1" in
  up)
    ip netns add ztpeer
    ip link add zt0 type veth peer name ztpeer0
    ip link set ztpeer0 netns ztpeer
    ip addr add $ZT_IP/24 dev zt0
    ip link set zt0 up
    ip route add $ALT_IP/32 dev zt0
    ip -n ztpeer link set lo up
    ip -n ztpeer addr add $PEER_IP/24 dev ztpeer0
    ip -n ztpeer addr add $ALT_IP/32 dev ztpeer0
    ip -n ztpeer link set ztpeer0 up
    ;;
  down)
    ip link del zt0 2>/dev/null
    ip netns del ztpeer 2>/dev/null
    exit 0
    ;;
esac
EOS
chmod 755 /usr/local/sbin/fixture-zt0
cat >/etc/systemd/system/fixture-zt0.service <<'EOU'
[Unit]
Description=Fixture stand-in for the ZeroTier interface zt0
# After firewalld on purpose: the interface appears after the firewall started,
# which is the harder ordering for the zone binding (ZeroTier behaves like this).
After=firewalld.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/fixture-zt0 up
ExecStop=/usr/local/sbin/fixture-zt0 down
[Install]
WantedBy=multi-user.target
EOU
systemctl daemon-reload
systemctl enable fixture-zt0.service
systemctl is-active fixture-zt0.service || systemctl start fixture-zt0.service

# --- No outbound contact from Caddy (defence in depth) ---------------------------
# The fixture sites use `tls internal`, so Caddy never asks an ACME CA. These
# entries make an accidental ACME/Cloudflare lookup fail locally anyway. (The
# Caddy container is host-networked and so uses the host's /etc/hosts; the
# podman role's base_hosts_file=image would NOT apply there.)
if ! grep -q fixture-blackhole /etc/hosts; then
  cat >>/etc/hosts <<'EOH'
# fixture-blackhole: ACME and Cloudflare must not be reached from this guest
127.0.0.1 acme-v02.api.letsencrypt.org acme-staging-v02.api.letsencrypt.org api.cloudflare.com api.resend.com
EOH
fi

# --- SELinux (permissive, targeted policy) so :Z yields container_file_t -----------
# The chroot-built image is unlabelled and boots with selinux=0 (see README).
zypper --non-interactive in --no-recommends selinux-policy-targeted container-selinux policycoreutils selinux-tools || echo "SELINUX-PACKAGES-FAILED"
install -d /etc/selinux
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=.*/SELINUX=permissive/; s/^SELINUXTYPE=.*/SELINUXTYPE=targeted/' /etc/selinux/config
else
  printf 'SELINUX=permissive\nSELINUXTYPE=targeted\n' >/etc/selinux/config
fi
sed -i 's/selinux=0/security=selinux selinux=1 enforcing=0/' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
if [ -f /etc/selinux/targeted/contexts/files/file_contexts ]; then
  setfiles -F /etc/selinux/targeted/contexts/files/file_contexts / || echo "SETFILES-PARTIAL"
fi

sync
touch /var/lib/fixture-provisioned
echo PROVISION-OK
