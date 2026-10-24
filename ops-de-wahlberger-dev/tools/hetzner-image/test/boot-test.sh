#!/usr/bin/env bash
# Boot a COPY of a disk produced by build-in-rescue.sh in qemu (SeaBIOS, TCG)
# and probe it over SSH. Test aid only; not part of the Hetzner workflow.
# Usage: boot-test.sh <raw-disk> <private-key> <outdir> [timeout-seconds]
set -euo pipefail
DISK="${1:?raw disk}"; KEY="${2:?private key}"; OUT="${3:?outdir}"; TMO="${4:-1500}"
PORT=2224
mkdir -p "$OUT"
cp -c "$DISK" "$OUT/boot-copy.raw" 2>/dev/null || cp "$DISK" "$OUT/boot-copy.raw"

qemu-system-x86_64 -machine pc -accel tcg,thread=multi -m 2048 -smp 2 \
  -drive "file=$OUT/boot-copy.raw,if=virtio,format=raw" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=n0 \
  -serial "file:$OUT/serial.log" -display none -monitor none \
  -pidfile "$OUT/qemu.pid" -daemonize
echo "qemu started pid $(cat "$OUT/qemu.pid") at $(date +%T)"
trap 'kill "$(cat "$OUT/qemu.pid")" 2>/dev/null || true' EXIT

SSH=(ssh -p "$PORT" -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR
     erikwahlberger@127.0.0.1)

start=$(date +%s)
until "${SSH[@]}" true 2>/dev/null; do
  [ $(( $(date +%s) - start )) -lt "$TMO" ] || { echo "TIMEOUT waiting for ssh"; exit 1; }
  sleep 10
done
echo "ssh answered after $(( $(date +%s) - start )) s"

# sudo comes from bootstrap-sudo.service (zypper over the network): wait for it.
start2=$(date +%s)
until "${SSH[@]}" 'sudo -n true' 2>/dev/null; do
  [ $(( $(date +%s) - start2 )) -lt 900 ] || { echo "sudo never became usable"; break; }
  sleep 10
done
echo "sudo -n true usable after $(( $(date +%s) - start2 )) s (from ssh)"

probe() { printf '\n### %s\n' "$1"; "${SSH[@]}" "$1" 2>&1 || echo "[exit $?]"; }
# shellcheck disable=SC2016
{
  probe 'ls /sys/firmware/efi 2>&1 | head -1; cat /proc/cmdline; sudo dmesg | grep -iE "BIOS|efi:" | head -5'
  probe 'id; hostname; cat /etc/hostname; uptime'
  probe 'sudo -n true && echo SUDO_OK'
  probe 'df -h /'
  probe 'findmnt -no FSTYPE /'
  probe 'findmnt -no SOURCE,OPTIONS /'
  probe 'sudo btrfs filesystem show /'
  probe 'sudo snapper list-configs'
  probe 'sudo snapper list'
  probe 'grep -E "^(PRETTY_NAME|VERSION)=" /etc/os-release'
  probe 'getenforce; sudo sestatus'
  probe 'ls -Z -d /home/erikwahlberger/.ssh /home/erikwahlberger/.ssh/authorized_keys /etc/sudoers.d/erikwahlberger /etc/hostname 2>&1'
  probe 'ip -br a; ip r'
  probe 'nmcli -t -f NAME,TYPE,DEVICE,STATE con show; nmcli -t -f GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY dev show eth0 2>&1 | head'
  probe 'sudo awk -F: '"'"'$2 !~ /^[!*]/ {print $1}'"'"' /etc/shadow; echo "(end of accounts with usable hash)"'
  probe 'systemctl --failed --no-legend'
  probe 'systemctl is-active jeos-firstboot jeos-firstboot-snapshot bootstrap-sudo sshd NetworkManager firewalld; systemctl is-enabled jeos-firstboot sshd'
  probe 'systemctl status jeos-firstboot --no-pager | head -8'
  probe 'cat /etc/machine-id; sudo ls /etc/ssh/ | head; sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
  probe 'sudo sshd -T | grep -iE "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods)"'
  probe 'sudo firewall-cmd --get-active-zones; sudo firewall-cmd --list-services'
  probe 'timedatectl | head -4; localectl status | head -3'
  probe 'sudo cat /etc/sudoers.d/erikwahlberger; command -v sudo; rpm -q sudo'
  probe 'ls -la /.snapshots /etc/selinux/.autorelabel 2>&1 | head; sudo journalctl -b -u bootstrap-sudo --no-pager | tail -5'
  probe 'sudo journalctl -b --no-pager -p warning | tail -30'
  probe 'who -b; sudo journalctl --list-boots --no-pager'
} >"$OUT/probe.txt"
echo "probe written to $OUT/probe.txt"
