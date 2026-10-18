# garage

Garage S3 object store as a rootful Podman Quadlet, on two dedicated btrfs
subvolumes (data on `/mnt/data`, metadata on `/mnt/containers`). Spec:
`reqs/garage-sstate.md`; plan: `PLAN-garage.md`.

## Scope

The role sets up the Garage service only: store, configuration, secrets,
container, Caddy route, backup sources. It creates no layout, bucket, key,
grant, quota, website flag or lifecycle rule. Those are user steps with the
Garage and S3 CLIs (below). Until the user applies a layout (step 1), Garage runs
and `garage status` exits 0, but it stores and serves no objects (GS-BR-16).

Commands below are tagged: "VM" = run in `tests/vm/scenarios/garage-test-setup.sh`
(layout, buckets, website, key, grant, put-object); "spike" = observed in
`tests/spikes/garage-v2.4.1-cli-config.md` on a throwaway node; "unverified" =
in neither. The Garage CLI runs in the container: prefix every `garage ...` with
`podman exec garage /garage ...` (the form the VM script uses).

## Variables

All inputs are in `defaults/main.yml` and declared in `meta/argument_specs.yml`
(the spec's Inputs table is normative). `garage_enabled` defaults to `false`;
`site.yml` runs the role after `caddy` and before `btrbk` only when it is true.
Enabling needs `backup_disk_enabled: true` (the role fails before any change
naming both flags).

## Runtime-fact contract

`garage_uid` and `garage_gid` are not inputs. `tasks/storage.yml` sets them with
`getent` for `garage_user`; the Quadlet (`templates/garage.container.j2`) and
`tasks/secrets.yml` consume them. The render check supplies fixture values.

## What this role does not do

- It does not publish any Garage port (no `PublishPort=`); Caddy reaches it over
  `caddy.network`.
- It does not create DNS records (`cloudflare_dns` does, from `caddy_sites`).
- It does not generate or rotate keys; Vault is the source of truth.
- It does not remove Garage when `garage_enabled` is set back to `false`.
- It does not touch the btrbk, snapper or Caddy configuration.

## Consumer settings (GS-FR-34)

- Endpoint `https://s3.de.int.wahlberger.dev`, path-style addressing, region `garage`.
  (The HTTPS endpoint through Caddy is covered by `tests/spikes/garage-caddy-routing.md`
  and the VM scenarios, not by the commands in this README.)
- Once a bucket has website access (step 3), BitBake reads it anonymously:

  ```
  SSTATE_MIRRORS ?= "file://.* https://s3.de.int.wahlberger.dev/<bucket>/PATH"
  ```

  with `<bucket>` = `sstate` as the example.

## One-node layout (GS-FR-139)

Run once on the NAS after the first role run.

```
podman exec garage /garage status                                  # VM; node ID = first column of the HEALTHY NODES row (16 hex chars)
podman exec garage /garage layout assign -z <zone> -c <capacity> <node_id>   # VM (VM uses -z dc1 -c 10GiB)
podman exec garage /garage layout apply --version 1                # VM
podman exec garage /garage status                                  # VM; the node must no longer show NO ROLE ASSIGNED
```

- Capacity is a placement weight, not a limit (behaviour at a full store is
  unverified, spike GS-A-09). Quotas are the limit.
- `500GB` is decimal (465.7 GiB); `500GiB` is binary. Choose the unit explicitly (spike).
- Do not run `layout apply --version <n>` with nothing staged: it still succeeds
  and bumps the version (spike). Check `garage layout show` first (VM script does).

## Buckets, keys, grants, quota, website, lifecycle (GS-FR-140)

All user-owned; nothing here is managed or reverted by Ansible.

```
# 1. bucket                                                         (VM)
podman exec garage /garage bucket create sstate
# 2. key (prints the key ID; read the secret later with --show-secret)   (VM)
podman exec garage /garage key create ci-upload
podman exec garage /garage key info --show-secret ci-upload   # prints to the terminal: do not paste it into a command line
# 3. grant read/write                                               (VM)
podman exec garage /garage bucket allow sstate --key ci-upload --read --write
# 4. website access (default index document index.html)            (VM)
podman exec garage /garage bucket website --allow sstate
#    revoke: bucket website --deny sstate                           (VM)
# 5. quota: recommendation for sstate is 500 GiB; a user choice, not enforced by any gate (GS-NFR-02)   (spike)
podman exec garage /garage bucket set-quotas sstate --max-size 500GiB
#    verify: bucket info sstate shows "maximum size: 536.9 GB (500.0 GiB)"; "none" removes it   (spike)
```

Lifecycle is an S3 API call, not a `garage` subcommand. Spike-verified form
(aws-cli 2.38.1, container on the same network as the node, endpoint
`http://garage:3900`; the VM script uses the same container form for `put-object`):

Never put the secret on a command line (visible in `ps` and shell history).
Read it into the shell without echo and let podman inherit it by name:

```
read -rs AWS_SECRET_ACCESS_KEY && export AWS_SECRET_ACCESS_KEY
podman run --rm --network systemd-caddy -v <dir>:/w:Z \
  -e AWS_ACCESS_KEY_ID=<GK...> -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=garage \
  docker.io/amazon/aws-cli:2.38.1 --endpoint-url http://garage:3900 s3api \
  put-bucket-lifecycle-configuration --bucket sstate --lifecycle-configuration file:///w/lc.json   # spike
unset AWS_SECRET_ACCESS_KEY
```

Alternative: a `--env-file` with mode 0600 (`umask 077`), deleted after the run.

`lc.json` (spike): `{"Rules":[{"ID":"expire-90d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":90}}]}`.
Read back with `s3api get-bucket-lifecycle-configuration --bucket sstate` (an
unset rule gives `NoSuchLifecycleConfiguration`, exit 254); remove with
`s3api delete-bucket-lifecycle --bucket sstate` (spike). Objects actually
expiring after 90 days is unverified (spike, not waited for).

Limits:

- Garage lifecycle is partial (GS-F-21, from Garage's documentation, not checked
  against this repository): `Expiration` and `AbortIncompleteMultipartUpload`
  work; `ExpiredObjectDeleteMarker` is not supported; a `Prefix` must be inside `Filter`.
- Lifecycle authorization follows `read`/`write`, not `owner` (spike): Put and
  Delete need `write`, Get needs `read`. A key with only `owner` gets 403 on
  everything. Any read+write key can change the lifecycle.
- Using the HTTPS endpoint from a client (not the in-network `http://garage:3900`) is unverified here.

## Restore (GS-FR-77, GS-BR-11)

Use the `garage` and `garage-meta` snapshots of the same btrbk run, the same
`<ts>`. Never combine snapshots of different runs. A plain
`btrfs subvolume snapshot` from the backup disk fails with "Invalid cross-device
link", so send/receive into a staging directory first, then take a writable
snapshot. Paths as in the spec; the VM drill (`tests/vm/scenarios/garage-v3-restore.sh`,
helper `restore_stop_replace` in `garage-v3-guest.sh`) used the same sequence
with staging dirs `/mnt/data/.restore-stage` and `/mnt/containers/.restore-stage`
and `.pre-restore` suffixes, and received before stopping the service.

```
systemctl stop garage.service
mkdir -p /mnt/data/.garage-restore /mnt/containers/.garage-restore-meta
btrfs send /mnt/backup/btrbk/garage/garage.<ts> | btrfs receive /mnt/data/.garage-restore/
btrfs send /mnt/backup/btrbk/garage-meta/garage-meta.<ts> | btrfs receive /mnt/containers/.garage-restore-meta/
mv /mnt/data/garage /mnt/data/garage.pre-restore-<date>
mv /mnt/containers/garage/meta /mnt/containers/garage/meta.pre-restore-<date>
btrfs subvolume snapshot /mnt/data/.garage-restore/garage.<ts> /mnt/data/garage
btrfs subvolume snapshot /mnt/containers/.garage-restore-meta/garage-meta.<ts> /mnt/containers/garage/meta
ansible-playbook site.yml --tags garage      # re-render the secrets from Vault (not in any backup)
systemctl start garage.service
podman exec garage /garage status
podman exec garage /garage block list-errors   # healthy: only the header "Hash  RC  Errors  Last error  Next try"
# after the check:
btrfs subvolume delete <staging and .pre-restore-<date> subvolumes>
```

- `mkdir`, `mv` and the `-<date>` suffix are as in the spec/VM helper; the
  `.garage-restore*` directory names and the order stop-then-receive follow the
  spec (the VM used other directory names). Not run verbatim on the VM.
- If btrbk finds no common parent for the restored subvolumes, its next run
  sends a full copy of each Garage source; the `disk_space` alert covers the space.
- Skew: the two snapshots are taken seconds apart, not atomically (accepted risk
  GS-R-01). The VM drill read objects written before the metadata snapshot and
  got 404 for objects written after it.

## Image user (GS-FR-84)

`docker.io/dxflrs/garage:v2.4.1` has no `id` binary (`exec: "id": executable
file not found`). `podman image inspect --format '{{.Config.User}}'
docker.io/dxflrs/garage:v2.4.1` prints an empty string (checked with
`docker image inspect` in the spike): the image's built-in user is root (uid 0).
The Quadlet sets a non-root `User=` from `garage_uid`/`garage_gid`.

## Restart handlers (GS-FR-142)

The "Restart garage" handler and the shared "Restart the container service"
handler (`roles/container`, used by every container service) do nothing in
check mode and do not fail when the unit is not installed yet.

## Backup-disk size observation (GS-NFR-03, observe only)

No gate or alert depends on these values. T-26 fills them after enabling.

| Day | Backup-disk used | Date measured |
|-----|------------------|---------------|
| 30  |                  |               |
| 120 |                  |               |
