#!/usr/bin/env bash
# Runs INSIDE the booted fixture guest as root (piped over ssh by up.sh).
# Idempotent. Follows inventories/vm/README.md; the UUIDs, paths, names and
# credentials below are the fake fixture values from inventories/vm/group_vars.
set -euxo pipefail

DATA_UUID=00000000-0000-4000-8000-0000000000d1
CONT_UUID=00000000-0000-4000-8000-0000000000c1

by_serial() { echo "/dev/disk/by-id/virtio-$1"; }

zypper --non-interactive --gpg-auto-import-keys ref
zypper --non-interactive in --no-recommends snapper podman sqlite3 btrfsprogs firewalld polkit
# Tools only the VM scenarios need (BD-AC-20 rows 11-13: LVM, MD RAID, LUKS).
zypper --non-interactive in --no-recommends lvm2 mdadm cryptsetup e2fsprogs procps openssl fuse3 hostname rsync
systemctl enable --now firewalld

# --- @data and @containers filesystems (UUIDs pinned by storage_mounts) ----
mkfs_subvol() { # mkfs_subvol <serial> <uuid> <subvol> <mountpoint>
  local dev uuid=$2 sv=$3 mp=$4
  dev="$(readlink -f "$(by_serial "$1")")"
  if ! blkid -t "UUID=$uuid" "$dev" >/dev/null 2>&1; then
    mkfs.btrfs -f -U "$uuid" "$dev"
  fi
  mkdir -p /mnt/top "$mp"
  if ! mountpoint -q /mnt/top; then mount "$dev" /mnt/top; fi
  [[ -d /mnt/top/$sv ]] || btrfs subvolume create "/mnt/top/$sv"
  umount /mnt/top
  grep -q "^UUID=$uuid " /etc/fstab ||
    echo "UUID=$uuid $mp btrfs subvol=/$sv 0 0" >>/etc/fstab
}
mkfs_subvol FIXTUREDATA "$DATA_UUID" @data /mnt/data
mkfs_subvol FIXTURECONTAINERS "$CONT_UUID" @containers /mnt/containers
systemctl daemon-reload
mountpoint -q /mnt/data || mount /mnt/data
mountpoint -q /mnt/containers || mount /mnt/containers

# --- snapper configs data / containers (as the manual production setup) ----
snapper list-configs | grep -qw data || snapper -c data create-config /mnt/data
snapper list-configs | grep -qw containers || snapper -c containers create-config /mnt/containers

# --- Let the fixture user run firewall-cmd / systemctl without sudo ----------
# (the validation commands in the README call `firewall-cmd --state` unprivileged)
install -d /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/50-fixture.rules <<'EOR'
polkit.addRule(function(action, subject) {
  if (subject.user == "fixture") { return polkit.Result.YES; }
});
EOR

# --- smartd refuses to start in a VM (ConditionVirtualization=no); let it run so the
# smartd role's `started` task is idempotent here (it then monitors 0 devices).
install -d /etc/systemd/system/smartd.service.d
printf '[Unit]\nConditionVirtualization=\n' >/etc/systemd/system/smartd.service.d/fixture.conf
systemctl daemon-reload

# --- Fixture SQLite file ----------------------------------------------------
mkdir -p /mnt/containers/forgejo/volume/data
if [[ ! -f /mnt/containers/forgejo/volume/data/forgejo.db ]]; then
  sqlite3 /mnt/containers/forgejo/volume/data/forgejo.db \
    'CREATE TABLE t (id integer); INSERT INTO t VALUES (1);'
fi

# --- Fixture Postgres container (data dir under /mnt/containers) ------------
# aarch64 guest: docker.io/library/postgres:16 is multi-arch.
mkdir -p /mnt/containers/fixture-postgres
if ! podman container exists fixture-postgres; then
  podman run -d --name fixture-postgres --restart=always \
    -e POSTGRES_DB=fixture -e POSTGRES_USER=fixture \
    -e POSTGRES_PASSWORD=fixture-postgres-not-a-secret \
    -v /mnt/containers/fixture-postgres:/var/lib/postgresql/data:Z \
    docker.io/library/postgres:16
fi
podman update --restart=always fixture-postgres >/dev/null
systemctl enable podman-restart.service
# The image runs a temporary server during first-time initdb; retry until the
# real one answers.
for _ in $(seq 1 30); do
  podman exec fixture-postgres psql -U fixture -d fixture \
    -c 'CREATE TABLE IF NOT EXISTS t (id int); INSERT INTO t SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM t);' && break
  sleep 3
done

# --- ac45-allowed Podman network (BD-AC-45) ---------------------------------
podman network exists ac45-allowed || podman network create --subnet 10.89.45.0/24 ac45-allowed

# --- Make ip_forward persistent (Podman published ports; see memory note) ---
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/99-podman-ip-forward.conf
/usr/lib/systemd/systemd-sysctl /etc/sysctl.d/99-podman-ip-forward.conf

# --- Sanity: backup + scratch disks must stay blank --------------------------
for s in FIXTUREBACKUP FIXTURESCRATCH; do
  d="$(readlink -f "$(by_serial $s)")"
  [[ -z "$(lsblk -no FSTYPE "$d" | tr -d '[:space:]')" ]] || { echo "$s not blank" >&2; exit 1; }
done
[[ "$(blockdev --getsize64 "$(by_serial FIXTUREBACKUP)")" == 21474836480 ]]

sync
touch /var/lib/fixture-provisioned
echo PROVISION-OK
