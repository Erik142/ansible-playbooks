# VM fixture

Disposable openSUSE Tumbleweed VM that every `[V]` scenario of the backup
feature runs against (`reqs/backup-overview.md`, "VM fixture").

- The VM is its own restic client. It is never nas, cloud or pi: do not
  point this inventory at a production host, and do not run the backup init
  playbook anywhere but here until the VM gate (BD-BR-01) has passed.
- No production secret lives in this directory (BD-FR-156). All passwords in
  `group_vars/all/vars.yml` are fake.
- The commands below are what `tests/vm/` automates for a qemu guest on an
  Apple Silicon Mac (`tests/vm/README.md`); the scenarios T-27 to T-30 were run
  that way (`tests/vm/RESULTS.md`). Use `tests/vm/ans.sh` to run Ansible against
  it: it checks that the target is the local VM, and adds the production
  *non-secret* vars (never `vault.yml`) minus every key this inventory overrides,
  because the roles' argument specs need e.g. `pocket_id_app_url` even when only
  one role is tagged.

## Disks

| Disk | Use | Notes |
|---|---|---|
| root | btrfs root (Tumbleweed default install) | |
| data | btrfs, subvolume `@data` at `/mnt/data` | any size, e.g. 10 GiB |
| containers | btrfs, subvolume `@containers` at `/mnt/containers` | any size, e.g. 10 GiB |
| backup | spare, blank, the backup disk | 20 GiB (`backup_disk_expected_size_bytes: 21474836480`), serial `FIXTUREBACKUP` |
| scratch | extra blank disk, must stay untouched by the init playbook | any size |

Example with libvirt (default network `192.168.122.0/24`, matching
`hosts.yml` and `restic_server_allowed_sources`). Install Tumbleweed with a
btrfs root first, then attach the disks (the `serial=` makes
`/dev/disk/by-id/virtio-FIXTUREBACKUP` appear in the guest):

```sh
for d in data containers scratch; do qemu-img create -f qcow2 /var/lib/libvirt/images/fixture-$d.qcow2 10G; done
qemu-img create -f qcow2 /var/lib/libvirt/images/fixture-backup.qcow2 20G
virsh attach-disk <vm> /var/lib/libvirt/images/fixture-data.qcow2       vdb --subdriver qcow2 --serial FIXTUREDATA       --persistent
virsh attach-disk <vm> /var/lib/libvirt/images/fixture-containers.qcow2 vdc --subdriver qcow2 --serial FIXTURECONTAINERS --persistent
virsh attach-disk <vm> /var/lib/libvirt/images/fixture-backup.qcow2     vdd --subdriver qcow2 --serial FIXTUREBACKUP     --persistent
virsh attach-disk <vm> /var/lib/libvirt/images/fixture-scratch.qcow2    vde --subdriver qcow2 --serial FIXTURESCRATCH    --persistent
```

In the guest, confirm the backup disk path and size:

```sh
ls -l /dev/disk/by-id/virtio-FIXTUREBACKUP
blockdev --getsize64 /dev/disk/by-id/virtio-FIXTUREBACKUP   # 21474836480
```

Do not partition or format the backup and scratch disks. The init playbook
does that to the backup disk; the scratch disk exists to prove it is not
touched.

## `@data` and `@containers`

`storage_mounts` in `group_vars/all/vars.yml` pins the filesystem UUIDs, so
create the filesystems with those UUIDs. Device names (`vdb`, `vdc`) are
those of the example above.

```sh
mkfs.btrfs -f -U 00000000-0000-4000-8000-0000000000d1 /dev/vdb   # data
mkfs.btrfs -f -U 00000000-0000-4000-8000-0000000000c1 /dev/vdc   # containers

mkdir -p /mnt/top
mount /dev/vdb /mnt/top && btrfs subvolume create /mnt/top/@data && umount /mnt/top
mount /dev/vdc /mnt/top && btrfs subvolume create /mnt/top/@containers && umount /mnt/top

mkdir -p /mnt/data /mnt/containers
cat >> /etc/fstab <<'FSTAB'
UUID=00000000-0000-4000-8000-0000000000d1 /mnt/data       btrfs subvol=/@data       0 0
UUID=00000000-0000-4000-8000-0000000000c1 /mnt/containers btrfs subvol=/@containers 0 0
FSTAB
systemctl daemon-reload
mount /mnt/data && mount /mnt/containers
findmnt /mnt/data /mnt/containers
```

## snapper configs `data` and `containers`

Same as the manual production setup (see `roles/snapper/README.md`):

```sh
zypper --non-interactive install snapper
snapper -c data create-config /mnt/data
snapper -c containers create-config /mnt/containers
snapper list-configs
```

## Fixture Postgres container

Matches `db_dump_postgres` (container `fixture-postgres`, database
`fixture`, user `fixture`, password `fixture-postgres-not-a-secret`). The
data directory lives under `/mnt/containers`.

```sh
zypper --non-interactive install podman
mkdir -p /mnt/containers/fixture-postgres
podman run -d --name fixture-postgres \
  -e POSTGRES_DB=fixture -e POSTGRES_USER=fixture \
  -e POSTGRES_PASSWORD=fixture-postgres-not-a-secret \
  -v /mnt/containers/fixture-postgres:/var/lib/postgresql/data:Z \
  docker.io/library/postgres:16
podman exec fixture-postgres psql -U fixture -d fixture \
  -c 'CREATE TABLE IF NOT EXISTS t (id int); INSERT INTO t VALUES (1);'
```

The image tag is a choice of this README, not read from the roles. Verified:
`db_dump` only needs `podman exec <container> pg_dump` to work, which it does
with `postgres:16` (and the container must be running).

## Fixture SQLite file

Path from `db_dump_forgejo_db_path`:

```sh
zypper --non-interactive install sqlite3
mkdir -p /mnt/containers/forgejo/volume/data
sqlite3 /mnt/containers/forgejo/volume/data/forgejo.db \
  'CREATE TABLE t (id integer); INSERT INTO t VALUES (1);'
```

## `ac45-allowed` Podman network

For BD-AC-45. The subnet must equal the second entry of
`restic_server_allowed_sources` (`10.89.45.0/24`):

```sh
podman network create --subnet 10.89.45.0/24 ac45-allowed
podman network inspect ac45-allowed | grep -i subnet
```

If you pick another subnet, change it in `group_vars/all/vars.yml` too.

## Point the inventory at the VM

Edit `ansible_host` in `hosts.yml` (one host, `nas-vm-fixture`, group
`nas`), or override per run. The VM user is `fixture` (`ansible_user`) and
needs SSH key login and passwordless sudo.

```sh
cd nas-de-int-wahlberger-dev
ansible-playbook -i inventories/vm --list-hosts site.yml
ansible-playbook -i inventories/vm -e ansible_host=<vm-ip> site.yml --check
```

## Run order of the validation tasks

Take a VM snapshot after the preparation above and before T-27, so a reset
is cheap.

1. T-27: init, mount and scrub (BD-AC-20 to 24, 26, 56).
2. T-28: btrbk and db_dump (BD-AC-29 to 37).
3. T-29: restic-server, firewall, maintenance (BD-AC-39 to 52, 54).
4. T-30: flags, guards, units, idempotency, reboot (BD-AC-25, 27, 28, 38,
   55, 57 to 60).

Details: `PLAN-backup.md`, tasks T-27 to T-30.
