## Feature: Provide a Garage S3 store on the NAS (first bucket: Yocto sstate)
status:            ready
priority:          should
version:           1.2
quality-pillars:   4,4,3,4,4,5,4,5
quality-reviewed:  2026-10-18

Open Questions are empty (all resolved, see "Resolved questions"); accepted risks are GS-R-01 to GS-R-03. Final requirements-auditor verdict READY, 0 blocking (2026-10-17); 0.7 is an editorial pass on that verdict, 0.8 records the spike T-03 result (`tests/spikes/garage-caddy-routing.md`), 0.9 three implementation points from task T-01, 1.0 the secret-handling pattern for assert tasks (T-07), 1.1 Erik's scope change: Ansible sets up only the Garage service; everything the Garage or S3 CLI can do is left to the user (GS-CC-40), 1.2 a cleanup after the re-audit of 1.1 (GS-CC-41). IDs carry the prefix `GS-`. IDs marked "[Deleted 0.x]" are kept and never reused. "[Amended 0.x]" marks an entry whose text changed in that version, "[New 0.x]" an entry added in it; "split from" names the FR a new ID was cut out of. The changes from 0.1 to 1.1 are listed under "Contract changes from 0.1" to "... from 1.1", and in the change log at the end of this file.

### Problem Statement

The Yocto / meta-sluss build hosts and the netcup CI runner share no sstate cache, so each one rebuilds artefacts that another host has already built. Erik wants one S3-compatible object store on the NAS that serves several buckets for different uses; the first planned use is a shared sstate cache that BitBake reads anonymously through `SSTATE_MIRRORS` at `https://s3.de.int.wahlberger.dev/<bucket>/PATH`. [Amended 1.1] Ansible sets up only the Garage service so that a user can start to use it: the store on btrfs (object data on the HDD, metadata on the NVMe), configuration, secrets, the container, the Caddy routes, no published ports, the btrbk backup and the restore procedure. Everything the Garage or S3 CLI can do (node layout, buckets, access keys, grants, quotas, website access, lifecycle rules) is done by the user and documented in the role README (decision 2026-10-18, GS-CC-40). After a role run Garage is running but has no layout, so it stores no objects until the user runs the documented layout steps (GS-BR-16). The store is reachable only from the home LAN and ZeroTier.

#### Constraints

- [Amended 0.3] Object data lives on the main data HDD in the btrfs subvolume `/mnt/data/garage` (directory `data/`), outside `/mnt/data/samba/` (Samba shares only `samba_share_path` = `/mnt/data/samba/Delat`).
- [New 0.3] Garage metadata lives on the NVMe in the btrfs subvolume `/mnt/containers/garage/meta` (decision B, GS-Q-11 closed).
- [Amended 0.3] `/mnt/data` and `/mnt/containers` must be btrfs, and both Garage paths must be their own subvolumes. If either mount is not btrfs, nothing is changed (hard stop).
- [New 0.3] One HTTPS host serves the whole store: `garage_s3_domain` = `s3.de.int.wahlberger.dev`. Buckets are path segments, never hostnames (decision A, GS-Q-02 closed).
- No public exposure: only the LAN (10.10.0.0/16) and ZeroTier (10.243.0.0/16) can reach the NAS. The NAS has no public interface.
- Rootful Podman Quadlets through the `container` role. Image tags are pinned and never `latest`; Renovate updates them.
- FQCN, idempotent, firewalld (not ufw), ansible-core >= 2.15 (the control host runs 2.16). Role conventions from `CLAUDE.md` apply (role-prefixed variables, `meta/argument_specs.yml`, README, no `meta/main.yml` dependencies).
- Secrets come only from Ansible Vault. They are never printed, never logged and never written to a rendered file in the repository.
- Garage single node, `dxflrs/garage:v2.4.1` (tag checked on Docker Hub in 0.1). The configuration keys were checked in 0.1 against https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/ (exceptions in GS-A-01).

#### Repo facts (checked 2026-10-17)

- GS-F-01: `/mnt/data` is the btrfs subvolume `/@data` (UUID `95652338-…`), mounted by the `storage` role. btrbk (`btrbk_sources`: `data`, `containers`) and snapper snapshot it.
- GS-F-02: The NAS has no restic client job (`restic_backup_decommission` removed it). No restic exclusion list exists.
- GS-F-03: A btrfs snapshot does not include nested subvolumes. A snapshot of `/mnt/data` therefore holds an empty `garage/` directory (verified in `tests/spikes/A-07-btrbk-snapshot-dir.md`).
- GS-F-04: firewalld zone rich rules do not filter a Podman-published port. The port is DNATed and takes the FORWARD path (`tests/spikes/A-05-firewall-podman.md`, `roles/firewall/README.md` "Podman caveat"). The published `:3900` plus rich rule in 0.1 (GS-FR-13, GS-FR-40) would not have restricted sources.
- GS-F-05: The `cloudflare_dns` role writes, in the public zone `wahlberger.dev`, the A record `nas.de.int.wahlberger.dev` = `ansible_facts.default_ipv4.address` (the LAN address). It also writes one CNAME per `caddy_sites` host pointing at that A record, all with `proxied: false`. 0.1 said "no public A record is created"; that was wrong.
- GS-F-06 [Amended 0.3]: The `btrbk` role runs `findmnt --mountpoint <path>` for every source and fails before any change unless the path is a mount point. `/mnt/data/garage` and `/mnt/containers/garage/meta` (nested subvolumes) are not mount points, so the role fails today with these sources. The first assert in `roles/btrbk/tasks/main.yml` rejects only snapshot dirs at or below `samba_data_dir`. 0.3 places the Garage snapshots in per-source sibling directories (GS-FR-72, GS-FR-90), so no `.btrbk` directory exists inside a Garage subvolume.
- GS-F-07: The `btrbk` role creates `<source>/.btrbk` (`root:root 0700`) and `<btrbk_target_dir>/<name>` with `ansible.builtin.file`. That module also creates missing parent directories.
- GS-F-08 [Amended 0.3]: Disks: the main data HDD behind `/mnt/data` is a 6 TB Toshiba MG04ACA600EY, and the backup disk is 6 TB. `roles/smartd/README.md` also lists a root SSD (Intel 240 GB) and an NVMe (Samsung 970 EVO Plus 2 TB). 0.2 did not record which mount uses the NVMe; GS-F-15 answers it.
- GS-F-09: NAS LAN address `10.10.0.100` (`ops-de-wahlberger-dev/docs/zerotier-flow-rules.md`). ZeroTier-to-LAN traffic is not NATed. Only the ops VM's ZeroTier traffic is filtered. All other members have Central's accept-all behaviour.
- GS-F-10: The Renovate custom manager in the top-level `renovate.json` matches `<name>_image: registry/repo:tag` lines in `roles/*/defaults/main.yml`.
- GS-F-11: `disk_space` checks `/`, `/mnt/data`, `/mnt/containers` and `/mnt/backup/btrbk` every 15 min. It emails when usage crosses `disk_space_threshold_percent` (85).
- GS-F-12: Caddy sets no request-body limit and no upstream timeout by default (`vars.yml`, Forgejo comment). Every site on `caddy.network` reaches its upstream by container name.
- GS-F-13 [New 0.3]: The NAS SSH host key matches the existing `known_hosts` entry for `nas.de.int.wahlberger.dev` (ED25519, `SHA256:uTBodckkm18YMLjOM356EYKJmoexQzSfYH+A8ePL80w`), checked by Erik on 2026-10-17 (GS-Q-01, GS-P-02).
- GS-F-14 [New 0.3]: `/mnt/data` is btrfs, subvolume `@data` on `/dev/sdb1`, an HDD: 5.5T, 76G used (Erik's check on the NAS, 2026-10-17).
- GS-F-15 [New 0.3]: `/mnt/containers` is btrfs on `/dev/nvme0n1p1`, the NVMe: 1.8T, 3G used; `findmnt` reports `btrfs` (same check). It is a different filesystem from `/mnt/data` (`storage_mounts` lists different UUIDs).
- GS-F-16 [New 0.3]: The root SSD `sda` is 224G (same check).
- GS-F-17 [New 0.3]: The netcup CI host's ZeroTier member IP is `10.243.73.1` (`vm_zt_ip` in `netcup-ci-wahlberger-dev/inventories/production/group_vars/all/vars.yml:25`).
- GS-F-18 [New 0.3]: `roles/caddy/templates/Caddyfile.j2` writes `reverse_proxy {{ site.upstream }}` as the first line of every site block, then the optional `extra` text. `roles/caddy/meta/argument_specs.yml` declares `upstream` required. The role has no form for a site with two routes to different upstreams; the approved `body` key adds one (GS-FR-95, GS-Q-13 closed).
- GS-F-19 [New 0.3]: `roles/btrbk/templates/btrbk.conf.j2` writes `volume <path>`, `snapshot_dir {{ btrbk_snapshot_dirname }}` (role-wide, relative to the volume) and `subvolume .` for every source. `roles/btrbk/tasks/config.yml` creates `<path>/<btrbk_snapshot_dirname>`. No per-source snapshot directory exists today.
- GS-F-20 [New 0.3] (observation, out of scope): `lsblk` shows `/dev/sdb1` also mounted at `/mnt/data/samba/Delat/Bilder/immich/library`, inside the Samba share. Recorded for Erik to review; this feature does not change it.
- GS-F-22 [New 0.6]: On the NAS, `findmnt -no FSROOT -T /var/lib` reports `/@/var`, a separate btrfs subvolume from `/` (which is `/@/.snapshots/1/snapshot` under the snapper config `root`). Root snapper snapshots therefore do not cover `/var/lib` (Erik's check, 2026-10-17; GS-Q-16).
- GS-F-21 [New 0.4] (Erik's input 2026-10-17, from Garage's S3 compatibility documentation; not checked against the repository): Garage's lifecycle support is partial. `Expiration` and `AbortIncompleteMultipartUpload` rules work; `ExpiredObjectDeleteMarker` is not supported; a `Prefix` must be inside `Filter`. The lifecycle calls are S3 API operations (`GetBucketLifecycleConfiguration`, `PutBucketLifecycleConfiguration`, `DeleteBucketLifecycle`).

#### Terms

- **data subvolume** [New 0.3]: the btrfs subvolume `garage_store_path` (`/mnt/data/garage`) on the HDD; it holds `data/`.
- **metadata subvolume** [New 0.3]: the btrfs subvolume `garage_meta_path` (`/mnt/containers/garage/meta`) on the NVMe; it is Garage's `metadata_dir`.
- **store** [Amended 0.3]: the data subvolume and the metadata subvolume together (one subvolume in 0.2).
- **Garage sources** [New 0.3]: the btrbk sources `garage` (data subvolume) and `garage-meta` (metadata subvolume).
- **Garage CLI**: `podman exec garage /garage <subcommand>`.
- **website bucket** [Amended 1.1]: a bucket the user has enabled for website access (`garage bucket website --allow <bucket>`). Ansible enables none.
- **S3 host** [New 0.3, replaces "web host" and "API host" of 0.2]: `https://<garage_s3_domain>` (production `https://s3.de.int.wahlberger.dev`), the only HTTPS host of the store, served by one `caddy_sites` entry.
- **web route** [New 0.3]: the S3 host's route for unsigned `GET` and `HEAD` requests to `/<bucket>/<key>`. Caddy forwards them to Garage's s3_web endpoint (`garage:3902`) with the bucket segment removed from the path and `Host: <bucket>` (GS-FR-93).
- **API route** [New 0.3]: the S3 host's route for every other request. Caddy forwards it to Garage's S3 API (`garage:3900`) with path, query and `Host` unchanged (GS-FR-94). Garage accepts only signed requests there (W1).
- **user-owned state** [New 1.1]: the node layout, buckets, access keys, grants, quotas, website flags and lifecycle rules. The user creates and changes them with the Garage CLI or an S3 client; the role never touches them (GS-BR-15).
- **test setup** [New 1.1] [V]: the step that, before the [V] scenarios that need data, runs the README layout steps and creates with the Garage CLI the buckets `sstate` (website access) and `private-test` (no website access), the key `test-rw` with read and write on both, and the object `selftest/up` (GS-FR-68). It stands in for the user.
- **route test Caddy** [New 0.3] [V]: a disposable container `caddy-route-test` from `caddy_image` on `caddy.network`. Its Caddyfile consists of `http://:8080 { <rendered body of the S3 host site> }`. It exists only during the test and reaches the same Garage. It is used because Caddy on [V] has no real certificate.
- **[S] / [V] / [H]**: where a scenario runs. [S] means static, in the repository. [V] means on the VM fixture (`inventories/vm`, two btrfs disks for `/mnt/data` and `/mnt/containers`). [H] means on production. On [V], Caddy has no real certificate (fake Cloudflare token), so [V] scenarios reach Garage directly or through the route test Caddy.

#### Contract changes from 0.1 (implementers and tests must follow)

Note [New 1.2]: GS-CC-01 to GS-CC-39 are the history of earlier versions. Entries tagged "Superseded by GS-CC-40" no longer describe the contract; entries tagged "Historical" cite IDs that 1.1 deleted. Where any of them conflicts with GS-CC-40 or the current FRs, the current FRs win.

- GS-CC-01: Backup: the store is now **backed up** through btrbk (it was excluded in 0.1). GS-BR-01 is deleted, GS-BR-03 is rewritten, and GS-FR-70 to GS-FR-77 are new. [Amended 0.3: two sources, GS-CC-18.]
- GS-CC-02 [Amended 0.3]: Mirror URL: `https://<host>/sstate/PATH` with a Host rewrite (0.1) becomes `https://<garage_s3_domain>/<bucket>/PATH`, in production `https://s3.de.int.wahlberger.dev/sstate/PATH`. On the web route Caddy removes the bucket segment from the path and sets `Host` to the bucket name. (0.2 had `https://sstate.<garage_s3_domain>/PATH`; replaced by GS-CC-13.)
- GS-CC-03: Write endpoint: `<LAN IP>:3900` published with a rich rule becomes `https://<garage_s3_domain>` through Caddy, with no published port (W1, GS-Q-03 closed). GS-FR-40 is deleted, and GS-AC-11 is rewritten.
- GS-CC-04: RPC: `<NAS LAN IP>:3901` becomes `127.0.0.1:3901` inside the container (bind and public address).
- GS-CC-05: s3_web: "bound to localhost" becomes `0.0.0.0:3902` inside the container's network namespace, not published.
- GS-CC-06 [Amended 0.3]: The data subvolume root changes from owner Garage UID `0700` to `root:root 0700`. `data/` stays `0700`, owned by the Garage account. The metadata is the separate subvolume `/mnt/containers/garage/meta`, `0700`, owned by the Garage account (GS-CC-17).
- GS-CC-07 [Amended 0.5]: Secret files: "root-only 0600 under `/etc/garage/`" (0.1) becomes `garage_user`-owned `0400` files in `garage_secrets_dir` (default `/var/lib/garage/secrets`, GS-Q-16 closed), outside every btrbk and snapper source (GS-CC-31, GS-CC-33). 0.2 to 0.4 had `<garage_config_dir>/secrets/`.
- GS-CC-08 [Superseded by GS-CC-40 in 1.1]: Keys: Vault is the source. Keys are imported into Garage, never generated by Garage and copied to Vault (GS-BR-06).
- GS-CC-09: The image reference becomes fully qualified (`docker.io/dxflrs/garage:v2.4.1`). Renovate detection uses the existing custom manager instead of a `# renovate:` comment.
- GS-CC-10 [Historical: cites IDs deleted in 1.1, see GS-CC-40]: New inputs, new error cases (GS-E-01 to GS-E-21) and new wiring (GS-FR-60 to GS-FR-67).
- GS-CC-11 [Amended 0.3]: Cross-feature changes:
  - the `btrbk` role: mount guard and refusal (GS-FR-75, GS-FR-76) and per-source `snapshot_dir` (GS-FR-90 to GS-FR-92), approved by Erik on 2026-10-17 (GS-CC-20). [backup-btrbk-and-db-dump.md](backup-btrbk-and-db-dump.md) owns that role and needs its own update;
  - the `caddy` role: optional `caddy_sites[].body` (GS-FR-95 to GS-FR-97), approved by Erik on 2026-10-17 (GS-CC-15, GS-CC-25);
  - production `vars.yml`, each only while `garage_enabled` is true: `caddy_sites` (+1 entry with `body`), `btrbk_sources` (+2) and `backup_disk_freshness_checks` (+2).
- GS-CC-12: ZeroTier: GS-FR-43 becomes the external precondition GS-P-01. Under W1 the netcup member (`10.243.73.1`, GS-F-17) needs only `:443` (0.1: `:3900` and `:443`).

#### Contract changes from 0.2 (in 0.3; implementers and tests must follow)

- GS-CC-13 [New 0.3]: Addressing (decision A): one host `garage_s3_domain` = `s3.de.int.wahlberger.dev`; buckets are path segments. No per-bucket DNS record and no per-bucket `caddy_sites` entry. GS-FR-31, GS-FR-32, GS-FR-34, GS-FR-35, GS-FR-36, GS-FR-37 and GS-FR-50 are rewritten; GS-AC-10, GS-AC-30 to GS-AC-34 and GS-AC-48 are rewritten.
- GS-CC-14 [New 0.3]: Caddy routing: the S3 host site has two routes (GS-FR-93 web route to `garage:3902`, GS-FR-94 API route to `garage:3900`). This replaces 0.2's "no `extra` directives, `Host` passed through unchanged" for website reads. Presigned requests (query parameter `X-Amz-Signature`, no `Authorization` header) count as signed and take the API route.
- GS-CC-15 [New 0.3] [Amended 0.4]: `caddy` role contract change, approved by Erik on 2026-10-17 (GS-Q-13 closed): new optional key `caddy_sites[].body`; `upstream` becomes optional when `body` is set (GS-FR-95 to GS-FR-97).
- GS-CC-16 [New 0.3] [Amended 0.8]: Garage `[s3_web] root_domain`: `".<garage_s3_domain>"` (0.2) became not set in 0.3; spike T-03 reversed this: it is required and set to `<garage_s3_domain>` without a leading dot (GS-CC-35).
- GS-CC-17 [New 0.3]: Metadata on the NVMe (decision B): `metadata_dir` `/mnt/data/garage/meta` becomes `/mnt/containers/garage/meta`, its own nested subvolume. The data subvolume holds only `data/`. New inputs `garage_meta_mount_path` and `garage_meta_path`. GS-FR-01 to GS-FR-04, GS-FR-06, GS-FR-07, GS-FR-09 and GS-FR-73 are amended; GS-E-01 and GS-E-02 cover both paths.
- GS-CC-18 [New 0.3]: Backup: two btrbk sources, `garage` and `garage-meta`, snapshotted seconds apart in one btrbk run, not atomically (accepted risk GS-R-01). GS-FR-08, GS-FR-71, GS-FR-74 and GS-FR-77 are amended; GS-FR-78, GS-FR-79, GS-BR-11, GS-E-26 and GS-E-27 are new. The Garage freshness checks exist only while `garage_enabled` is true.
- GS-CC-19 [New 0.3]: Snapshot location (decision C): `/mnt/data/garage/.btrbk` becomes the siblings `/mnt/data/.btrbk-garage` (source `garage`) and `/mnt/containers/.btrbk-garage-meta` (source `garage-meta`). GS-FR-72 is rewritten. The 0.2 GS-AC-20 check "no snapshot inside a snapshot" is removed and replaced by sibling checks.
- GS-CC-20 [New 0.3]: `btrbk` role contract changes, approved by Erik on 2026-10-17 (decision D, GS-Q-05 closed): optional per-source keys `mount_path` (GS-FR-75, GS-FR-76) and `snapshot_dir` (GS-FR-90 to GS-FR-92). The Garage sources are declared only in production `vars.yml` and only while `garage_enabled` is true (GS-FR-70, GS-FR-78); `roles/btrbk/defaults/main.yml` is unchanged.
- GS-CC-21 [New 0.3]: Removed inputs `garage_s3_publish_ip` and `garage_allowed_sources` (only used by W2/W3; W1 is final).
- GS-CC-22 [New 0.3] [Superseded by GS-CC-40 in 1.1]: Sizes fixed (decision E): `sstate` quota 500 GiB; 1 TiB on the backup disk for both Garage targets together; shared role-wide retention. `garage_layout_capacity` stays a required input without a default.
- GS-CC-23 [New 0.3]: GS-BR-05 rewritten: only the hostname `garage_s3_domain` is public; bucket names appear in request paths only. GS-AC-33 checks that no record contains a bucket name and that the certificate names one host.
- GS-CC-24 [New 0.3]: GS-FR-61 (enable precondition) is amended; new fixture buckets (GS-FR-68); the Garage `caddy_sites` entry exists only while `garage_enabled` is true (GS-FR-32).

#### Contract changes from 0.3 (in 0.4; implementers and tests must follow)

- GS-CC-25 [New 0.4]: The `caddy` role change (`caddy_sites[].body`, GS-FR-95 to GS-FR-97) is approved; GS-Q-13 is closed and the 0.3 no-role-change fallback is dropped.
- GS-CC-26 [New 0.4] [Superseded by GS-CC-40 in 1.1]: sstate retention (GS-Q-08 closed as decided): new optional input `garage_buckets[].expire_after_days` (production `sstate`: 90); new grant flag `owner`; new key `bucket-admin` with Vault variables `vault_garage_bucket_admin_key_id` and `vault_garage_bucket_admin_secret`; new FRs GS-FR-100 to GS-FR-105, GS-BR-12, GS-BR-13, GS-NFR-07, GS-NFR-08, GS-E-28 to GS-E-31 and GS-AC-60 to GS-AC-64. The 0.3 Out of Scope entry "sstate retention or garbage collection tooling - deferred" is removed.
- GS-CC-27 [New 0.4]: GS-Q-14 becomes the accepted risk GS-R-01 with Erik's reasoning; GS-FR-79 (metadata snapshot first) is raised from [Should] to [Must]. References to GS-Q-14 now point to GS-R-01.
- GS-CC-28 [New 0.4] [Superseded by GS-CC-40 in 1.1]: GS-FR-21, GS-FR-26, GS-FR-27, GS-FR-61, GS-FR-68 and GS-FR-85 are amended for the lifecycle tasks, the `owner` flag, the quota syntax check (GS-A-22), the enable preconditions and the fixture.

#### Contract changes from 0.4 (in 0.5; implementers and tests must follow)

- GS-CC-29 [New 0.5] [Historical: cites IDs deleted in 1.1, see GS-CC-40]: Compound FRs split, one outcome per ID: GS-FR-04 -> GS-FR-04, GS-FR-106, GS-FR-107; GS-FR-23 -> GS-FR-23, GS-FR-108, GS-FR-109, GS-FR-111; GS-FR-32 -> GS-FR-32, GS-FR-112, GS-FR-113; GS-FR-35 -> GS-FR-35, GS-FR-114; GS-FR-61 -> GS-FR-61, GS-FR-115 to GS-FR-120; GS-FR-70 -> GS-FR-70, GS-FR-127; GS-FR-73 -> GS-FR-73, GS-FR-121, GS-FR-122; GS-FR-95 -> GS-FR-95, GS-FR-130; GS-FR-100 -> GS-FR-100, GS-FR-123; GS-FR-104 -> GS-FR-104, GS-FR-124; GS-FR-105 -> GS-FR-105, GS-FR-125. No meaning changed by the split.
- GS-CC-30 [New 0.5] [Superseded by GS-CC-40 in 1.1]: Production list composition (decided 2026-10-17): `btrbk_sources` restates `data` and `containers` and appends the Garage entries only while `garage_enabled` is true (GS-FR-126); `backup_disk_freshness_checks` (GS-FR-128) and `caddy_sites` (GS-FR-129) follow the same pattern. New input `garage_s3_client_image` (GS-FR-124, GS-FR-131). New cross-feature task GS-FR-110 (update of backup-btrbk-and-db-dump.md) with enable precondition GS-FR-117.
- GS-CC-31 [New 0.5] (GS-Q-15 closed, option 2): the Garage secret files move from `<garage_config_dir>/secrets/` to `garage_secrets_dir` (default `/etc/garage/secrets`, `root:<garage_user> 0750`), outside every btrbk and snapper source, with a run-time guard (GS-FR-20, GS-FR-121, GS-FR-132 to GS-FR-134, GS-BR-14, GS-NFR-09, GS-E-32, GS-AC-67, GS-AC-68). The restore re-renders secrets from Vault (GS-FR-77). [Amended 0.6: the default path is `/var/lib/garage/secrets`, GS-CC-33.]
- GS-CC-32 [New 0.5] [Historical: cites IDs deleted in 1.1, see GS-CC-40]: Priorities aligned: GS-FR-74 and GS-FR-67 become [Must]. GS-NFR-04 becomes a day-30 bound with a day-120 re-measure (GS-AC-65). GS-AC-10 and GS-AC-52 use a realistic sstate key; GS-AC-38 asserts the absence of `metadata_snapshots_dir` and `metadata_auto_snapshot_interval`; GS-AC-60 uses `garage_s3_client_image`.

#### Contract changes from 0.5 (in 0.6; implementers and tests must follow)

- GS-CC-33 [New 0.6] (GS-Q-16 closed): `garage_secrets_dir` defaults to `/var/lib/garage/secrets` instead of `/etc/garage/secrets`; it is in the subvolume `/@/var`, which no snapper config and no btrbk source covers (GS-F-22). The run-time guard GS-FR-134 and GS-AC-67/68 stay. Confirmed as decided: `garage_secrets_dir` `root:<garage_user> 0750` (GS-FR-132), the `caddy_sites` conditional (GS-FR-129) and `docker.io/amazon/aws-cli` as `garage_s3_client_image` (GS-A-26).

#### Contract changes from 0.6 (in 0.7, editorial; no decision changed)

- GS-CC-34 [New 0.7] [Superseded by GS-CC-40 in 1.1]: GS-FR-133 states the one credential path of the lifecycle client: environment variables of its one-shot container, never a file and never a command line (GS-A-07 amended). GS-FR-77 is [Must], aligned with GS-FR-118. GS-FR-110 names the exact rows of backup-btrbk-and-db-dump.md (BD-FR-51, the `btrbk_sources` Inputs row, the source-snapshot Outputs row). GS-AC-04 asserts stub directories instead of "empty" snapshot dirs. GS-NFR-04 states the post-day-120 bound; GS-NFR-08 is measured at GS-AC-64. New GS-A-27, GS-A-28, GS-R-03 and GS-AC-70 to GS-AC-72; GS-AC-40, GS-AC-55, GS-AC-64, GS-AC-67 and GS-AC-69 sharpened.

#### Contract changes from 0.7 (in 0.8; implementers and tests must follow)

- GS-CC-35 [New 0.8]: Spike T-03 (`tests/spikes/garage-caddy-routing.md`): Garage v2.4.1 does not start without `[s3_web] root_domain` ("missing field `root_domain`"). GS-FR-38, the O-1 `[s3_web] root_domain` row and GS-AC-38 now require `root_domain = "{{ garage_s3_domain }}"` without a leading dot; "root_domain not set" is removed. GS-A-01 (the `root_domain` part) and GS-A-15 are verified by T-03. The Caddy fragment O-6 ships unchanged; GS-AC-10, GS-AC-30, GS-AC-31, GS-AC-52, GS-A-16 and GS-A-23 passed in T-03.

#### Contract changes from 0.8 (in 0.9; implementers and tests must follow)

- GS-CC-36 [New 0.9] (T-01): Quadlet verification. `systemd-analyze verify` cannot check a `.container` file (same limit as `restic-server`, `tests/render.d/30-restic-server.yml`). GS-AC-38 keeps its regex asserts [S] and adds a generator check: the render-check container runs the Podman Quadlet generator in dry-run mode (`/usr/libexec/podman/quadlet -dryrun`) on the rendered `garage.container`, and the generated `garage.service` passes `systemd-analyze verify` (GS-A-30). If the generator cannot run in that container, the generator half moves to [V], where GS-AC-37 already reads the generated unit, and GS-AC-38 names that in the same change.
- GS-CC-37 [New 0.9] (T-01): config path. New GS-FR-136: the server and every CLI call read `<garage_config_dir>/garage.toml`; the Quadlet passes it with `Environment=GARAGE_CONFIG_FILE=...`, which is unverified (GS-A-29; spike T-02 `tests/spikes/garage-v2.4.1-cli-config.md` records only the default `/etc/garage.toml` and the entrypoint `/garage server`). Fallback if the variable is not read: a command-line argument. GS-AC-38 asserts the line; GS-AC-35 proves it on [V].
- GS-CC-38 [New 0.9] [Superseded by GS-CC-40 in 1.1 for `garage_layout_capacity`] (T-01): `garage_layout_capacity` and `garage_s3_domain` are declared `required: false` with default `''` in `meta/argument_specs.yml` and `defaults/main.yml`, like the other spec-required inputs that have defaults. New GS-FR-135: the preflight check fails before any change when either is empty or invalid, so the requirement has no gap. GS-AC-25 gains two rows.

#### Contract changes from 0.9 (in 1.0; implementers and tests must follow)

- GS-CC-39 [New 1.0] (T-07): `no_log: true` on an `assert` also hides its `fail_msg`, so the failure could no longer name the invalid input (GS-E-04). Decision (the requirements engineer's recommendation, which the coordinator asked for): assert-only input checks keep `no_log` off under the conditions now written into GS-FR-21: untemplated conditions read the secret, static messages name the variable only, and `quiet: true` is set. The test is the proof: GS-AC-25 runs every invalid-input row at `-vvv` and finds no fixture secret value, and GS-AC-23 covers a full run. The alternative (`no_log` on the assert, with a generic failure message) was rejected because GS-E-04 requires the message to name the variable.

#### Contract changes from 1.0 (in 1.1; implementers and tests must follow)

- GS-CC-40 [New 1.1] (Erik's decision 2026-10-18, scope change): the rule is "anything the Garage or S3 CLI can do is done by the user through the CLI, not by Ansible". Removed from the role: node layout (GS-FR-14), buckets (GS-FR-15), quotas (GS-FR-27), website flags (GS-FR-28), key import and comparison (GS-FR-24, GS-FR-25), grants (GS-FR-26), `mirror-read` (GS-FR-33), lifecycle (GS-FR-100 to GS-FR-105, GS-FR-123 to GS-FR-125, GS-FR-131), the expiration enable precondition (GS-FR-119), GS-BR-06, GS-BR-07, GS-BR-12, GS-BR-13, GS-NFR-01, GS-NFR-07, GS-NFR-08, GS-E-06 to GS-E-10, GS-E-14, GS-E-28 to GS-E-31 and their scenarios; inputs `garage_buckets`, `garage_keys`, `garage_layout_zone`, `garage_layout_capacity`, `garage_s3_client_image` and the S3-key Vault entries. Kept: store and subvolumes, `garage.toml` (including `[s3_web] root_domain`), secrets and admin token file, Quadlet, Caddy routes, no published ports, btrbk backup, restore procedure, health check and readiness wait (which only check that Garage runs). New: GS-FR-137 to GS-FR-140, GS-BR-15, GS-BR-16, GS-E-33, GS-AC-73 to GS-AC-75; the [V] test setup replaces the role-managed fixture (GS-FR-68). Consequence: Garage runs without a layout until the user runs the README steps. GS-Q-08 (retention) is retired as user-owned; the 500 GiB `sstate` quota is a README recommendation only. GS-A-20 to GS-A-22 and GS-A-28 move to Out of Scope; their spike notes stay as evidence for the README.

#### Contract changes from 1.1 (in 1.2, cleanup; no scope decision)

- GS-CC-41 [New 1.2]: Re-audit cleanup of 1.1. Stale contract entries GS-CC-08, -22, -26, -28, -30, -34, -38 and the GS-Q-07 resolved row are tagged "Superseded by GS-CC-40"; the other historical entries that cite deleted IDs are tagged "Historical". New GS-FR-141 governs the secret-format and path rows of GS-E-04 and GS-AC-25. GS-E-03 now says "fail at that command" (it cannot always fail before any change) and gets GS-AC-76. GS-FR-139 is verified by GS-AC-50, which also asserts the capacity note. `garage block list-errors` is pinned from spike T-02 (GS-FR-77, GS-AC-55). GS-A-10 points to spike T-02 and GS-AC-07; the Out of Scope quota entry no longer cites a deleted error case. "realistic" and "visibly" are replaced. Erik's decisions of 2026-10-18, also in GS-CC-41: (1) GS-NFR-04 is an observation, not a gate: the day-30 and day-120 sizes (GS-AC-51, GS-AC-65) are recorded in the README, the 1 TiB limit is removed, and the 85 % `disk_space` alert (GS-NFR-03) is the backstop; (2) the enable gate GS-FR-120 and GS-NFR-02 read no quota figure: the only size gate is `/mnt/data` usage <= 85 % (GS-AC-47). GS-FR-140 keeps the 500 GiB quota as a README recommendation only.

#### External preconditions (not deliverables of this feature)

- GS-P-01 [Amended 0.3]: A ZeroTier flow rule limits the netcup CI member `10.243.73.1` (GS-F-17) to the NAS's `:443` (W1). Owner: Erik, by hand in ZeroTier Central. It is recorded in `ops-de-wahlberger-dev/docs/zerotier-flow-rules.md`. Until it exists, the netcup flow is blocked (GS-BR-08). The LAN build hosts do not depend on it.
- GS-P-02 [Amended 0.3]: The NAS SSH host key is verified out of band. Satisfied on 2026-10-17 (GS-F-13).
- GS-P-03 [Amended 1.1]: The two entries `vault_garage_rpc_secret` and `vault_garage_admin_token` are added to the existing `inventories/production/group_vars/all/vault.yml`, encrypted with the existing 1Password item `Ansible Vault - nas-de-int-wahlberger-dev` (vault `DevOps`). No new 1Password item (GS-Q-10 closed). S3 access keys are user-owned and are not in Vault.

### Actors

| Actor | Human/System | Description |
|---|---|---|
| Erik (owner) | Human | Answers Open Questions, approves role changes, holds Vault and 1Password, runs the playbook, edits ZeroTier Central and owns the Cloudflare zone |
| Ansible control host | System | Erik's Mac or Semaphore on ops-de-wahlberger-dev; applies `site.yml` |
| `garage` role | System | New role in this repository; creates the two subvolumes, the secrets, `garage.toml` and the Quadlet, and checks that Garage runs. It creates no Garage state [Amended 1.1] |
| Garage | System | Container `garage` (`docker.io/dxflrs/garage:v2.4.1`) on the NAS: S3 API, s3_web, RPC and admin endpoints |
| Caddy (`caddy` role) | System | Existing reverse proxy on `caddy.network`; serves TLS (DNS-01) for the S3 host and splits its requests into the web route and the API route |
| Build host | System | Yocto/BitBake host on the LAN or ZeroTier; reads through the web route and uploads through the API route with a key the user created |
| netcup CI runner | System | `forgejo_runner` on netcup-ci-wahlberger-dev (`10.243.73.1`), over ZeroTier; uploads and reads like a build host (blocked until GS-P-01) |
| btrbk | System | Existing role; snapshots the two Garage subvolumes and replicates them to the backup disk |
| `cloudflare_dns` | System | Existing role; writes the one public, unproxied CNAME for the S3 host |
| `disk_space`, `notify_failure` | System | Existing roles; usage alerts and unit-failure emails |
| ZeroTier Central | External system | Flow rules, edited by hand by Erik |
| Store user (Erik) [New 1.1] | Human | Runs the README steps on the NAS (`podman exec garage /garage ...`) and with S3 clients: node layout, buckets, keys, grants, quotas, website access, lifecycle rules |

### Functional Requirements

#### A. Storage (role `garage`)

- GS-FR-01 [Must] [Amended 0.3]: Before any change, the role shall read `findmnt -no FSTYPE <path>` for `garage_mount_path` and for `garage_meta_mount_path`. If either output is not `btrfs` (including empty output, meaning not mounted), the role shall fail and change nothing.
- GS-FR-02 [Must] [Amended 0.3]: For each of `garage_store_path` and `garage_meta_path` that does not exist, the role shall create it with `btrfs subvolume create`. The role creates `garage_config_dir`, the parent of `garage_meta_path`, as a directory first.
- GS-FR-03 [Must] [Amended 0.3]: The role shall create the directory `data/` in the data subvolume. The data subvolume contains no `meta/` directory.
- GS-FR-04 [Must] [Amended 0.5]: The data subvolume root shall be owned by `root:root` with mode `0700` (GS-CC-06).
- GS-FR-106 [Must] [New 0.5, split from GS-FR-04]: `<garage_store_path>/data` shall be owned by `<garage_user>:<garage_user>` with mode `0700`.
- GS-FR-107 [Must] [New 0.5, split from GS-FR-04]: The metadata subvolume root shall be owned by `<garage_user>:<garage_user>` with mode `0700`.
- GS-FR-05 [Must]: The Garage process shall run with the numeric UID and GID of `garage_user` (`User=`/`Group=` in the Quadlet). Neither ID shall be 0 (GS-Q-12 closed).
- GS-FR-06 [Should] [Amended 0.3]: While the metadata subvolume is empty, the role shall set the No_COW attribute (`chattr +C`) on its root directory. If it already contains files, the role shall not change its attributes (GS-Q-11 closed: metadata on the NVMe, No_COW kept).
- GS-FR-07 [Must] [Amended 0.3]: `garage.toml` shall set `metadata_dir` to `garage_meta_path` (`/mnt/containers/garage/meta`) and `data_dir` to `<garage_store_path>/data` (`/mnt/data/garage/data`): one data directory, no multi-disk list. Container paths equal the host paths.
- GS-FR-08 [Should] [Amended 0.3]: `garage.toml` shall set neither `metadata_snapshots_dir` nor `metadata_auto_snapshot_interval`. The backup copy of data and metadata is the pair of btrbk snapshots of the Garage sources from one btrbk run (GS-FR-79, GS-BR-11). The pair is not atomic (accepted risk GS-R-01).
- GS-FR-09 [Must] [Amended 0.3]: If `garage_store_path` or `garage_meta_path` exists and `btrfs subvolume show <path>` exits non-zero for it, the role shall fail before any change. It shall not move, delete or convert the path (GS-BR-02).

#### B. Backup (btrbk)

- GS-FR-70 [Must] [Amended 0.5]: The production `btrbk_sources` entry for the data subvolume shall be `{name: garage, path: /mnt/data/garage, mount_path: /mnt/data, snapshot_dir: /mnt/data/.btrbk-garage}` (GS-Q-05 closed).
- GS-FR-78 [Must] [Amended 0.5]: The production `btrbk_sources` entry for the metadata subvolume shall be `{name: garage-meta, path: /mnt/containers/garage/meta, mount_path: /mnt/containers, snapshot_dir: /mnt/containers/.btrbk-garage-meta}`.
- GS-FR-126 [Must] [New 0.5] (decided 2026-10-17): Production `vars.yml` shall define `btrbk_sources` as one Jinja expression: the `data` and `containers` entries restated with the values of `roles/btrbk/defaults/main.yml`, followed by the entries of GS-FR-78 and GS-FR-70 only when `garage_enabled | bool` is true.
- GS-FR-127 [Must] [New 0.5, split from GS-FR-70]: `roles/btrbk/defaults/main.yml` shall keep its `btrbk_sources` default unchanged (GS-CC-20).
- GS-FR-128 [Must] [New 0.5] (decided 2026-10-17): Production `vars.yml` shall define `backup_disk_freshness_checks` as one Jinja expression: the four existing entries unchanged, followed by the two entries of GS-FR-74 only when `garage_enabled | bool` is true.
- GS-FR-79 [Must] [New 0.3] [Amended 0.4] (mitigation of GS-R-01, decided 2026-10-17): Production `btrbk_sources` shall list `garage-meta` before `garage`, so that one `btrbk run` snapshots both and takes the metadata snapshot first (GS-A-17).
- GS-FR-71 [Must] [Amended 0.3]: btrbk shall replicate each Garage source to `<btrbk_target_dir>/<name>` (`/mnt/backup/btrbk/garage`, `/mnt/backup/btrbk/garage-meta`) with the role-wide retention: `btrbk_snapshot_preserve_min` `2d` and `btrbk_target_preserve` `14d 8w 12m 3y` (GS-Q-07 closed: shared retention).
- GS-FR-72 [Must] [Amended 0.3]: btrbk shall create the snapshots of each Garage source in a sibling directory outside the source subvolume, on the same filesystem and outside the Samba share: `garage` in `/mnt/data/.btrbk-garage`, `garage-meta` in `/mnt/containers/.btrbk-garage-meta` (GS-Q-06 closed). No `.btrbk` directory exists inside either Garage subvolume.
- GS-FR-73 [Must] [Amended 0.5]: The Garage container shall bind-mount `<garage_store_path>/data` and `garage_meta_path` with `:Z`.
- GS-FR-121 [Must] [New 0.5, split from GS-FR-73]: The Garage container shall bind-mount `<garage_config_dir>/garage.toml` and `garage_secrets_dir` read-only (`:ro`).
- GS-FR-122 [Must] [New 0.5, split from GS-FR-73]: The Quadlet shall contain no `Volume=` line other than those of GS-FR-73 and GS-FR-121; in particular none for the data subvolume root, `garage_config_dir` as a whole or a snapshot directory, so the `:Z` relabel never reaches a read-only btrbk snapshot.
- GS-FR-74 [Must] [Amended 0.5]: The two Garage entries of production `backup_disk_freshness_checks` shall be `{path: /mnt/backup/btrbk/garage, max_age_hours: 26}` and `{path: /mnt/backup/btrbk/garage-meta, max_age_hours: 26}` (composition in GS-FR-128; [Must] to match GS-NFR-06).
- GS-FR-75 [Must] [Amended 0.3] (`btrbk` role contract change, approved 2026-10-17, GS-CC-20): Where a `btrbk_sources` entry has the optional key `mount_path`, the btrbk mount guard shall check `mount_path` with `findmnt --mountpoint` against `storage_mounts` (UUID and subvolume, as today) and the source `path` with `btrfs subvolume show`, instead of requiring `path` to be a mount point (GS-F-06). Entries without `mount_path` keep today's check.
- GS-FR-76 [Must] [Amended 0.3] (`btrbk` role contract change, approved 2026-10-17): If a source `path` does not exist, is not a btrfs subvolume, or (where `mount_path` is set) is not below `mount_path`, the btrbk role shall fail before any change and shall not create the path (GS-BR-04, GS-F-07).
- GS-FR-90 [Must] [New 0.3] (`btrbk` role contract change, approved 2026-10-17): `btrbk_sources` entries shall accept an optional key `snapshot_dir` (absolute path). Where it is set, `btrbk.conf` shall place that source's snapshots in `snapshot_dir`. Entries without it keep `<path>/<btrbk_snapshot_dirname>` (GS-F-19, GS-A-18).
- GS-FR-91 [Must] [New 0.3] (`btrbk` role contract change, approved 2026-10-17): After the mount guard passes, the btrbk role shall create each per-source `snapshot_dir` with `root:root 0700`, instead of `<path>/<btrbk_snapshot_dirname>` for that source.
- GS-FR-92 [Must] [New 0.3] (`btrbk` role contract change, approved 2026-10-17): If a per-source `snapshot_dir` is not absolute, is at or below `samba_data_dir`, is at or below the source `path`, or is on another mount than the source (`findmnt --noheadings --output TARGET --target` reports different targets for the parent of `snapshot_dir` and for `path`), the btrbk role shall fail before any change.
- GS-FR-77 [Must] [Amended 0.7, label aligned with GS-FR-118]: The role README shall describe the restore of the store: stop `garage.service`; restore `data/` from `/mnt/backup/btrbk/garage/garage.<ts>` and the metadata subvolume content from `/mnt/backup/btrbk/garage-meta/garage-meta.<ts>`, both with the same `<ts>` (GS-BR-11); re-render the secret files from Vault with `ansible-playbook site.yml --tags garage` (they are not in any backup, GS-BR-14); start the service; run `garage status` and `garage block list-errors`, which exits 0 and prints only its header line `Hash  RC  Errors  Last error  Next try` when no block has an error (verified in spike T-02, `tests/spikes/garage-v2.4.1-cli-config.md`).
- GS-FR-110 [Must] [Amended 0.7] (task, cross-feature): [backup-btrbk-and-db-dump.md](backup-btrbk-and-db-dump.md) shall be updated by its own refactor in these places:
  - BD-FR-51 (snapshots in `<source path>/<btrbk_snapshot_dirname>`): add "or in the entry's `snapshot_dir` where set" (GS-FR-90 to GS-FR-92);
  - the Inputs row `btrbk_sources` ("Each path is a `storage_mounts` path"): add the optional keys `mount_path` (a `storage_mounts` path; `path` is a btrfs subvolume below it, checked with `btrfs subvolume show`) and `snapshot_dir` (GS-FR-75, GS-FR-76);
  - the Outputs row "Source snapshots `<source>/.btrbk/<name>.<timestamp>`": add the per-source `snapshot_dir` location.
  This feature does not edit that file; the update is a precondition for enabling (GS-FR-117).

#### C. Garage service

- GS-FR-10 [Must]: `roles/garage/defaults/main.yml` shall pin `garage_image: docker.io/dxflrs/garage:v2.4.1` on a single line. The tag shall never be `latest`.
- GS-FR-18 [Should]: The `garage_image` line shall match the Renovate custom-manager regex in the top-level `renovate.json` (GS-F-10).
- GS-FR-11 [Must]: The role shall render `garage.toml` from `roles/garage/templates/garage.toml.j2` with exactly the keys and values in Output O-1.
- GS-FR-137 [Must] [New 1.1]: After the role has run and the user has run the README layout steps (GS-FR-139), a bucket and key the user creates with the Garage CLI shall accept signed uploads and downloads through the API route, with no further Ansible change.
- GS-FR-136 [Must] [Amended 1.1]: The Garage server and every Garage CLI call in the container (health check, readiness wait, and the user's `podman exec garage /garage ...` calls) shall read `<garage_config_dir>/garage.toml`. The Quadlet passes the path with `Environment=GARAGE_CONFIG_FILE=<garage_config_dir>/garage.toml` (GS-A-29). If GS-A-29 fails, the path is passed as a command-line argument instead: `Exec=` gets the config option before `server`, and `HealthCmd=` and every `podman exec garage /garage ...` call get the same option; GS-FR-16, GS-AC-36 and GS-AC-38 are amended in the same change.
- GS-FR-12 [Must] [Amended 1.1]: `garage_rpc_secret` and `garage_admin_token` shall come from Vault (`vault_garage_rpc_secret`, `vault_garage_admin_token`) through `vars.yml` indirection with `| default('')`.
- GS-FR-20 [Must] [Amended 0.5]: The role shall write the RPC secret to `<garage_secrets_dir>/rpc_secret` and the admin token to `<garage_secrets_dir>/admin_token`, each owned by `<garage_user>:<garage_user>` with mode `0400` (GS-A-03, GS-Q-15 closed).
- GS-FR-132 [Must] [New 0.5]: `garage_secrets_dir` shall be a directory owned by `root:<garage_user>` with mode `0750`.
- GS-FR-133 [Must] [Amended 1.1]: The only Garage secret files on the host shall be `rpc_secret` and `admin_token` in `garage_secrets_dir`.
- GS-FR-134 [Must] [New 0.5]: Before any change, the role shall check that no btrbk source and no snapper config covers `garage_secrets_dir`: where the path (or, before it exists, its nearest existing parent) is on btrfs, `btrfs inspect-internal rootid` of it shall differ from the root ID of every `btrbk_sources` path and of every subvolume listed by `snapper list-configs`. If the check fails, the role shall fail before any change, naming the path and the covering source or config (GS-E-32). For the default `/var/lib/garage/secrets` the check passes (GS-F-22).
- GS-FR-21 [Must] [Amended 1.0]: Every task that receives a secret value shall set `no_log: true`. This covers the secret files [Amended 1.1: key and lifecycle tasks no longer exist]. Approved exception for assert-only input checks (GS-CC-39): an `ansible.builtin.assert` task may omit `no_log` when its `that` conditions are untemplated expressions that read the secret variable (no `{{ }}`, so the echoed `assertion` text holds no value), its `fail_msg` and `success_msg` are static text that names the variable and never templates a secret, and it sets `quiet: true`. GS-AC-23 and GS-AC-25 prove that no fixture secret value appears in the output.
- GS-FR-13 [Must]: The Quadlet shall contain no `PublishPort=` line: no Garage port (3900 to 3903) is published on any host address (GS-CC-03, W1).
- GS-FR-22 [Must]: The Quadlet shall set `ContainerName=garage` and attach the container to `caddy.network` only.
- GS-FR-23 [Must] [Amended 0.5]: Garage's S3 API shall listen on `0.0.0.0:3900` inside the container's network namespace (O-1).
- GS-FR-108 [Must] [New 0.5, split from GS-FR-23]: Garage's s3_web endpoint shall listen on `0.0.0.0:3902` inside the container's network namespace.
- GS-FR-109 [Must] [New 0.5, split from GS-FR-23]: Garage's RPC endpoint shall listen on `127.0.0.1:3901`, the container's loopback.
- GS-FR-111 [Must] [New 0.5, split from GS-FR-23]: Garage's admin endpoint shall listen on `127.0.0.1:3903`, the container's loopback.
- GS-FR-14 [Deleted 1.1]: Role-run node layout. The user applies the layout with the README steps (GS-FR-139, GS-CC-40).
- GS-FR-15 [Deleted 1.1]: Bucket creation; user-owned (GS-CC-40).
- GS-FR-27 [Deleted 1.1]: Bucket quota; user-owned (GS-CC-40). README recommendation in GS-FR-140.
- GS-FR-28 [Deleted 1.1]: Website flag; user-owned (GS-CC-40).
- GS-FR-24 [Deleted 1.1]: Key import; user-owned (GS-CC-40).
- GS-FR-25 [Deleted 1.1]: Key secret comparison; user-owned keys are not in Vault (GS-CC-40).
- GS-FR-26 [Deleted 1.1]: Grants; user-owned (GS-CC-40).
- GS-FR-29 [Must] [Amended 1.1]: After the container starts or restarts, the role shall wait until `podman exec garage /garage status` exits 0. The wait lasts at most `garage_ready_timeout_sec` (60). On timeout the role fails. The check passes without a layout (spike T-02: `garage status` exits 0 with "NO ROLE ASSIGNED"); it checks only that Garage runs.
- GS-FR-16 [Must]: The Quadlet shall set `HealthCmd=/garage status`.
- GS-FR-80 [Should]: The Quadlet shall set `HealthOnFailure=kill`, so that `Restart=always` restarts an unhealthy container.
- GS-FR-17 [Must]: The role shall deploy `garage.container` through the `container` role with `Restart=always` and `WantedBy=default.target`.
- GS-FR-81 [Must]: The Quadlet shall set `OnFailure=notify-failure@%n.service`, the flap-limited variant used by `restic-server`.
- GS-FR-82 [Must]: The Quadlet shall set `RequiresMountsFor=` to `garage_mount_path` and `garage_config_dir`.
- GS-FR-19 [Must]: The Quadlet shall not set `SecurityLabelDisable=true`.
- GS-FR-138 [Must] [New 1.1]: The role shall run no Garage or S3 command that creates, changes or deletes a layout, bucket, access key, grant, quota, website flag or lifecycle rule. Its only Garage CLI call is `garage status` (GS-FR-29, GS-BR-15).
- GS-FR-83 [Must]: The role shall create `garage_user` as a system account: UID below 1000, shell `/usr/sbin/nologin`.
- GS-FR-84 [Should]: The role README shall record the image's built-in user, read with `podman run --rm docker.io/dxflrs/garage:v2.4.1 id`. If the image has no `id` binary, use `podman image inspect --format '{{.Config.User}}' docker.io/dxflrs/garage:v2.4.1` instead; empty output means root.
- GS-FR-85 [Should] [Amended 1.1]: In check mode, on a host where `garage.service` is not running yet, the role shall skip the readiness wait (GS-FR-29) instead of failing.

#### D. Read path (option B, decided 2026-10-17; addressing amended in 0.3, decision A)

- GS-FR-30 [Must] [Amended 1.1]: For each bucket the user has enabled for website access, Garage's s3_web endpoint shall serve objects to anonymous `GET` and `HEAD` requests through the web route. No bucket is enabled by Ansible.
- GS-FR-31 [Must] [Amended 1.1]: Once the user enables a bucket for website access, it shall be served at `https://<garage_s3_domain>/<bucket>/<key>`, in production `https://s3.de.int.wahlberger.dev/<bucket>/PATH`. No hostname exists per bucket (GS-Q-02 closed).
- GS-FR-32 [Must] [Amended 0.5]: While `garage_enabled` is true, production `caddy_sites` shall contain exactly one entry for Garage: `{host: "{{ garage_s3_domain }}", body: <the body in O-6>}`.
- GS-FR-112 [Must] [New 0.5, split from GS-FR-32]: `caddy_sites` shall contain no entry whose host ends in `.<garage_s3_domain>`.
- GS-FR-113 [Must] [New 0.5, split from GS-FR-32]: The Garage entry's `body` shall contain only the directives listed in O-6.
- GS-FR-129 [Must] [New 0.5]: Production `vars.yml` shall define `caddy_sites` as its existing entries unchanged, followed by the entry of GS-FR-32 only when `garage_enabled | bool` is true (same Jinja pattern as GS-FR-126).
- GS-FR-93 [Must] [New 0.3] (web route): When a request to the S3 host has method `GET` or `HEAD`, carries no `Authorization` header and no `X-Amz-Signature` query parameter, and its path matches `^/([^/]+)(/.*)?$`, Caddy shall forward it to `garage:3902` with the first path segment removed from the path and the `Host` header set to that segment (GS-A-15, GS-A-16).
- GS-FR-94 [Must] [New 0.3] (API route): Caddy shall forward every other request to the S3 host to `garage:3900` with path, query and `Host` header unchanged.
- GS-FR-38 [Must] [Amended 0.8]: `garage.toml` shall set `[s3_web] root_domain = "{{ garage_s3_domain }}"`, without a leading dot. Garage v2.4.1 refuses to start without it, and the bare-`Host` bucket mapping of the web route works with it (GS-A-01, GS-A-15, verified by spike T-03).
- GS-FR-33 [Deleted 1.1]: `mirror-read` key; user-owned (GS-CC-40).
- GS-FR-34 [Must] [Amended 1.1]: The role README shall give consumers the S3 settings: endpoint `https://s3.de.int.wahlberger.dev`, path-style addressing, region `garage`, and, once the user has enabled a bucket for website access, the mirror line `SSTATE_MIRRORS ?= "file://.* https://s3.de.int.wahlberger.dev/<bucket>/PATH"` (for example `<bucket>` = `sstate`).
- GS-FR-139 [Must] [New 1.1]: The role README shall give the exact CLI steps for the one-node layout: read the node ID from `garage status`, `garage layout assign -z <zone> -c <capacity> <node_id>`, `garage layout apply --version 1`, and verify with `garage status` that the node has a role. It states that capacity is a placement weight (GS-A-09) and that `500GB` and `500GiB` differ (spike T-02).
- GS-FR-140 [Should] [New 1.1]: The role README shall give the user CLI steps to create a bucket, create a key, grant read/write, enable website access, set a quota (recommendation for `sstate`: 500 GiB; not part of any gate, GS-NFR-02) and set a lifecycle rule, with the Garage limits recorded in GS-F-21 and the spike notes `tests/spikes/garage-v2.4.1-cli-config.md` (lifecycle permissions) and `tests/spikes/garage-caddy-routing.md`.
- GS-FR-35 [Must] [Amended 0.3]: The DNS record of the S3 host shall be created only by the existing `cloudflare_dns` role from `caddy_sites`: one public, unproxied CNAME `<garage_s3_domain>` to `nas.de.int.wahlberger.dev`, whose A record is the NAS LAN address (GS-F-05, GS-Q-04 closed).
- GS-FR-114 [Must] [New 0.5, split from GS-FR-35]: The feature shall create no DNS record whose name contains a bucket name.
- GS-FR-36 [Must] [Amended 0.3]: Unsigned `PUT`, `POST` and `DELETE` requests to the S3 host shall get a non-2xx status and leave the bucket unchanged (they take the API route, GS-FR-94).
- GS-FR-37 [Must] [Amended 0.3]: The S3 host shall not list bucket contents to unsigned requests: while the bucket has no `index.html`, `GET /<bucket>/` returns 404 and `GET /<bucket>` returns a non-2xx status, and neither response body contains an object key.

#### E. Write path (W1, GS-Q-03 closed)

- GS-FR-50 [Must] [Amended 0.3]: The S3 API shall be reachable only through the API route of the S3 host `https://<garage_s3_domain>` (GS-FR-94). Clients use path-style addressing (`https://<garage_s3_domain>/<bucket>/<key>`) and region `garage`.
- GS-FR-51 [Must]: The S3 host's Caddy site shall contain no `request_body` limit (Caddy default, GS-F-12), so that a 1 GiB object upload is accepted.

#### F. Network and firewall

- GS-FR-40 [Deleted 0.2] [Amended 0.3]: Rich rule for `:3900`. It had no effect on a published port (GS-F-04), and W1 publishes nothing. GS-Q-03 is closed with W1, so it does not return.
- GS-FR-41 [Must]: The feature shall leave `firewall_allowed_services`, `firewall_allowed_ports` and `firewall_rich_rules` unchanged. Caddy's `https` is already allowed.
- GS-FR-42 [Deleted 0.2]: Merged into GS-FR-41.
- GS-FR-43 [Deleted 0.2]: Became the external precondition GS-P-01 and the rule GS-BR-08.
- GS-FR-44 [Must]: `samba_share_path` stays `/mnt/data/samba/Delat`, and no Samba share is added or changed.
- GS-FR-45 [Must]: The feature shall create no Cloudflare record with `proxied: true` and no router port forward.
- GS-FR-46 [Deleted 0.2]: Merged into GS-FR-41.

#### G. Wiring

- GS-FR-60 [Must]: `site.yml` shall run `- role: garage` with `tags: [garage]` and `when: garage_enabled | bool`, placed after `caddy` and before `btrbk` (GS-BR-10).
- GS-FR-61 [Must] [Amended 1.1]: `garage_enabled` shall default to `false` in the role defaults. Production `vars.yml` sets it to `true` only when GS-FR-115 to GS-FR-118 and GS-FR-120 hold.
- GS-FR-115 [Must] [New 0.5, split from GS-FR-61]: Production `garage_enabled` shall be set to `true` only after the `btrbk` role changes (GS-FR-75, GS-FR-76, GS-FR-90 to GS-FR-92) are merged.
- GS-FR-116 [Must] [New 0.5, split from GS-FR-61]: Production `garage_enabled` shall be set to `true` only after the `caddy` role change (GS-FR-95 to GS-FR-97, GS-FR-130) is merged.
- GS-FR-117 [Must] [New 0.5]: Production `garage_enabled` shall be set to `true` only after the update of GS-FR-110 is merged.
- GS-FR-118 [Must] [New 0.5, split from GS-FR-61]: Production `garage_enabled` shall be set to `true` only after the one-time [V] restore drill (GS-AC-55, GS-AC-56) has passed.
- GS-FR-119 [Deleted 1.1]: Enable precondition on the expiration demonstration; lifecycle is user-owned (GS-CC-40).
- GS-FR-120 [Must] [Amended 1.2]: Production `garage_enabled` shall be set to `true` only after the GS-AC-47 check of `/mnt/data` usage against the 85 % threshold is recorded (GS-NFR-02).
- GS-FR-62 [Must]: `tests/render.d/40-garage.yml` shall render `garage.toml` and `garage.container` with the VM fixture and assert the lines listed in GS-AC-38.
- GS-FR-63 [Must]: `molecule/default/converge.yml` shall not include the `garage` role (it needs btrfs, Podman and Garage). The molecule exclusion note in `CLAUDE.md` names it.
- GS-FR-64 [Must]: `roles/garage/meta/argument_specs.yml` shall declare every `garage_*` input in the Inputs table.
- GS-FR-135 [Must] [Amended 1.1]: Before any change, the role's preflight check shall fail, naming the variable and never a value, when `garage_s3_domain` is empty or does not end in `.{{ cloudflare_dns_zone }}` (GS-E-04). This check, not the argument spec (`required: false`, GS-CC-38), enforces that it is set.
- GS-FR-141 [Must] [New 1.2]: Before any change, the role's preflight check shall fail, naming the variable and never a value, when `garage_rpc_secret` does not match `^[0-9a-f]{64}$`, when `garage_admin_token` is shorter than 32 characters, when `garage_meta_path` is not a direct child of `garage_config_dir`, or when `garage_config_dir` is not below `garage_meta_mount_path` (GS-E-04). Sources: the RPC secret format is Garage's 32-byte hex `rpc_secret` (configuration reference, generated with `openssl rand -hex 32`); the admin-token minimum and the path rules are this spec's Inputs constraints since 0.2 and 0.3.
- GS-FR-65 [Must] [Amended 1.1]: The VM fixture inventory shall define a fake value for `vault_garage_rpc_secret` (a fixed 64-hex fixture string listed in `inventories/vm/README.md`) and for `vault_garage_admin_token` (contains the marker `fixture-garage-not-a-secret`). These are the "fixture secret values" in GS-AC-23 and GS-AC-24.
- GS-FR-68 [Must] [Amended 1.1]: The [V] scenarios that need data shall run the test setup (Terms) first: README layout steps, buckets `sstate` (website access) and `private-test` (no website access), key `test-rw` with read and write on both, object `selftest/up`. It uses only the Garage CLI and an S3 client, never role variables, and is used by GS-AC-07, GS-AC-10, GS-AC-30, GS-AC-31, GS-AC-52, GS-AC-55, GS-AC-56 and GS-AC-73.
- GS-FR-66 [Should]: `vault.yml.example` shall list every `vault_garage_*` variable with its generation command (GS-P-03).
- GS-FR-67 [Must] [Amended 0.5]: If `garage_enabled` is true and `backup_disk_enabled` is false, the role shall fail before any change, because the store must be backed up (decision 2026-10-17).

#### H. `caddy` role change (GS-CC-15, approved 2026-10-17)

- GS-FR-95 [Must] [Amended 0.5]: The `caddy` role shall accept an optional `caddy_sites[].body` (str). Where `body` is set, the rendered site block shall equal `<host> { <body> }` (whitespace aside, as compared in GS-AC-48) and contain no generated `reverse_proxy` line.
- GS-FR-130 [Must] [New 0.5, split from GS-FR-95]: `roles/caddy/meta/argument_specs.yml` shall declare `caddy_sites[].body` optional and `caddy_sites[].upstream` optional.
- GS-FR-96 [Must] [New 0.3]: For `caddy_sites` entries without `body`, the rendered `Caddyfile` shall be byte-identical to the output of the template on `master` before this feature.
- GS-FR-97 [Must] [New 0.3]: If a `caddy_sites` entry sets `body` together with `upstream` or `extra`, or sets neither `body` nor `upstream`, the `caddy` role shall fail before any change, naming the entry's `host`.

#### I. Object retention [Deleted 1.1] (user-owned, GS-CC-40)

- GS-FR-100 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-123 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-101 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-102 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-103 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-104 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-124 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-131 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-105 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).
- GS-FR-125 [Deleted 1.1]: lifecycle/retention by the role; user-owned (GS-CC-40).

### Business Rules

- GS-BR-01 [Deleted 0.2]: "No backup by default". Replaced by the owner decision of 2026-10-17 to back up the store.
- GS-BR-02: A Garage subvolume path (`garage_store_path` or `garage_meta_path`) exists and is not a btrfs subvolume -> the play fails before any change, on every run (GS-FR-09).
- GS-BR-03 [Amended 0.5]: The store is backed up only by the Garage sources `garage` and `garage-meta`. The `/mnt/data` and `/mnt/containers` btrbk and snapper snapshots do not contain it (GS-F-03), and no restic job covers it (GS-F-02). The Garage secrets are not part of any backup (GS-BR-14).
- GS-BR-14 [New 0.5] (GS-Q-15 closed, option 2): Garage secret files exist only in Vault and in `garage_secrets_dir` on the NAS -> no btrbk snapshot, snapper snapshot or backup-disk replica contains them, and a restore re-renders them from Vault instead of restoring them (GS-FR-77, GS-FR-134). The Garage node key in the metadata subvolume is not a Vault secret; it is backed up with `garage-meta` because a restore needs it (GS-A-25).
- GS-BR-04: A btrbk source path is absent or not a btrfs subvolume -> btrbk fails before any change and never creates the path (GS-FR-76).
- GS-BR-05 [Amended 0.3]: `garage_s3_domain` is published in public DNS (GS-F-05) and in certificate-transparency logs -> the hostname contains no confidential information. Bucket names appear only in request paths: no DNS record name and no certificate name contains a bucket name (GS-FR-35, GS-Q-04 closed).
- GS-BR-06 [Deleted 1.1]: S3 keys are user-owned and not in Vault (GS-CC-40).
- GS-BR-07 [Deleted 1.1]: The role compares no keys (GS-CC-40).
- GS-BR-08: The ZeroTier rule GS-P-01 does not exist -> the netcup runner is not configured to use the store.
- GS-BR-09 [Amended 1.1]: The user has enabled a bucket for website access -> every client that reaches the S3 host can read every object of it with an unsigned `GET` or `HEAD` on the web route. A bucket without website access -> only requests signed with a key that has a read grant can read; unsigned reads get 404.
- GS-BR-10: The `garage` role runs before `btrbk` in `site.yml` -> both Garage subvolumes exist before btrbk checks or snapshots them.
- GS-BR-11 [New 0.3]: A restore of the store uses the `garage` and `garage-meta` snapshots of the same btrbk run (same `<ts>`) -> snapshots of different runs are never combined (GS-FR-77).
- GS-BR-12 [Deleted 1.1]: Retention is user-owned (GS-CC-40).
- GS-BR-13 [Deleted 1.1]: Quotas are user-owned (GS-CC-40); README recommendation in GS-FR-140.
- GS-BR-15 [New 1.1]: Node layout, buckets, access keys, grants, quotas, website flags and lifecycle rules are user-owned -> a role run creates, changes and deletes none of them, and leaves the ones the user made unchanged (GS-FR-138).
- GS-BR-16 [New 1.1]: Garage has no layout until the user runs the README layout steps -> Garage runs and `garage status` exits 0, but it stores and serves no objects; the role run still succeeds (GS-FR-29, GS-E-33).

### Inputs

| Name | Type | Required | Default | Constraints |
|---|---|---|---|---|
| `garage_enabled` | bool | no | `false` | `site.yml` gate (GS-FR-60, GS-FR-61) |
| `garage_image` | str | no | `docker.io/dxflrs/garage:v2.4.1` | Fully qualified; tag is not `latest`; single line (GS-FR-10) |
| `garage_mount_path` | path | no | `/mnt/data` | Equals a `storage_mounts` path; btrfs (GS-FR-01); mount of the data subvolume |
| `garage_store_path` | path | no | `{{ garage_mount_path }}/garage` | Data subvolume; direct child of `garage_mount_path`; not at or below `samba_data_dir`, `.snapshots` or a `.btrbk*` directory |
| `garage_meta_mount_path` [New 0.3] | path | no | `/mnt/containers` | Equals a `storage_mounts` path; btrfs (GS-FR-01); mount of the metadata subvolume |
| `garage_config_dir` [Amended 0.5] | path | no | `/mnt/containers/garage` | Below `garage_meta_mount_path`; holds `garage.toml` and the metadata subvolume; holds no secret file (GS-FR-133) |
| `garage_secrets_dir` [New 0.5] [Amended 0.6] | path | no | `/var/lib/garage/secrets` (GS-Q-15, GS-Q-16 closed; in subvolume `/@/var`, GS-F-22) | Absolute; covered by no `btrbk_sources` path and no snapper config (GS-FR-134); `root:<garage_user> 0750` (GS-FR-132) |
| `garage_s3_client_image` | — | — | — | [Deleted 1.1] user-owned or unused (GS-CC-40) |
| `garage_meta_path` [New 0.3] | path | no | `{{ garage_config_dir }}/meta` | Metadata subvolume; direct child of `garage_config_dir`; not at or below `.snapshots` or a `.btrbk*` directory |
| `garage_user` | str | no | `garage` | System account, UID < 1000, nologin (GS-FR-83, GS-Q-12 closed) |
| `garage_uid`, `garage_gid` | int | derived | `getent` at run time | Not 0 (GS-FR-05) |
| `garage_layout_zone` | — | — | — | [Deleted 1.1] user-owned or unused (GS-CC-40) |
| `garage_layout_capacity` | — | — | — | [Deleted 1.1] the layout is a README step (GS-FR-139, GS-CC-40) |
| `garage_s3_domain` [Amended 0.9] | str | yes (enforced by the preflight check GS-FR-135; argument spec `required: false`) | `''`; production `s3.de.int.wahlberger.dev` (GS-Q-02 closed) | FQDN ending in `.{{ cloudflare_dns_zone }}`; also the `[s3_web] root_domain` (GS-FR-38) |
| `garage_s3_region` | str | no | `garage` | Non-empty |
| `garage_buckets` | — | — | — | [Deleted 1.1] user-owned or unused (GS-CC-40) |
| `garage_keys` | — | — | — | [Deleted 1.1] user-owned or unused (GS-CC-40) |
| `garage_rpc_secret` | str | yes | `{{ vault_garage_rpc_secret \| default('') }}` | Matches `^[0-9a-f]{64}$` (`openssl rand -hex 32`) |
| `garage_admin_token` | str | yes | `{{ vault_garage_admin_token \| default('') }}` | >= 32 characters (`openssl rand -base64 32`) |
| `garage_ready_timeout_sec` | int | no | `60` | 10 to 600 (GS-FR-29, GS-NFR-05) |
| `garage_s3_publish_ip` | — | — | — | [Deleted 0.3] W3 only; W1 is final (GS-CC-21) |
| `garage_allowed_sources` | — | — | — | [Deleted 0.3] W2 only; W1 is final (GS-CC-21) |
| Vault [Amended 1.1]: `vault_garage_rpc_secret`, `vault_garage_admin_token` | str | yes | none | Formats above; stored in the existing `vault.yml`, encrypted with the 1Password item `Ansible Vault - nas-de-int-wahlberger-dev` (GS-P-03, GS-Q-10 closed). The S3-key entries of 0.4 are deleted (GS-CC-40) |
| `caddy_sites[].body` [New 0.3] (`caddy` role) | str | no | none | Raw site-block body; excludes `upstream` and `extra` (GS-FR-95, GS-FR-97; approved 2026-10-17) |
| `btrbk_sources[].mount_path` [New 0.3] (`btrbk` role) | path | no | none | A `storage_mounts` path; `path` must be below it (GS-FR-75, GS-FR-76) |
| `btrbk_sources[].snapshot_dir` [New 0.3] (`btrbk` role) | path | no | none (`<path>/<btrbk_snapshot_dirname>`) | Absolute; not at or below `samba_data_dir` or `path`; same mount as `path` (GS-FR-90 to GS-FR-92) |
| Existing, extended by this feature [Amended 0.5]: `caddy_sites`, `btrbk_sources`, `backup_disk_freshness_checks` | list | — | see GS-FR-32, GS-FR-70, GS-FR-74, GS-FR-78 | Composed in production `vars.yml` with a Jinja conditional on `garage_enabled` (GS-FR-126, GS-FR-128, GS-FR-129); non-Garage entries unchanged |

### Outputs

O-1 [Amended 0.3] `garage.toml` at `<garage_config_dir>/garage.toml`, `root:root 0644`, no secret values:

| Key | Value |
|---|---|
| `replication_factor` | `1` |
| `metadata_dir` / `data_dir` | `/mnt/containers/garage/meta` / `/mnt/data/garage/data` (GS-FR-07) |
| `db_engine`, `metadata_fsync`, `data_fsync` | not set (defaults: `lmdb`, `false`, `false`; GS-A-06) |
| `metadata_snapshots_dir`, `metadata_auto_snapshot_interval` | not set (GS-FR-08) |
| `rpc_bind_addr` / `rpc_public_addr` | `"127.0.0.1:3901"` / `"127.0.0.1:3901"` (GS-A-10) |
| `rpc_secret_file` | `"<garage_secrets_dir>/rpc_secret"` (container path equals host path) |
| `[s3_api] api_bind_addr` | `"0.0.0.0:3900"` |
| `[s3_api] s3_region` | `"garage"` |
| `[s3_api] root_domain` | not set (path-style only) |
| `[s3_api] advertise_path_style` | listed in 0.1 as `true`; verify the key exists in the v2.4.1 reference, omit if absent (GS-A-01) |
| `[s3_web] bind_addr` | `"0.0.0.0:3902"` |
| `[s3_web] root_domain` | `"<garage_s3_domain>"`, no leading dot; required (GS-FR-38, verified by spike T-03) |
| `[admin] api_bind_addr` | `"127.0.0.1:3903"` |
| `[admin] admin_token_file` | `"<garage_secrets_dir>/admin_token"` (container path equals host path) |
| `[k2v_api]`, inline `rpc_secret`, inline `admin_token` | absent |

O-2 [Amended 0.5] Quadlet `/etc/containers/systemd/garage.container`:
- `ContainerName=garage`, `Image=<garage_image>`, `Network=caddy.network` (only), `User=`/`Group=` numeric `garage_user` IDs;
- `Volume=` for `/mnt/data/garage/data` and `/mnt/containers/garage/meta` (`:Z`), `garage.toml` (`:ro`) and `garage_secrets_dir` (`:ro`);
- `HealthCmd=/garage status`, `HealthOnFailure=kill`;
- `RequiresMountsFor=<garage_mount_path> <garage_config_dir>`, `OnFailure=notify-failure@%n.service`, `Restart=always`, `WantedBy=default.target`;
- no `PublishPort=`, no `SecurityLabelDisable=`.

O-3 [Amended 0.3]: data subvolume `/mnt/data/garage` with `data/`; metadata subvolume `/mnt/containers/garage/meta`; snapshot directories `/mnt/data/.btrbk-garage` and `/mnt/containers/.btrbk-garage-meta` (created by the btrbk role, GS-FR-91).
O-4 [Amended 0.5]: `garage_secrets_dir` (`root:<garage_user> 0750`) with `rpc_secret` and `admin_token`, each `0400`, owned by `garage_user`; in no snapshot or backup (GS-BR-14).
O-5 [Amended 1.1]: Garage state: none. The role creates no layout, bucket, key, grant, quota, website flag or lifecycle rule; Garage runs with no layout until the user runs the README steps (GS-BR-15, GS-BR-16).

O-6 [Amended 0.3]: one `caddy_sites` entry `{host: "{{ garage_s3_domain }}", body: <body>}`. The rendered site block for production is the fragment below; `body` is the text between the outer braces. Route order: Caddy evaluates the `handle @web` block before the matcher-less `handle` block and runs only one of them; inside `handle @web`, `rewrite` runs before `reverse_proxy` (Caddy's directive order). To verify in a Caddy container (GS-A-16, GS-AC-52). The fragment contains no other directive.

```caddyfile
s3.de.int.wahlberger.dev {
	@web {
		method GET HEAD
		header !Authorization
		not query X-Amz-Signature=*
		path_regexp bucket ^/([^/]+)(/.*)?$
	}
	handle @web {
		rewrite * {re.bucket.2}
		reverse_proxy garage:3902 {
			header_up Host {re.bucket.1}
		}
	}
	handle {
		reverse_proxy garage:3900
	}
}
```

O-7 [Amended 0.3]: one Cloudflare CNAME `s3.de.int.wahlberger.dev` to `nas.de.int.wahlberger.dev` (through `cloudflare_dns`, `proxied: false`).
O-8 [Amended 0.5]: production `vars.yml` compositions of `btrbk_sources` (restated `data`, `containers`, then `garage-meta` and `garage`), `backup_disk_freshness_checks` and `caddy_sites`, the Garage entries only while `garage_enabled` is true (GS-FR-126, GS-FR-128, GS-FR-129); target directories `/mnt/backup/btrbk/garage-meta` and `/mnt/backup/btrbk/garage`.
O-9 [Amended 1.1]: `roles/garage/README.md` with the consumer settings (GS-FR-34), the layout steps (GS-FR-139), the user steps for buckets, keys, grants, website access, quotas and lifecycle (GS-FR-140), the restore steps and the recorded image user.
O-10: `tests/render.d/40-garage.yml`.
O-11 [New 0.3]: `caddy` role: `body` key in `Caddyfile.j2` and `meta/argument_specs.yml`; `btrbk` role: `mount_path` and `snapshot_dir` keys in `btrbk.conf.j2`, `tasks/main.yml`, `tasks/config.yml` and `meta/argument_specs.yml`.

### Error Cases

| ID | Condition | Expected behaviour |
|---|---|---|
| GS-E-01 [Amended 0.3] | `garage_mount_path` or `garage_meta_mount_path` not mounted or not btrfs | Fail before any change; the message names the path and the type found (GS-FR-01) |
| GS-E-02 [Amended 0.3] | `garage_store_path` or `garage_meta_path` exists as a plain directory, file or symlink | Fail before any change; nothing is moved, deleted or converted (GS-FR-09, GS-BR-02) |
| GS-E-03 [Amended 1.2] | A `btrfs` command fails for another reason (I/O error, read-only filesystem, `btrfs-progs` missing, permission) | Fail at that command and show its stderr; no Quadlet is written and `garage.service` is not started (GS-AC-76) |
| GS-E-04 [Amended 1.2] | Required input empty or invalid (secret empty, rpc secret not 64 hex, admin token shorter than 32 characters, `garage_s3_domain` empty or outside the zone, `garage_meta_path` not below `garage_meta_mount_path`) | Fail before any change; the message names the variable, never its value (GS-FR-135, GS-FR-141) |
| GS-E-05 | Image pull fails, or the container exits at start (config error, secret file mode refused) | Unit fails; the role fails when the readiness wait times out (GS-FR-29); `notify-failure@` emails per its flap rule (GS-FR-81) |
| GS-E-06 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-07 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-08 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-09 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-10 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-11 [Amended 0.3] | `/mnt/data` or `/mnt/containers` usage crosses 85 % | `disk_space` emails within 15 min (existing, GS-NFR-03) |
| GS-E-12 [Amended 0.3] | Garage down while Caddy is up | Both routes of the S3 host answer 502; BitBake builds from source (GS-A-11) |
| GS-E-13 [Amended 0.3] | Unsigned `PUT`/`POST`/`DELETE` to the S3 host | Taken by the API route; non-2xx; the bucket is unchanged (GS-FR-36) |
| GS-E-14 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-15 [Amended 0.3] | btrbk source `garage` or `garage-meta` configured while its path is absent, not a subvolume, or not below its `mount_path` | btrbk fails before any change and does not create the path (GS-FR-76, GS-BR-04) |
| GS-E-16 | Backup disk full | btrbk fails and emails through its existing `OnFailure=` (unchanged behaviour) |
| GS-E-17 | Two clients upload the same object key at the same time | S3 last-writer-wins; the content is identical (GS-A-12); not tested |
| GS-E-18 | Two playbook runs overlap | Not supported (GS-A-13) |
| GS-E-19 | `/mnt/data` or `/mnt/containers` not mounted at boot | `garage.service` does not start (`RequiresMountsFor=`, GS-FR-82) |
| GS-E-20 | `garage_enabled` true while `backup_disk_enabled` false | Fail before any change (GS-FR-67) |
| GS-E-21 [Amended 1.1] | Check mode on a host where `garage.service` is not running yet | The readiness wait is skipped; the run does not fail (GS-FR-85) |
| GS-E-22 [New 0.3] | Per-source `snapshot_dir` relative, at or below `samba_data_dir`, at or below the source path, or on another mount than the source | btrbk role fails before any change, naming the source and the `snapshot_dir` (GS-FR-92) |
| GS-E-23 [New 0.3] | `caddy_sites` entry with `body` plus `upstream` or `extra`, or with neither `body` nor `upstream` | `caddy` role fails before any change, naming the entry's `host` (GS-FR-97) |
| GS-E-24 [Amended 1.1] | Unsigned `GET`/`HEAD` for a bucket that does not exist or that the user has not enabled for website access | Taken by the web route; 404; no object data returned (GS-BR-09) |
| GS-E-25 [New 0.3] | Presigned request (`X-Amz-Signature` query parameter, no `Authorization` header) | Taken by the API route; Garage checks the signature (GS-FR-93, GS-FR-94) |
| GS-E-26 [New 0.3] | Skew between the `garage-meta` and `garage` snapshots of one run | After a restore, an object uploaded between the two snapshots is absent (404) and its blocks are unreferenced; every object in the metadata snapshot reads back (GS-A-19, GS-R-01) |
| GS-E-27 [New 0.3] | Restore attempted with `garage` and `garage-meta` snapshots of different runs | Not supported: the README restore steps require the same `<ts>` (GS-BR-11, GS-FR-77) |
| GS-E-28 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-29 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-30 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-31 [Deleted 1.1] | — | Covered user-owned state (GS-CC-40) |
| GS-E-33 [New 1.1] | S3 request before the user has applied a layout | Garage answers non-2xx and stores nothing; the role run that started Garage succeeded (GS-BR-16) |
| GS-E-32 [New 0.5] | `garage_secrets_dir` lies in a subvolume that a `btrbk_sources` path or a snapper config covers | Fail before any change, naming the path and the covering source or config (GS-FR-134) |

### Acceptance Criteria

Scenario GS-AC-01 [V] [Amended 0.3]: btrfs check passes (GS-FR-01)
- Given `/mnt/data` and `/mnt/containers` are mounted btrfs on the VM
- When the role runs
- Then `findmnt -no FSTYPE /mnt/data` and `findmnt -no FSTYPE /mnt/containers` each print `btrfs` and the run continues past the check

Scenario GS-AC-02 [V] [Amended 0.3]: Both Garage paths are subvolumes (GS-FR-02)
- Given `/mnt/data/garage` and `/mnt/containers/garage/meta` did not exist
- When the role runs
- Then `btrfs subvolume show /mnt/data/garage` and `btrfs subvolume show /mnt/containers/garage/meta` each exit 0
- And `btrfs subvolume list -o /mnt/data` lists a path ending in `garage`, and `btrfs subvolume list -o /mnt/containers` lists a path ending in `garage/meta`

Scenario Outline GS-AC-03 [V] [Amended 0.5]: Owners and modes (GS-FR-03, GS-FR-04, GS-FR-106, GS-FR-107, GS-FR-132)
- When the role has run
- Then `stat -c '%a %U:%G' <path>` prints <expected>
- And `/mnt/data/garage/meta` does not exist

| path | expected | FR |
|---|---|---|
| `/mnt/data/garage` | `700 root:root` | GS-FR-04 |
| `/mnt/data/garage/data` | `700 garage:garage` | GS-FR-106 |
| `/mnt/containers/garage/meta` | `700 garage:garage` | GS-FR-107 |
| `/var/lib/garage/secrets` (`garage_secrets_dir`) | `750 root:garage` | GS-FR-132 |

Scenario GS-AC-04 [V] [Amended 0.7]: The `/mnt/data` and `/mnt/containers` snapshots exclude the store (GS-BR-03, GS-F-03)
- Given the store holds at least one object, and at least one earlier `btrbk run` has created Garage snapshots
- When btrbk creates `/mnt/data/.btrbk/data.<ts>` and `/mnt/containers/.btrbk/containers.<ts>`
- Then each nested subvolume appears in these snapshots only as an empty stub directory: `data.<ts>/garage`, `containers.<ts>/garage/meta`, and every entry below `data.<ts>/.btrbk-garage` and `containers.<ts>/.btrbk-garage-meta` is an empty directory
- And `find data.<ts>/garage data.<ts>/.btrbk-garage containers.<ts>/garage/meta containers.<ts>/.btrbk-garage-meta -mindepth 1 -not -type d` prints nothing (no `data/` block file and no metadata file below any stub)
- And `.btrbk-garage` and `.btrbk-garage-meta` themselves are empty only on the first run, before any Garage snapshot exists; later they hold one empty stub per Garage snapshot
- And no file named `rpc_secret` or `admin_token` exists anywhere in `containers.<ts>` (GS-BR-14)

Scenario GS-AC-05 [V] [H] [Amended 0.3]: Samba unchanged (GS-FR-44)
- Given the output of `smbclient -L //<nas> -N` before the apply
- When the apply has run
- Then `smbclient -L //<nas> -N` prints the same share list, and no share is named `garage`
- And no `path =` line in `testparm -s` is at or below `/mnt/data/garage` or `/mnt/data/.btrbk-garage`

Scenario GS-AC-06 [Deleted 1.1]: Layout applied by the role; the layout is a README step (GS-FR-139), exercised by GS-AC-07.

Scenario GS-AC-07 [V] [Amended 1.1]: README steps make the service usable (GS-FR-137, GS-FR-139, GS-FR-34)
- Given a fresh store after a successful role run, and `garage status` shows the node with "NO ROLE ASSIGNED"
- When the README layout steps run, then a bucket `sstate` and a key `test-rw` with read and write on it are created with the Garage CLI
- Then `garage status` shows the node with a role
- And a 1 MiB object `selftest/up`, put by a container on `caddy.network` to `http://garage:3900/sstate/` and signed with `test-rw` (path-style, region `garage`), returns 200
- And a signed `HEAD` returns the same size, and a signed `GET` returns the same sha256

Scenario GS-AC-08 [Deleted 1.1]: `mirror-read` key; user-owned (GS-CC-40).

Scenario GS-AC-09 [Deleted 1.1]: Read-only key refused a write; user-owned keys and grants (GS-CC-40).

Scenario GS-AC-10 [V] [H] [Amended 0.5]: Anonymous read on the web route, bare-Host mapping, the key K defined in the scenario and the production URL (GS-FR-30, GS-FR-31, GS-FR-93, GS-A-15, GS-A-16)
- Given an object `selftest/up` with sha256 S in `sstate`, and an object with the key K = `ab/cd/sstate:pn-foo:x86_64:1.0+git-r0:0123abcd_populate_sysroot.tar.zst` and sha256 R, both uploaded with `test-rw` by the test setup (GS-FR-68)
- When a container on `caddy.network` runs `curl -s -H 'Host: sstate' http://garage:3902/selftest/up` [V]
- Then the status is 200 and the sha256 is S
- And `GET /<K>` with `Host: sstate` on `garage:3902` returns 200 with sha256 R
- And `GET /selftest/missing` with `Host: sstate` returns 404
- And [V] unsigned `GET /sstate/<K>` through the route test Caddy returns 200 with sha256 R, both with `:` and `+` literal and with them percent-encoded (`%3A`, `%2B`)
- And [H] from a LAN host, `curl -s -o /dev/null -w '%{http_code}' 'https://s3.de.int.wahlberger.dev/sstate/<K>'` prints `200` after K is uploaded there

Scenario GS-AC-11 [V] [Amended 0.5]: Garage ports unreachable from outside the container network (GS-FR-13, GS-FR-23, GS-FR-108, GS-FR-109, GS-FR-111)
- Given `garage.service` is active
- When a host on the VM's network runs `nc -z -w 3 <VM IP> <port>` for 3900, 3901, 3902 and 3903
- Then each exits non-zero
- And on the VM, `ss -ltnH '( sport >= :3900 and sport <= :3903 )'` in the host namespace prints nothing
- And from a container on `caddy.network`, `nc -z -w 3 garage 3900` and `nc -z -w 3 garage 3902` exit 0, while `garage 3901` and `garage 3903` exit non-zero

Scenario GS-AC-12 [V]: Idempotent (all FRs)
- Given a completed apply
- When `ansible-playbook -i inventories/vm site.yml --tags garage,caddy,btrbk` runs again
- Then the recap shows `changed=0`
- And a following `--check --diff` run shows no diff

Scenario GS-AC-13 [S]: Static checks (GS-FR-11, GS-FR-62)
- When `yamllint .`, `ansible-lint` (production profile), `ansible-playbook site.yml --syntax-check` and `tests/render-check.sh` run
- Then each exits 0

Scenario Outline GS-AC-14 [V] [Amended 0.3]: Refusal on a non-btrfs mount (GS-FR-01, GS-E-01)
- Given <overrides> point at a mounted tmpfs `/mnt/garage-test`
- When the role runs
- Then it fails with a message naming `/mnt/garage-test` and `tmpfs`
- And no path below `/mnt/garage-test` was created
- And `/etc/containers/systemd/garage.container` does not exist

| overrides |
|---|
| `garage_mount_path: /mnt/garage-test` |
| `garage_meta_mount_path: /mnt/garage-test`, `garage_config_dir: /mnt/garage-test/garage` |

Scenario GS-AC-15 [V] [Amended 0.3]: Existing subvolumes reused (GS-FR-02)
- Given the store exists with object `selftest/up`, the data subvolume has Subvolume ID N and the metadata subvolume has Subvolume ID M
- When the role runs again
- Then `btrfs subvolume show /mnt/data/garage` reports Subvolume ID N and `btrfs subvolume show /mnt/containers/garage/meta` reports Subvolume ID M
- And `selftest/up` is still readable

Scenario Outline GS-AC-16 [V] [Amended 0.3]: Plain directory refused (GS-FR-09, GS-BR-02, GS-E-02)
- Given <path> is a plain directory containing `keep.txt` with sha256 K
- When the role runs
- Then it fails with a message that names <path> and says it is not a btrfs subvolume
- And `keep.txt` still has sha256 K
- And neither `garage.container` nor any file in `garage_secrets_dir` exists

| path |
|---|
| `/mnt/data/garage` |
| `/mnt/containers/garage/meta` |

Scenario GS-AC-17 [V]: Runtime account (GS-FR-05, GS-FR-83)
- When `garage.service` is active
- Then `podman top garage huser` prints the UID from `id -u garage`, which is not 0
- And `getent passwd garage` shows a UID below 1000 and the shell `/usr/sbin/nologin`

Scenario GS-AC-18 [V] [Amended 0.3]: No_COW on an empty metadata subvolume (GS-FR-06)
- Given the metadata subvolume is created empty by the role
- Then `lsattr -d /mnt/containers/garage/meta` shows the `C` flag

Scenario GS-AC-19 [V] [Amended 0.3]: Non-empty metadata subvolume left unchanged (GS-FR-06)
- Given `/mnt/containers/garage/meta` contains files and has no `C` flag
- When the role runs
- Then the output of `lsattr -d /mnt/containers/garage/meta` is the same as before the run

Scenario GS-AC-20 [V] [Amended 0.3]: Store replicated by btrbk into sibling snapshot directories (GS-FR-70, GS-FR-71, GS-FR-72, GS-FR-75, GS-FR-78, GS-FR-90, GS-FR-91)
- Given `garage_enabled` and `backup_disk_enabled` are true and `sstate` holds an object
- When the btrbk role runs (its guard passes) and `btrbk run` completes
- Then `/mnt/data/.btrbk-garage/garage.<ts>` and `/mnt/containers/.btrbk-garage-meta/garage-meta.<ts>` exist with the same `<ts>` (GS-A-17)
- And `/mnt/backup/btrbk/garage/garage.<ts>` and `/mnt/backup/btrbk/garage-meta/garage-meta.<ts>` exist
- And the received `garage.<ts>` contains `data/`, and the received `garage-meta.<ts>` lists the same top-level entries as `/mnt/containers/.btrbk-garage-meta/garage-meta.<ts>`
- And `/mnt/data/garage/.btrbk` and `/mnt/containers/garage/meta/.btrbk` do not exist
- And `stat -c '%a %U:%G'` prints `700 root:root` for `/mnt/data/.btrbk-garage` and `/mnt/containers/.btrbk-garage-meta`

Scenario Outline GS-AC-21 [V] [Amended 0.3]: btrbk refuses an absent Garage subvolume (GS-FR-76, GS-BR-04, GS-E-15)
- Given `btrbk_sources` contains <source> and <path> does not exist
- When the btrbk role runs
- Then it fails before any change with a message naming <path>
- And <path> still does not exist

| source | path |
|---|---|
| `garage` | `/mnt/data/garage` |
| `garage-meta` | `/mnt/containers/garage/meta` |

Scenario GS-AC-22 [V] [Amended 0.5]: Secret files are accepted by Garage (GS-FR-20, GS-FR-133, GS-A-03, GS-A-24)
- When the role has run
- Then `stat -c '%a %U:%G'` prints `400 garage:garage` for `<garage_secrets_dir>/rpc_secret` and `<garage_secrets_dir>/admin_token`
- And `find /mnt/containers/garage /mnt/data/garage \( -name rpc_secret -o -name admin_token \)` prints nothing
- And `garage.service` is active

Scenario GS-AC-23 [V]: Secrets absent from run output (GS-FR-21)
- Given the VM fixture secret values (GS-FR-65)
- When `ansible-playbook -i inventories/vm site.yml --tags garage -vvv` runs, on a fresh store and again on a store with user-made buckets and keys
- Then no fixture secret value appears in the Ansible output
- And `journalctl -u garage.service` contains no fixture secret value

Scenario GS-AC-24 [S]: Secrets absent from rendered files (GS-FR-11, GS-FR-12)
- When `tests/render-check.sh` renders `garage.toml` and `garage.container` with the fixture
- Then neither file contains a fixture secret value (GS-FR-65)
- And `garage.toml` contains `rpc_secret_file` and `admin_token_file`, and no line matches `^\s*(rpc_secret|admin_token)\s*=`

Scenario Outline GS-AC-25 [V] [Amended 1.2]: Invalid input refused before any change (GS-E-04, GS-FR-21, GS-FR-135, GS-FR-141)
- Given <input> is set to <value>
- When the role runs
- Then it fails before any change with a message naming <input>
- And the message contains no secret value
- And when the run uses `-vvv`, the whole output, including the assert result's `assertion` field, contains no fixture secret value (GS-FR-21 exception, GS-CC-39)

| input | value |
|---|---|
| `vault_garage_rpc_secret` | empty |
| `vault_garage_rpc_secret` | 63 hex characters |
| `vault_garage_admin_token` | 31 characters |
| `garage_s3_domain` | `s3.example.org` |
| `garage_s3_domain` | empty (GS-FR-135) |
| `garage_meta_path` | `/mnt/data/garage-meta` |

Scenario GS-AC-26 [Deleted 1.1]: Key secret mismatch; no role-managed keys (GS-CC-40).

Scenario GS-AC-27 [Deleted 1.1]: Staged layout refused; no role-run layout (GS-CC-40).

Scenario GS-AC-28 [Deleted 1.1]: Quota and website flag converge; user-owned (GS-CC-40).

Scenario GS-AC-29 [Deleted 1.1]: Quota reached; user-owned (GS-CC-40).

Scenario GS-AC-30 [V] [Amended 0.3]: Unsigned write refused on the S3 host (GS-FR-36, GS-E-13)
- Given object `selftest/up` with sha256 S in `sstate`, and the route test Caddy
- When unsigned `PUT`, `POST` and `DELETE` requests to `http://caddy-route-test:8080/sstate/selftest/up` run
- Then each status is non-2xx
- And `selftest/up` still has sha256 S

Scenario GS-AC-31 [V] [Amended 0.3]: No listing on the S3 host (GS-FR-37, GS-A-16)
- Given `sstate` has no `index.html`, and the route test Caddy
- When unsigned `GET /sstate/` and `GET /sstate` run against `http://caddy-route-test:8080`
- Then `GET /sstate/` returns 404 and `GET /sstate` returns a non-2xx status
- And neither response body contains `selftest/`

Scenario GS-AC-32 [H] [Amended 0.3]: Upload through the API route (GS-FR-50, GS-FR-51)
- Given a 1 GiB file
- When a LAN host puts it to `https://s3.de.int.wahlberger.dev/sstate/selftest/<timestamp>`, signed with a key Erik created with write access to that bucket (path-style, region `garage`)
- Then the response is 200
- And a signed `DELETE` of the same key returns 204

Scenario GS-AC-33 [H] [Amended 0.3]: DNS record and certificate name (GS-FR-35, GS-FR-45, GS-BR-05)
- When `dig +short s3.de.int.wahlberger.dev @1.1.1.1` runs
- Then the answer is `nas.de.int.wahlberger.dev.` followed by `10.10.0.100`
- And `dig +short sstate.s3.de.int.wahlberger.dev @1.1.1.1` prints nothing
- And `openssl s_client -connect s3.de.int.wahlberger.dev:443 -servername s3.de.int.wahlberger.dev </dev/null | openssl x509 -noout -ext subjectAltName` lists only `DNS:s3.de.int.wahlberger.dev`
- And every `community.general.cloudflare_dns` task in the repository sets `proxied: false`

Scenario GS-AC-34 [H] [Amended 0.3]: Garage down (GS-E-12)
- Given `garage.service` is stopped
- When a LAN host requests `https://s3.de.int.wahlberger.dev/sstate/<known object>`
- Then the status is 502
- And after `systemctl start garage.service` the same request returns 200 within 60 s

Scenario GS-AC-35 [V] [Amended 0.9]: Ready within 60 s, config read from the declared path (GS-FR-29, GS-FR-136, GS-NFR-05, GS-A-29)
- When `systemctl restart garage.service` runs
- Then `podman exec garage /garage status` exits 0 within 60 s, polled every 2 s
- And because the image has no `/etc/garage.toml` (its default path, spike T-02), the exit 0 shows that the server and the CLI read `<garage_config_dir>/garage.toml` (GS-FR-136)

Scenario GS-AC-36 [V]: Healthcheck (GS-FR-16, GS-FR-80)
- Given `garage.service` is active
- Then `podman healthcheck run garage` exits 0
- And `podman inspect garage` shows a healthcheck command containing `/garage status`

Scenario GS-AC-37 [V]: Unit wiring (GS-FR-17, GS-FR-81, GS-FR-82)
- When `systemctl show garage.service -p OnFailure -p Restart -p RequiresMountsFor` runs
- Then it prints `OnFailure=notify-failure@garage.service.service` and `Restart=always`
- And `RequiresMountsFor` lists `/mnt/data` and `/mnt/containers/garage`
- And `systemctl show -p Wants default.target` contains `garage.service`

Scenario GS-AC-38 [S] [Amended 0.9]: Render-check asserts (GS-FR-136, GS-FR-07, GS-FR-08, GS-FR-11, GS-FR-13, GS-FR-19, GS-FR-22, GS-FR-23, GS-FR-38, GS-FR-62, GS-FR-65, GS-FR-73, GS-FR-108, GS-FR-109, GS-FR-111, GS-FR-121, GS-FR-122)
- When `tests/render-check.sh` runs `40-garage.yml`
- Then `garage.container` matches:
  - `^ContainerName=garage$`, `^Network=caddy\.network$` (exactly one `Network=` line);
  - `^User=<fixture uid>$`, `^HealthCmd=/garage status$`, `^HealthOnFailure=kill$`;
  - `^OnFailure=notify-failure@%n\.service$`, `^Restart=always$`;
  - `Volume=` lines for `/mnt/data/garage/data` and `/mnt/containers/garage/meta` ending in `:Z`, and for `garage.toml` and `<garage_secrets_dir>` containing `ro`;
  - exactly four `Volume=` lines;
  - `^Environment=GARAGE_CONFIG_FILE=<garage_config_dir>/garage\.toml$` (GS-FR-136);
  - no `PublishPort=`, no `SecurityLabelDisable`, no `Volume=/mnt/data/garage:`, no `Volume=/mnt/containers/garage:` and no `Volume=` line containing `.btrbk`
- And `garage.toml` matches:
  - `replication_factor = 1`;
  - `rpc_bind_addr = "127.0.0.1:3901"`, `rpc_public_addr = "127.0.0.1:3901"`;
  - `api_bind_addr = "0.0.0.0:3900"`, `bind_addr = "0.0.0.0:3902"`, `api_bind_addr = "127.0.0.1:3903"`;
  - `metadata_dir = "/mnt/containers/garage/meta"`, `data_dir = "/mnt/data/garage/data"`;
  - `rpc_secret_file` and `admin_token_file` pointing below `<garage_secrets_dir>`;
  - exactly one `root_domain` line: `root_domain = "s3.example.test"` (fixture domain, no leading dot) under `[s3_web]`; none under `[s3_api]` (GS-FR-38);
  - no `metadata_snapshots_dir` line and no `metadata_auto_snapshot_interval` line (GS-FR-08);
  - no `[k2v_api]`
- And in the render-check container, `/usr/libexec/podman/quadlet -dryrun` on the rendered `garage.container` exits 0, and the generated `garage.service` passes `systemd-analyze verify` (GS-CC-36, GS-A-30; [V] fallback through GS-AC-37 if the generator cannot run there)

Scenario GS-AC-39 [S]: Role order and gate (GS-FR-60, GS-BR-10)
- When `tests/static-checks.sh` runs its role-order check
- Then `garage` has tag `garage` and `when: garage_enabled | bool`
- And it comes after `caddy` and before `btrbk`

Scenario GS-AC-40 [V] [Amended 0.5]: Disabled flag is a no-op (GS-FR-61, GS-FR-126, GS-FR-128, GS-FR-129)
- Given `garage_enabled: false`
- When `site.yml` runs
- Then no `garage` task reports changed
- And `/mnt/data/garage`, `/mnt/containers/garage/meta` and `garage.container` do not exist
- And `btrbk_sources`, `backup_disk_freshness_checks` and `caddy_sites` contain no Garage entry
- And after the next `btrbk.service` run, `systemctl show btrbk.service -p Result -p ExecMainStatus` prints `Result=success` and `ExecMainStatus=0`

Scenario GS-AC-41 [S]: Molecule exclusion (GS-FR-63)
- Then `molecule/default/converge.yml` does not contain `garage`
- And the molecule exclusion note in `CLAUDE.md` names `garage`

Scenario GS-AC-42 [S]: Argument specs (GS-FR-64)
- Then every `garage_*` variable in the Inputs table is declared in `roles/garage/meta/argument_specs.yml`
- And `ansible-lint` passes

Scenario GS-AC-43 [V]: Backup gate (GS-FR-67, GS-E-20)
- Given `garage_enabled: true` and `backup_disk_enabled: false`
- When the role runs
- Then it fails before any change, naming both flags

Scenario GS-AC-44 [S] [Amended 1.1]: Image pinned and Renovate-detectable (GS-FR-10, GS-FR-18)
- When the `garage_image` line is matched against the custom-manager regex in `renovate.json`
- Then it matches with depName `docker.io/dxflrs/garage` and currentValue `v2.4.1`

Scenario GS-AC-45 [S] [V] [Amended 0.3]: Backup freshness (GS-FR-74, GS-NFR-06)
- Given `garage_enabled: true`
- Then production `backup_disk_freshness_checks` contains `{path: /mnt/backup/btrbk/garage, max_age_hours: 26}` and `{path: /mnt/backup/btrbk/garage-meta, max_age_hours: 26}`
- And [V] after a btrbk run, `backup-disk-health.service` completes with exit 0

Scenario GS-AC-46 [V]: Check mode on a fresh host (GS-FR-85, GS-E-21)
- Given `garage_enabled: true` and no `garage.service` on the VM
- When `ansible-playbook -i inventories/vm site.yml --check --tags garage` runs
- Then it exits 0 and the readiness wait is reported as skipped

Scenario GS-AC-47 [H] [Amended 1.2]: Size gate on `/mnt/data` (GS-NFR-02, GS-FR-120)
- Given `df -B1 --output=size,used /mnt/data` gives S and U
- When the values are recorded before `garage_enabled` is set to true in production
- Then U <= 0.85 × S
- And no bucket quota enters the check

Scenario GS-AC-48 [S] [Amended 0.5]: Caddy site for Garage (GS-FR-32, GS-FR-51, GS-FR-93, GS-FR-94, GS-FR-95, GS-FR-112, GS-FR-113)
- When `Caddyfile.j2` is rendered with the production `caddy_sites` and `garage_enabled: true`
- Then exactly one site address equals `s3.de.int.wahlberger.dev`, and no site address ends in `.s3.de.int.wahlberger.dev`
- And that site block equals the O-6 fragment (whitespace aside)
- And it contains no `request_body`

Scenario GS-AC-49 [S]: Firewall variables unchanged (GS-FR-41)
- Then `firewall_allowed_services`, `firewall_allowed_ports` and `firewall_rich_rules` in the role defaults and production `vars.yml` are byte-identical to `master` before this feature

Scenario GS-AC-50 [S] [Amended 1.1]: Documentation (GS-FR-34, GS-FR-66, GS-FR-77, GS-FR-84, GS-FR-139, GS-FR-140)
- Then `roles/garage/README.md` contains:
  - the S3 settings and the `SSTATE_MIRRORS` line with `https://s3.de.int.wahlberger.dev/<bucket>/PATH` from GS-FR-34;
  - the layout steps from GS-FR-139 (`garage status`, `layout assign`, `layout apply`, verify), with the note that capacity is a placement weight and that `500GB` and `500GiB` differ;
  - the user steps from GS-FR-140 (bucket, key, grant, website access, quota recommendation, lifecycle);
  - the restore steps from GS-FR-77, including "same `<ts>`" and "re-render the secrets from Vault";
  - the recorded image user
- And `vault.yml.example` lists `vault_garage_rpc_secret` and `vault_garage_admin_token` with a generation command, and no other `vault_garage_*` variable

Scenario GS-AC-51 [H] [Amended 1.2]: Backup-disk size observed at day 30 (GS-NFR-04)
- When `btrfs filesystem du -s /mnt/backup/btrbk/garage /mnt/backup/btrbk/garage-meta` runs 30 days after enabling
- Then the sum over both lines of Exclusive + Set shared is recorded in the role README with the date
- And no limit is checked (observation only; GS-NFR-03 is the backstop)

Scenario GS-AC-65 [H] [Amended 1.2]: Backup-disk size observed again at day 120 (GS-NFR-04)
- Given 120 days have passed since enabling, so deleted objects now exist only in older backup snapshots
- When `btrfs filesystem du -s /mnt/backup/btrbk/garage /mnt/backup/btrbk/garage-meta` runs 120 days after enabling
- Then the sum over both lines of Exclusive + Set shared is recorded in the role README next to the day-30 value
- And no limit is checked (observation only; GS-NFR-03 is the backstop)

Scenario Outline GS-AC-52 [V] [Amended 0.5]: Routing of the S3 host (GS-FR-30, GS-FR-93, GS-FR-94, GS-BR-09, GS-E-24, GS-E-25, GS-A-16)
- Given object `selftest/up` with sha256 S and size Z in `sstate`, object `obj` in `private-test`, both from the test setup (GS-FR-68), the key K = `ab/cd/sstate:pn-foo:x86_64:1.0+git-r0:0123abcd_populate_sysroot.tar.zst` (sstate naming) with test content of sha256 R, and the route test Caddy
- When <request> is sent to `http://caddy-route-test:8080`
- Then the result is <expected>

| request | expected |
|---|---|
| unsigned `GET /sstate/selftest/up` | 200, sha256 S (web route) |
| unsigned `HEAD /sstate/selftest/up` | 200, `Content-Length` Z (web route) |
| unsigned `GET /sstate/selftest/missing` | 404 |
| unsigned `GET /nope/x` | 404 |
| unsigned `GET /private-test/obj` | 404 (no website access) |
| `GET /sstate?list-type=2` signed with `test-rw` | 200, body contains `<ListBucketResult` and `selftest/up` (API route; `Host` unchanged, so the signature is valid) |
| `PUT /sstate/selftest/route` signed with `test-rw` | 200 |
| `PUT /sstate/<K>` signed with `test-rw` | 200 (API route; the signature covers the `:` and `+` characters of K) |
| `GET /sstate/<K>` signed with `test-rw` | 200, sha256 R (API route) |
| presigned `GET /private-test/obj` (`test-rw`, query `X-Amz-Signature`) | 200 (API route) |
| unsigned `GET /` | non-2xx (API route) |

Scenario Outline GS-AC-53 [V] [New 0.3]: Invalid per-source snapshot_dir refused (GS-FR-92, GS-E-22)
- Given the `btrbk_sources` entry `garage` has `snapshot_dir` <value>
- When the btrbk role runs
- Then it fails before any change, naming `garage` and <value>
- And `/etc/btrbk/btrbk.conf` is unchanged

| value |
|---|
| `.btrbk-garage` (relative) |
| `/mnt/data/samba/Delat/.btrbk-garage` |
| `/mnt/data/garage/.snap` (inside the source) |
| `/mnt/containers/.btrbk-garage` (other mount) |

Scenario GS-AC-54 [S] [New 0.3]: btrbk configuration with the Garage sources (GS-FR-70, GS-FR-78, GS-FR-79, GS-FR-90, GS-A-18)
- Given `btrbk_sources` = the role defaults plus the entries of GS-FR-78 and GS-FR-70, in this order
- When `tests/render-check.sh` renders `btrbk.conf.j2` and runs `btrbk config print`
- Then it exits 0
- And the printed configuration places `garage-meta` snapshots in `/mnt/containers/.btrbk-garage-meta` and `garage` snapshots in `/mnt/data/.btrbk-garage`, with targets `/mnt/backup/btrbk/garage-meta` and `/mnt/backup/btrbk/garage`
- And the `garage-meta` section comes before the `garage` section
- And the `data` and `containers` sections still pass the existing `20-btrbk.yml` asserts (`snapshot_dir .btrbk`)

Scenario GS-AC-55 [V] [Amended 0.7]: Restore from one run's snapshot pair (GS-FR-77, GS-BR-11, GS-BR-14, GS-A-27, GS-R-03)
- Given object `selftest/up` with sha256 S was stored before a completed `btrbk run` with snapshots `garage.<ts>` and `garage-meta.<ts>`, the run took place while a client uploaded objects to `sstate` without pause (live LMDB, GS-A-27), `selftest/up` was deleted afterwards, and `garage_secrets_dir` was emptied to simulate a lost host
- When the README restore steps run with that `<ts>`, including the secret re-render from Vault
- Then the secret files are present again with the modes of GS-AC-22
- And `garage status` exits 0 within 60 s of the start
- And `selftest/up` reads back with sha256 S
- And `podman exec garage /garage block list-errors` exits 0 and prints only the header line `Hash  RC  Errors  Last error  Next try`, no rows (syntax and output from spike T-02)

Scenario GS-AC-56 [V] [New 0.3]: Skew between the two snapshots (GS-E-26, GS-A-19, GS-R-01)
- Given object A in `sstate`
- When a read-only snapshot of `/mnt/containers/garage/meta` is taken, then object B is uploaded and object A is deleted, then a read-only snapshot of `/mnt/data/garage` is taken within 10 s of the first, and the store is restored from these two snapshots
- Then `garage.service` starts and `garage status` exits 0
- And A reads back with its original sha256
- And a `GET` of B returns 404

Scenario GS-AC-57 [S] [Amended 0.5]: `caddy` role `body` rendering (GS-FR-95, GS-FR-96, GS-FR-130)
- Given `caddy_sites` with the Garage entry (`body`) and the existing production entries without `body`
- When `Caddyfile.j2` is rendered
- Then the S3 host block contains the O-6 body and no `reverse_proxy` line other than the two in the body
- And the blocks of the other entries are byte-identical to their rendering by the template on `master` before this feature

Scenario Outline GS-AC-58 [V] [New 0.3]: Invalid `caddy_sites` entry refused (GS-FR-97, GS-E-23)
- Given `caddy_sites` contains <entry>
- When the `caddy` role runs
- Then it fails before any change, naming `a.example.test`
- And the deployed `Caddyfile` is unchanged

| entry |
|---|
| `{host: a.example.test, body: "respond 200", upstream: "x:1"}` |
| `{host: a.example.test, body: "respond 200", extra: "encode gzip"}` |
| `{host: a.example.test}` |

Scenario Outline GS-AC-59 [S] [Amended 0.5]: Garage entries in production vars follow the flag (GS-FR-32, GS-FR-70, GS-FR-74, GS-FR-78, GS-FR-79, GS-FR-126, GS-FR-127, GS-FR-128, GS-FR-129)
- Given production `vars.yml` evaluated with `garage_enabled` = <flag>
- Then <expected>

| flag | expected |
|---|---|
| true | `btrbk_sources` contains `garage-meta` before `garage`, with the keys of GS-FR-78 and GS-FR-70; `backup_disk_freshness_checks` contains both Garage targets; `caddy_sites` contains the S3 host entry |
| false | none of the three lists contains a Garage entry, and the remaining entries equal those on `master` before this feature |

- And in both rows, the `data` and `containers` entries of `btrbk_sources` equal `roles/btrbk/defaults/main.yml`, and `roles/btrbk/defaults/main.yml` is byte-identical to `master` before this feature (GS-FR-127)

Scenario GS-AC-60 [Deleted 1.1]: Lifecycle or retention by the role; user-owned (GS-CC-40).

Scenario GS-AC-61 [Deleted 1.1]: Lifecycle or retention by the role; user-owned (GS-CC-40).

Scenario GS-AC-62 [Deleted 1.1]: Lifecycle or retention by the role; user-owned (GS-CC-40).

Scenario GS-AC-63 [Deleted 1.1]: Lifecycle or retention by the role; user-owned (GS-CC-40).

Scenario GS-AC-64 [Deleted 1.1]: Lifecycle or retention by the role; user-owned (GS-CC-40).

Scenario GS-AC-66 [S] [New 0.5]: Cross-feature update merged before enabling (GS-FR-110, GS-FR-117)
- Given the change that sets production `garage_enabled: true`
- Then `reqs/backup-btrbk-and-db-dump.md` contains requirements for the per-source `mount_path` checked with `btrfs subvolume show` and for the per-source `snapshot_dir`
- And `reqs/index.md` lists the new version of that file
- And that update was merged before the change

Scenario GS-AC-67 [V] [New 0.5]: Secrets are in no snapshot (GS-FR-134, GS-BR-14, GS-NFR-09)
- Given the role has run and `garage_secrets_dir` holds `rpc_secret` and `admin_token`
- When `btrbk run` completes and `snapper -c <config> create` runs for every config listed by `snapper list-configs`
- Then `findmnt -no FSROOT -T /var/lib/garage/secrets` prints `/@/var` (GS-F-22)
- And `btrfs inspect-internal rootid /var/lib/garage/secrets` differs from the root ID of every `btrbk_sources` path and of every snapper config subvolume
- And `find` over every snapper `.snapshots` directory, every btrbk snapshot directory and `/mnt/backup/btrbk` finds no file named `rpc_secret` or `admin_token`

Scenario Outline GS-AC-68 [V] [New 0.5]: Secrets directory inside a snapshotted subvolume refused (GS-FR-134, GS-E-32)
- Given `garage_secrets_dir` is set to <path>
- When the role runs
- Then it fails before any change, naming <path> and <covering>
- And <path> does not exist afterwards

| path | covering |
|---|---|
| `/mnt/containers/garage/secrets` | snapper config `containers` and btrbk source `containers` |
| `/mnt/data/garage-secrets` | snapper config `data` and btrbk source `data` |

Scenario GS-AC-69 [S] [Amended 1.1]: Enable preconditions recorded (GS-FR-115 to GS-FR-118, GS-FR-120)
- Given the change that sets production `garage_enabled: true`
- When Erik reviews it
- Then its description links the merged `btrbk` role change, the merged `caddy` role change and the GS-AC-66 update
- And it records the pass results of GS-AC-55 and GS-AC-56 and the GS-AC-47 values
- And the production `vault.yml` defines every `vault_garage_*` variable of the Inputs table with a non-empty value, checked without printing values (for example `ansible ... -m ansible.builtin.assert -a "that=vault_garage_rpc_secret | length > 0"` per variable)

Scenario GS-AC-70 [V] [Amended 1.1]: Test setup uses only the CLI (GS-FR-68)
- When the test setup has run
- Then `garage bucket list` shows `sstate` and `private-test`, `garage bucket info sstate` shows website access enabled and `garage key info test-rw` shows read and write on both buckets
- And no file in `inventories/vm/` and no role variable defines a bucket, key or grant

Scenario GS-AC-71 [V] [New 0.7]: Restart after a kill (GS-FR-17, GS-FR-80)
- Given `garage.service` is active and `systemctl show garage.service -p NRestarts` prints N
- When `podman kill garage` runs (the same action `HealthOnFailure=kill` takes on an unhealthy container)
- Then `systemctl show garage.service -p NRestarts` prints N + 1 within 30 s
- And `podman exec garage /garage status` exits 0 within 60 s of the kill
- Note: the unhealthy-to-kill step itself is checked by inspection (`HealthOnFailure=kill` in GS-AC-38, healthcheck command in GS-AC-36), because a deterministic `/garage status` failure cannot be injected without changing the image

Scenario GS-AC-72 [V] [New 0.7]: Readiness wait times out (GS-FR-29, GS-E-05)
- Given `garage_ready_timeout_sec: 10` and `garage_image` overridden to a pinned image that has no `/garage` binary, so `podman exec garage /garage status` never exits 0
- When the role runs
- Then it fails at the readiness wait within 10 s plus one poll interval, with a message naming `garage_ready_timeout_sec`
- And the readiness wait is the failed task

Scenario GS-AC-73 [V] [New 1.1]: The role leaves user-owned state unchanged (GS-BR-15, GS-FR-138)
- Given the test setup has run, and the user has also set a 10 MiB quota on `private-test` and a lifecycle rule on `sstate`
- And the outputs of `garage layout show`, `garage bucket info sstate`, `garage bucket info private-test` and `garage key info test-rw` are saved
- When `ansible-playbook -i inventories/vm site.yml --tags garage` runs
- Then the recap shows `changed=0`
- And the four outputs are identical to the saved ones, and `GetBucketLifecycleConfiguration` on `sstate` returns the user's rule

Scenario GS-AC-74 [S] [New 1.1]: No state-changing Garage command in the role (GS-FR-138)
- When `roles/garage/tasks/` and `roles/garage/templates/` are searched
- Then no file contains `layout assign`, `layout apply`, `bucket create`, `bucket allow`, `bucket deny`, `bucket website`, `set-quotas`, `key create`, `key import` or a lifecycle API call
- And the only `/garage` subcommand in the tasks is `status`

Scenario GS-AC-75 [V] [New 1.1]: Garage runs without a layout after the role (GS-BR-16, GS-FR-29, GS-E-33)
- Given a fresh store
- When the role has run
- Then the run succeeded and `podman exec garage /garage status` exits 0 and lists the node with "NO ROLE ASSIGNED"
- And a signed `PUT` through `http://garage:3900` returns a non-2xx status before the README layout steps run

Scenario GS-AC-76 [V] [New 1.2]: A failing btrfs command stops the role (GS-E-03)
- Given `/mnt/data/garage` does not exist and `/mnt/data` is remounted read-only (`mount -o remount,ro /mnt/data`)
- When the role runs
- Then it fails at the `btrfs subvolume create` task, and its output shows the command's stderr (`Read-only file system`)
- And `/etc/containers/systemd/garage.container` does not exist and `garage.service` is not active
- And after `mount -o remount,rw /mnt/data` the next role run succeeds

### Non-Functional Requirements

- GS-NFR-01 [Deleted 1.1]: `sstate` quota; user-owned. The README recommends 500 GiB (GS-FR-140).
- GS-NFR-02 [Amended 1.2] (Erik's decision 2026-10-18): Before `garage_enabled` is set to true in production, used bytes of `/mnt/data` <= 85 % of its size (`disk_space_threshold_percent`). This is the only size gate; no quota figure enters it. After enabling, the `disk_space` alert (GS-NFR-03) is the backstop.
- GS-NFR-03 [Amended 0.3]: `/mnt/data`, `/mnt/containers` and `/mnt/backup/btrbk` stay in `disk_space_paths` with `disk_space_threshold_percent: 85` and `disk_space_check_interval: 15min`, so a crossing is emailed within 15 min.
- GS-NFR-04 [Amended 1.2] (Erik's decision 2026-10-18): Observation, not a gate. 30 and 120 days after enabling, the size of the Garage replicas in `/mnt/backup/btrbk/garage` and `/mnt/backup/btrbk/garage-meta` (sum of Exclusive + Set shared of both) is measured and recorded in the role README (GS-AC-51, GS-AC-65). There is no size limit for them; the 85 % `disk_space` alert on `/mnt/backup/btrbk` (GS-NFR-03) is the backstop.
- GS-NFR-05: After `garage.service` starts, `garage status` exits 0 within 60 s.
- GS-NFR-06 [Amended 0.3]: The newest snapshot in each of `/mnt/backup/btrbk/garage` and `/mnt/backup/btrbk/garage-meta` is younger than 26 h.
- GS-NFR-07 [Deleted 1.1]: Expiry bound; retention is user-owned (GS-CC-40).
- GS-NFR-08 [Deleted 1.1]: Quota bound; quotas are user-owned (GS-CC-40).
- GS-NFR-09 [New 0.5] (GS-Q-15 closed): Garage secret files exist only in Vault and in `garage_secrets_dir` on the NAS: zero copies in btrbk snapshots, snapper snapshots or on the backup disk (GS-BR-14, GS-AC-67).
- No throughput or latency NFR. The mirror affects only build time, BitBake builds from source when the mirror is slow or unreachable (GS-A-11), and throughput is bounded by the HDD and the LAN/ZeroTier link.

### Verification

| Requirement | Method | Evidence |
|---|---|---|
| GS-FR-01 | test [V] | GS-AC-01, GS-AC-14 |
| GS-FR-02 | test [V] | GS-AC-02, GS-AC-15 |
| GS-FR-03, GS-FR-04, GS-FR-106, GS-FR-107, GS-FR-132 | test [V] | GS-AC-03 |
| GS-FR-05, GS-FR-83 | test [V] | GS-AC-17 |
| GS-FR-06 | test [V] | GS-AC-18, GS-AC-19 |
| GS-FR-07, GS-FR-08, GS-FR-11, GS-FR-38 | inspection [S] (render check) | GS-AC-38, GS-AC-13 |
| GS-FR-09, GS-BR-02 | test [V] | GS-AC-16 |
| GS-FR-10, GS-FR-18 | inspection [S] | GS-AC-44 |
| GS-FR-12, GS-FR-20, GS-FR-133 | test [S] [V] | GS-AC-24, GS-AC-22 |
| GS-FR-134, GS-BR-14, GS-NFR-09, GS-E-32 | test [V] | GS-AC-67, GS-AC-68, GS-AC-04 |
| GS-FR-13, GS-FR-22, GS-FR-23, GS-FR-108, GS-FR-109, GS-FR-111 | test [S] [V] | GS-AC-38, GS-AC-11 |
| GS-FR-16, GS-FR-80 | test [S] [V] | GS-AC-36, GS-AC-38, GS-AC-71 |
| GS-FR-17, GS-FR-81, GS-FR-82 | test [V] | GS-AC-37, GS-AC-71 |
| GS-FR-19, GS-FR-73, GS-FR-121, GS-FR-122 | inspection [S] | GS-AC-38 |
| GS-FR-21 | test [V] | GS-AC-23, GS-AC-25 |
| GS-FR-29 | test [V] | GS-AC-35, GS-AC-72, GS-AC-75 |
| GS-FR-136 | test [S] [V] | GS-AC-38, GS-AC-35 |
| GS-FR-135 | test [V] | GS-AC-25 |
| GS-FR-137 | demonstration [V] (README steps on a fresh store) | GS-AC-07 |
| GS-FR-139 | inspection [S], demonstration [V] | GS-AC-50, GS-AC-07 |
| GS-FR-141 | test [V] | GS-AC-25 |
| GS-E-03 | test [V] | GS-AC-76 |
| GS-FR-138, GS-BR-15 | test [V], inspection [S] | GS-AC-73, GS-AC-74 |
| GS-BR-16, GS-E-33 | test [V] | GS-AC-75 |
| GS-FR-30, GS-FR-31 | test [V], smoke [H] | GS-AC-10, GS-AC-52 |
| GS-FR-32, GS-FR-112, GS-FR-113 | inspection [S] | GS-AC-48, GS-AC-59 |
| GS-FR-93, GS-FR-94 | test [V] (route test Caddy), inspection [S] | GS-AC-52, GS-AC-10, GS-AC-48 |
| GS-FR-34, GS-FR-66, GS-FR-77, GS-FR-84, GS-FR-140 | inspection [S] | GS-AC-50 |
| GS-FR-35, GS-FR-45, GS-FR-114, GS-BR-05 | demonstration [H], inspection [S] | GS-AC-33 |
| GS-FR-36, GS-FR-37, GS-BR-09 | test [V] (route test Caddy) | GS-AC-30, GS-AC-31, GS-AC-52 |
| GS-FR-41 | inspection [S] | GS-AC-49 |
| GS-FR-44 | test [V], smoke [H] | GS-AC-05 |
| GS-FR-50, GS-FR-51 | demonstration [H], inspection [S] | GS-AC-32, GS-AC-48 |
| GS-FR-60, GS-BR-10 | inspection [S] | GS-AC-39 |
| GS-FR-61 | test [V] | GS-AC-40 |
| GS-FR-110, GS-FR-117 | inspection [S] (before enabling) | GS-AC-66 |
| GS-FR-115, GS-FR-116, GS-FR-118, GS-FR-120 | inspection (Erik, before enabling) | GS-AC-69 |
| GS-FR-62, GS-FR-65 | test [S] | GS-AC-38, GS-AC-24 |
| GS-FR-63 | inspection [S] | GS-AC-41 |
| GS-FR-64 | inspection [S] | GS-AC-42 |
| GS-FR-67 | test [V] | GS-AC-43 |
| GS-FR-68 | test [V] | GS-AC-70 |
| GS-FR-70, GS-FR-78, GS-FR-79, GS-FR-126, GS-FR-127, GS-FR-128, GS-FR-129 | inspection [S] | GS-AC-59, GS-AC-54 |
| GS-FR-71, GS-FR-72, GS-FR-75, GS-FR-90, GS-FR-91, GS-BR-03 | test [V], inspection [S] | GS-AC-20, GS-AC-04, GS-AC-54 |
| GS-FR-74, GS-NFR-06 | inspection [S], test [V] | GS-AC-45, GS-AC-59 |
| GS-FR-76, GS-BR-04 | test [V] | GS-AC-21 |
| GS-FR-92 | test [V] | GS-AC-53 |
| GS-FR-85 | test [V] | GS-AC-46 |
| GS-FR-95, GS-FR-96, GS-FR-130 | inspection [S] | GS-AC-57, GS-AC-48 |
| GS-FR-97 | test [V] | GS-AC-58 |
| GS-BR-08 | inspection (Erik, before netcup configuration) | GS-P-01 record in `zerotier-flow-rules.md` |
| GS-BR-11, GS-A-27 (GS-R-03) | demonstration [V] (manual, once before enabling) | GS-AC-55 |
| GS-E-26 (GS-R-01, GS-A-19) | demonstration [V] (manual, once before enabling) | GS-AC-56 |
| GS-NFR-02 | analysis [H] (before enabling) | GS-AC-47 |
| GS-NFR-03 | inspection [S] | `disk_space_paths` in `vars.yml` |
| GS-NFR-04 | observation [H] (day 30, day 120; recorded, not gated) | GS-AC-51, GS-AC-65 |
| GS-NFR-05 | test [V] | GS-AC-35 |
| IDs marked [Deleted 1.1] | none (out of scope, GS-CC-40) | — |

### Out of Scope

- Multi-node Garage and replication factor above 1 - Won't (single NAS).
- [New 1.1] Node layout, buckets, access keys, grants, quotas, website access and lifecycle rules - user-owned (Erik's decision 2026-10-18, GS-CC-40): done with the Garage CLI or an S3 client; the README documents the steps (GS-FR-139, GS-FR-140). This includes sstate retention (the retired 90-day rule, GS-Q-08), the 500 GiB `sstate` quota (a README recommendation), the lifecycle worker cycle, lifecycle permissions, the quota command and quota enforcement (former GS-A-20 to GS-A-22 and GS-A-28; evidence in `tests/spikes/garage-v2.4.1-cli-config.md`), and Garage's partial lifecycle support (GS-F-21).
- Garage admin UI or any exposure of the admin API beyond the container's loopback - Won't in this feature.
- K2V API - Won't (no consumer).
- Virtual-host (bucket-as-hostname) addressing and per-bucket DNS records - Won't (decision A, 2026-10-17).
- An alert at a percentage of a bucket quota - not in this feature; `disk_space` covers the filesystems (GS-NFR-03), and Garage rejects an upload beyond a user-set quota with a non-2xx S3 error.
- Per-source btrbk retention for the Garage sources - Won't; the shared role-wide retention is kept (GS-Q-07 closed).
- An atomic snapshot of data and metadata - not possible across two btrfs filesystems; the skew is the accepted risk GS-R-01.
- Consumer configuration in other repositories (meta-sluss `local.conf`, the netcup `forgejo_runner` role) - deferred to those repositories. This feature documents the settings only (GS-FR-34).
- ZeroTier Central rules - external precondition GS-P-01, edited by hand by Erik.
- A snapper config for either Garage subvolume - not needed because btrbk covers the backup (GS-BR-03).
- Restic backup of the store - not needed because the NAS has no restic client (GS-F-02) and btrbk covers it.
- An automated, recurring restore drill - deferred; GS-AC-55 runs the documented steps once on [V] (GS-FR-77).
- The mount of `/dev/sdb1` at `/mnt/data/samba/Delat/Bilder/immich/library` inside the Samba share (GS-F-20) - not this feature; for Erik to review.
- Changes to the ops, cloud or netcup playbooks and to the Pi.

### Risks

| ID | Risk | Reasoning and mitigation | Verification | Owner | Status |
|---|---|---|---|---|---|
| GS-R-01 [New 0.4, was GS-Q-14] | The `garage-meta` and `garage` snapshots of one btrbk run are taken seconds apart, not atomically (two btrfs filesystems). | Garage writes data blocks before metadata references them. With the metadata snapshot taken first (GS-FR-79), an upload in the window leaves only unreferenced blocks in the data snapshot; the only exposure is a block deleted in the window, and Garage delays block deletion (GS-A-19). Restores use one run's pair only (GS-BR-11) | GS-AC-55 and GS-AC-56 on [V], once before enabling (GS-FR-118) | Erik | Accepted 2026-10-17 |
| GS-R-02 [New 0.5] | Garage secrets are in no backup (GS-Q-15 decision): a restore of Garage depends on access to Vault, that is the vault password in the 1Password item `Ansible Vault - nas-de-int-wahlberger-dev`. | The values are needed only to re-render two files; Vault and 1Password are outside the NAS, so losing the NAS loses no secret. The restore steps re-render the secrets from Vault (GS-FR-77) | GS-AC-55 (restore with an emptied `garage_secrets_dir`) | Erik | Accepted with the GS-Q-15 decision, 2026-10-17 |
| GS-R-03 [New 0.7] | The metadata snapshot is taken from a live LMDB database with `metadata_fsync` = `false`; a restore could need a Garage repair or lose the last metadata writes. | A btrfs snapshot is a point-in-time copy of the subvolume, and LMDB commits by switching a meta page after writing its pages, so a point-in-time copy shows the last committed state (GS-A-27, to verify). If GS-AC-55 shows a repair need, the README restore steps add the repair command, or the metadata snapshot is taken with Garage stopped | GS-AC-55 on [V] with the snapshot taken under upload load, once before enabling (GS-FR-118) | Erik | Accepted (editorial addition after the final audit, 2026-10-17) |

### Open Questions

None. All questions are resolved; see the table below.

#### Resolved questions (kept for traceability, not open)

| ID | Question (short) | Answer (Erik, 2026-10-17) |
|---|---|---|
| GS-Q-01 | `/mnt/data` btrfs check, disk layout, host key | Host key verified against the existing `known_hosts` entry (GS-F-13). `/mnt/data` btrfs on the HDD (GS-F-14), `/mnt/containers` btrfs on the NVMe (GS-F-15), root SSD 224G (GS-F-16) |
| GS-Q-02 | `garage_s3_domain` | `s3.de.int.wahlberger.dev`; buckets are path segments; mirror URL `https://s3.de.int.wahlberger.dev/sstate/PATH` (GS-CC-13) |
| GS-Q-03 | Write path | W1: S3 API only through Caddy, nothing published |
| GS-Q-04 | Public DNS names | Accepted: one public record `s3.de.int.wahlberger.dev` from `cloudflare_dns`. Bucket names are in paths only, not in DNS or certificate logs; the hostname itself is public in CT logs (GS-BR-05) |
| GS-Q-05 | btrbk wiring | (a) Garage sources only in production `vars.yml`, only while `garage_enabled` is true; (b) btrbk role change approved: per-source `mount_path` with `btrfs subvolume show` (GS-FR-75, GS-FR-76) and per-source `snapshot_dir` (GS-FR-90 to GS-FR-92) (GS-CC-20) |
| GS-Q-06 | btrbk snapshot_dir for the store | Siblings outside the store: `/mnt/data/.btrbk-garage` and `/mnt/containers/.btrbk-garage-meta` (GS-FR-72, GS-CC-19) |
| GS-Q-07 [Superseded by GS-CC-40 in 1.1 for (a) and (b), by GS-CC-41 in 1.2 for (c)] | Size budget | (a) `sstate` quota 500 GiB; (b) `garage_layout_capacity` stays a required input without default (placement weight); (c) 1 TiB on the backup disk for both Garage targets; (d) shared 3-year retention kept. No HDD limit beyond GS-NFR-02 |
| GS-Q-09 | netcup ZeroTier IP and flow rule | IP `10.243.73.1` (GS-F-17). The flow rule stays the external precondition GS-P-01, owner Erik |
| GS-Q-10 | 1Password item for `vault_garage_*` | No new item: existing `vault.yml`, encrypted with the 1Password item `Ansible Vault - nas-de-int-wahlberger-dev` (vault `DevOps`) (GS-P-03) |
| GS-Q-11 | Metadata placement | NVMe: own subvolume `/mnt/containers/garage/meta`, No_COW kept (GS-CC-17) |
| GS-Q-12 | Container runtime UID | Dedicated system account `garage` (GS-FR-05, GS-FR-83) |
| GS-Q-08 [Closed 0.4] [Retired 1.1] | sstate retention or garbage collection | Retired: retention is user-owned (GS-CC-40). The 0.4 decision (90 days, `bucket-admin` lifecycle rule) no longer applies; the README describes how a user sets a lifecycle rule (GS-FR-140) |
| GS-Q-13 [Closed 0.4] | Approve the `caddy` role change (`caddy_sites[].body`) | Approved (GS-FR-95 to GS-FR-97, GS-CC-25) |
| GS-Q-14 [Closed 0.4] | Snapshot skew between `garage-meta` and `garage` | Accepted as risk GS-R-01: metadata snapshot first, VM drill GS-AC-55 and GS-AC-56 kept |
| GS-Q-15 [Closed 0.5] | The Garage secret files under `/mnt/containers/garage` are in the `containers` btrbk and snapper snapshots. Accept, or move them out? | Option 2: move them to `/etc/garage/secrets/` (`root:garage`, files per GS-FR-20), a path that no btrbk or snapper source covers, with a run-time guard and an AC (GS-FR-132 to GS-FR-134, GS-AC-67). Secrets exist only in Vault and on the host; a restore re-renders them from Vault (GS-BR-14, GS-R-02). The path was then changed by GS-Q-16 |
| GS-Q-16 [New 0.5] [Closed 0.6] | Location of `garage_secrets_dir`: `/etc/garage/secrets` lies in the root subvolume, which the installer's snapper config `root` snapshots (`roles/snapper/defaults/main.yml`: `snapper_preexisting_configs: [root]`) | `/var/lib/garage/secrets` (option 2). Erik checked on the NAS: `/var/lib` is in the separate subvolume `/@/var`, not covered by the `root` config (GS-F-22). The run-time guard GS-FR-134 and GS-AC-67/68 stay |

### Assumptions

- GS-A-01 [Amended 0.8]: The Garage configuration keys were checked in 0.1 against the configuration reference. `[s3_web] root_domain`: verified by spike T-03 (`tests/spikes/garage-caddy-routing.md`, section Result): Garage v2.4.1 refuses to start without it ("missing field `root_domain`"), so it is set to `<garage_s3_domain>` without a leading dot (GS-FR-38, GS-AC-38). Still to verify before writing the template, because T-03 did not cover it: `[s3_api] advertise_path_style` (omit it if the v2.4.1 reference lacks it).
- GS-A-02 [Amended 1.1]: The Garage v2.4.1 CLI syntax used in the README steps (`status`, `layout assign/apply/show`, `bucket create/info/website/allow`, `key create/info`) is to be checked against `podman exec garage /garage <cmd> --help` and the T-02 spike note when the README is written. The role itself runs only `garage status`. `block list-errors` is verified in spike T-02 (GS-FR-77).
- GS-A-03: Garage refuses to start when a secret file has any group or other permission bit, unless `allow_world_readable_secrets` is set. For that reason the files are owned by `garage_user` with mode `0400`, not `root:<gid> 0440`. To verify on v2.4.1 (GS-AC-22).
- GS-A-04 [Amended 0.3]: Caddy's `reverse_proxy` passes the client `Host` header to the upstream unchanged by default. The API route relies on it for SigV4 signatures; the web route overrides it with `header_up Host`.
- GS-A-05: btrfs snapshots do not include nested subvolumes (verified, GS-F-03).
- GS-A-06: `metadata_fsync` and `data_fsync` keep Garage's defaults (`false`); the data can be rebuilt from source.
- GS-A-07 [Deleted 1.1]: The role imports no key (GS-CC-40).
- GS-A-08: Every container on `caddy.network` can reach `garage:3900` (signature required) and `garage:3902` (the same anonymous read as any LAN client). Accepted.
- GS-A-09: Layout capacity is a placement weight between nodes, not a storage limit; bucket quotas are the limit. To verify.
- GS-A-10 [Amended 1.2]: `rpc_bind_addr` and `rpc_public_addr` of `127.0.0.1:3901` are enough for one node and for the CLI through `podman exec`, following the pattern of the Garage quick-start (single node, local RPC address). Verified in spike T-02 (`tests/spikes/garage-v2.4.1-cli-config.md`, "GS-A-10 RPC on loopback"); GS-AC-07 keeps checking it.
- GS-A-11: BitBake builds a task from source when the sstate mirror is unreachable or returns an error (standard `SSTATE_MIRRORS` behaviour).
- GS-A-12: sstate object keys contain the task hash, so concurrent uploads of the same key carry identical content.
- GS-A-13: Playbook runs against the NAS do not overlap (manual runs and Semaphore runs are not concurrent).
- GS-A-14: netavark DNS on `caddy.network` resolves `garage` for Caddy, as it does for `tandoor` and `forgejo`.
- GS-A-15 [Amended 0.8]: Garage v2.4.1's s3_web endpoint serves bucket `<b>` for a request whose `Host` header equals `<b>`, a global bucket alias. Verified by spike T-03 (`tests/spikes/garage-caddy-routing.md`): with `root_domain = "s3.de.int.wahlberger.dev"` a bare `Host: sstate` maps to bucket `sstate`, because the host does not end in the root domain and resolves as a global alias; the mapping is verified only with `root_domain` set (GS-FR-38). GS-AC-10 [V] keeps checking it.
- GS-A-16 [New 0.3]: The O-6 fragment behaves as follows in Caddy 2 (`localhost/caddy-cloudflare:2`), to verify with the route test Caddy (GS-AC-52, GS-AC-31): (a) `handle @web` is evaluated before the matcher-less `handle`, and only one of them runs; (b) inside `handle @web`, `rewrite` runs before `reverse_proxy`; (c) `header !Authorization` matches only requests without that header; (d) `query X-Amz-Signature=*` matches any value of that parameter; (e) `{re.bucket.1}` and `{re.bucket.2}` keep the `@web` captures after the `rewrite`; (f) for `GET /<bucket>` (empty second capture) the response is non-2xx.
- GS-A-17 [New 0.3]: btrbk creates the snapshots of one run in the order of the `volume` sections in `btrbk.conf`, and all snapshots of one run carry the same `<ts>` suffix (`timestamp_format long`). To verify with `btrbk dryrun` and GS-AC-20. If either does not hold, GS-FR-77, GS-FR-79 and GS-BR-11 are amended before implementation.
- GS-A-18 [New 0.3]: `btrbk.conf` accepts `snapshot_dir` as a path relative to the volume directory or as an absolute path (btrbk.conf(5)). To verify with `btrbk config print` in the render check (GS-AC-54). If an absolute path outside the volume is refused, the template renders the source's parent as `volume` and the source as `subvolume` (for example `volume /mnt/data`, `subvolume garage`, `snapshot_dir .btrbk-garage`), which gives the same snapshot paths.
- GS-A-19 [New 0.3]: Garage removes a block file only after a delay once its last reference is gone, not within the seconds between the two snapshots of one run. A `garage-meta` snapshot taken first therefore never references a block that the following `garage` snapshot lacks; an object uploaded in between leaves only unreferenced blocks. To verify (GS-AC-56, GS-R-01).
- GS-A-20 [Moved to Out of Scope 1.1]: concerns user-owned buckets (lifecycle worker, lifecycle permissions, quota command or quota enforcement); evidence stays in `tests/spikes/garage-v2.4.1-cli-config.md` for the README (GS-FR-140).
- GS-A-21 [Moved to Out of Scope 1.1]: concerns user-owned buckets (lifecycle worker, lifecycle permissions, quota command or quota enforcement); evidence stays in `tests/spikes/garage-v2.4.1-cli-config.md` for the README (GS-FR-140).
- GS-A-22 [Moved to Out of Scope 1.1]: concerns user-owned buckets (lifecycle worker, lifecycle permissions, quota command or quota enforcement); evidence stays in `tests/spikes/garage-v2.4.1-cli-config.md` for the README (GS-FR-140).
- GS-A-23 [New 0.5]: S3 clients (BitBake's fetcher, the upload tool) send the `:` and `+` of sstate keys either literally or percent-encoded, and Caddy's `path_regexp`/`rewrite` and the API route pass both forms to Garage so that the object is found and SigV4 signatures stay valid. To verify with the key K defined in GS-AC-10 and GS-AC-52.
- GS-A-24 [New 0.5]: With SELinux enforcing, Garage can read `garage.toml` and `garage_secrets_dir` bind-mounted `:ro` without a relabel option. To verify on [V] (GS-AC-22: `garage.service` active). If it cannot, the secrets mount gets `:ro,Z`, which relabels only that directory, and GS-FR-121 and GS-AC-38 are amended in the same change.
- GS-A-25 [New 0.5]: Garage keeps its node key in `metadata_dir`, so the `garage-meta` backup carries it and a restore keeps the node identity. To verify on v2.4.1 (GS-AC-55).
- GS-A-27 [New 0.7]: A btrbk snapshot of the metadata subvolume taken while Garage runs (live LMDB, `metadata_fsync` = `false`, GS-A-06) is crash-consistent and restores cleanly: Garage starts on it without manual repair. To verify with GS-AC-55, whose snapshot is taken under upload load (risk GS-R-03).
- GS-A-28 [Moved to Out of Scope 1.1]: concerns user-owned buckets (lifecycle worker, lifecycle permissions, quota command or quota enforcement); evidence stays in `tests/spikes/garage-v2.4.1-cli-config.md` for the README (GS-FR-140).
- GS-A-29 [New 0.9]: Garage v2.4.1 reads its configuration path from the environment variable `GARAGE_CONFIG_FILE`, for `server` and for every CLI subcommand. Not confirmed by the v2.4.1 documentation and not covered by spike T-02 (`tests/spikes/garage-v2.4.1-cli-config.md` records the default `/etc/garage.toml` and the entrypoint `/garage server` only). To verify with `/garage --help` in the image and GS-AC-35 on [V]; fallback in GS-FR-136.
- GS-A-30 [New 0.9]: The render-check container (`docker.io/opensuse/tumbleweed`) can install Podman and run `/usr/libexec/podman/quadlet -dryrun` on a single rendered `.container` file without a running Podman service. To verify when the GS-AC-38 generator check is added; fallback in GS-CC-36.
- GS-A-26 [Deleted 1.1]: Lifecycle client image; the role has no lifecycle client (GS-CC-40). Spike T-02 used `docker.io/amazon/aws-cli:2.38.1`, which [V] tests may use as their S3 client.

### Change log

- 1.2 (2026-10-18): cleanup after the re-audit of 1.1 (READY with gaps), GS-CC-41: superseded and historical tags on stale contract entries (G1), GS-FR-141 for input formats (G4), GS-A-10 and the quota Out of Scope entry repointed (G5), GS-AC-76 for GS-E-03 and GS-AC-50 for GS-FR-139 (G6), `block list-errors` pinned from spike T-02 (G7), ambiguous terms replaced. Erik's decisions applied: GS-NFR-04 observe-only (no 1 TiB gate) and GS-FR-120/GS-NFR-02/GS-AC-47 without a quota figure. Quality metadata refreshed with the requirements engineer's self-score (Atomic 3: compound FRs such as GS-FR-02, GS-FR-09 and GS-FR-92 remain).
- 1.1 (2026-10-18): Erik's scope change and clarification (GS-CC-40): Ansible sets up only the Garage service; everything the Garage or S3 CLI can do (node layout, buckets, keys, grants, quotas, website access, lifecycle) is user-owned and documented in the README (GS-FR-139, GS-FR-140). Removed IDs are marked [Deleted 1.1]; GS-Q-08 retired; GS-A-20 to GS-A-22 and GS-A-28 moved to Out of Scope; new GS-FR-137 to GS-FR-140, GS-BR-15, GS-BR-16, GS-E-33, GS-AC-73 to GS-AC-75; [V] test setup replaces the role-managed fixture (GS-FR-68, GS-AC-70); Verification table rebuilt. Consequence recorded: Garage runs without a layout until the user runs the README steps (GS-BR-16). Status kept `ready`; the quality scores date from 0.7.
- 1.0 (2026-10-18): GS-CC-39 (T-07): GS-FR-21 gains the approved exception for assert-only input checks (untemplated conditions, static messages that name the variable, `quiet: true`, no `no_log`), proven by GS-AC-25 at `-vvv` and GS-AC-23. Status stays `ready`.
- 0.9 (2026-10-18): three points from task T-01 (roles/garage skeleton), recorded as GS-CC-36 to GS-CC-38: Quadlet generator dry-run check in GS-AC-38 with a [V] fallback (GS-A-30); config path GS-FR-136 via `GARAGE_CONFIG_FILE`, to verify (GS-A-29), command-line argument as fallback; preflight non-empty check GS-FR-135 for `garage_layout_capacity` and `garage_s3_domain` (argument spec `required: false`), two new GS-AC-25 rows. Status stays `ready`.
- 0.8 (2026-10-18): spike T-03 result (GS-CC-35): `[s3_web] root_domain` is required and set to `garage_s3_domain` without a leading dot (GS-FR-38, O-1, GS-AC-38); GS-A-01 (root_domain part) and GS-A-15 marked verified. `[s3_api] advertise_path_style` in GS-A-01 stays to verify (not covered by T-03). Status stays `ready`; no other changes.
- 0.7 (2026-10-17): editorial pass after the final requirements-auditor verdict (READY, 0 blocking; pillars 4,4,3,4,4,5,4,5). No decision changed (GS-CC-34). GS-AC-04 asserts empty stub directories and no file below them (`.btrbk-garage*` are empty only on the first run); GS-FR-110 names BD-FR-51 and the Inputs and Outputs rows; GS-A-27 and GS-R-03 (live LMDB snapshot, GS-AC-55 under upload load); GS-NFR-04 post-day-120 bound; GS-NFR-08 qualified, GS-A-28; GS-FR-77 [Must]; GS-AC-40 and GS-AC-64 wording; lifecycle credentials through the environment only (GS-FR-133, GS-AC-67 simplified); GS-AC-70 (fixture), GS-AC-71 (restart after kill), GS-AC-72 (readiness timeout); GS-AC-69 also checks `garage_layout_capacity` and the `vault_garage_*` entries. Compound FRs that remain (Atomic 3) are not split, by the coordinator's instruction. Status set to `ready`; quality metadata recorded.
- 0.6 (2026-10-17): GS-Q-16 closed: `garage_secrets_dir` defaults to `/var/lib/garage/secrets`; fact GS-F-22 (`/var/lib` is in `/@/var`) recorded; guard GS-FR-134 and GS-AC-67/68 kept, GS-AC-03 and GS-AC-67 updated for the path (GS-CC-33). The 0.5 choices "to confirm" are decided: mode `0750` `root:garage`, the `caddy_sites` conditional (GS-FR-129) and aws-cli (GS-A-26). Open Questions are empty; `status` stays `draft` until the requirements-auditor re-audit.
- 0.5 (2026-10-17): requirements-auditor re-audit of 0.4 (verdict READY, 33/40, weakest pillar Atomic) and Erik's decision on GS-Q-15. Contract changes GS-CC-29 to GS-CC-32; GS-CC-07 amended. `status` stays `draft`.
  - Atomicity: compound FRs split into one outcome per ID (GS-CC-29); the Verification table is remapped to the new IDs.
  - `garage_s3_client_image` added as an input (GS-FR-124, GS-FR-131, GS-AC-44, GS-AC-60).
  - Production list composition with a Jinja conditional on `garage_enabled` (GS-FR-126 to GS-FR-129, GS-AC-59).
  - Realistic sstate key in GS-AC-10 (web route) and GS-AC-52 (API route), GS-A-23.
  - GS-NFR-04 is a day-30 bound, re-measured at day 120 (GS-AC-65 [H]).
  - Cross-feature task GS-FR-110 (update backup-btrbk-and-db-dump.md) and enable precondition GS-FR-117 (GS-AC-66).
  - GS-AC-38 asserts that `metadata_snapshots_dir` and `metadata_auto_snapshot_interval` are absent.
  - GS-FR-74 and GS-FR-67 raised to [Must]; "proposed default, Erik may change it" replaced by "default (decided)"; GS-FR-95 uses the GS-AC-48 comparison wording.
  - GS-Q-15 raised as a blocking question by the coordinator, then closed by Erik with option 2: secrets in `/etc/garage/secrets/`, outside every btrbk and snapper source (GS-CC-31, GS-FR-20, GS-FR-121, GS-FR-132 to GS-FR-134, GS-BR-14, GS-NFR-09, GS-R-02, GS-E-32, GS-AC-67, GS-AC-68); the restore re-renders the secrets from Vault (GS-FR-77, GS-AC-55).
  - New blocking GS-Q-16: the decided path is in the root subvolume that the `root` snapper config snapshots (repo fact in `roles/snapper/defaults/main.yml`).
  - Choices made by the requirements engineer, to confirm: `garage_secrets_dir` mode `0750` (Erik gave owner `root:garage` only); `caddy_sites` composed with the same conditional pattern (GS-FR-129); aws-cli as the client image (GS-A-26); the enable checklist GS-AC-69.
- 0.4 (2026-10-17): Erik's decisions of 2026-10-17 on the 0.3 choices and on retention. Contract changes GS-CC-25 to GS-CC-28; GS-CC-11 and GS-CC-15 amended.
  - GS-Q-13 closed: the `caddy` role change `caddy_sites[].body` is approved; the no-role-change fallback text is dropped.
  - Confirmed: presigned requests take the API route; the Garage `caddy_sites` entry and freshness checks follow `garage_enabled`; `GET /<bucket>` returns non-2xx.
  - GS-Q-14 closed and moved to the new Risks section as GS-R-01 (accepted), with Erik's reasoning; GS-FR-79 (metadata snapshot first) raised to [Must]; the GS-AC-55 and GS-AC-56 drill is kept and gates enabling (GS-FR-61).
  - GS-Q-08 closed as decided: lifecycle expiration (GS-FR-100 to GS-FR-105, GS-BR-12, GS-BR-13, GS-NFR-07, GS-NFR-08, GS-E-28 to GS-E-31, GS-AC-60 to GS-AC-64, GS-F-21, GS-A-20, GS-A-21); new `bucket-admin` key and `owner` grant flag; fixture bucket `expire-test`.
  - The quota command syntax became its own non-blocking check GS-A-22.
  - Choices made by the requirements engineer, to confirm: `bucket-admin` gets `owner` only, without `read` or `write` (least privilege, GS-A-21 fallback); the lifecycle calls go to `garage:3900` on `caddy.network` so they work on [V] without a certificate (GS-FR-104); the expiration demonstration GS-AC-61 (<= 48 h on [V]) is one of the enable preconditions in GS-FR-61.
  - Open Questions are empty; `status` stays `draft` until the requirements-auditor re-audit.
- 0.3 (2026-10-17): Erik's final decisions A to I of 2026-10-17: one S3 host with buckets as path segments (A); metadata on the NVMe in its own subvolume (B); sibling snapshot directories (C); btrbk declaration and btrbk role changes approved (D); sizes (E); NAS facts and host key (F); W1 and the netcup IP (G); dedicated `garage` account (H); secrets in the existing vault (I). Contract changes GS-CC-13 to GS-CC-24; GS-CC-02, GS-CC-06, GS-CC-11 and GS-CC-12 amended. Closed GS-Q-01 to GS-Q-07 and GS-Q-09 to GS-Q-12 (moved to "Resolved questions"); new GS-Q-13 (blocking) and GS-Q-14 (not blocking); GS-Q-08 stays open. New facts GS-F-13 to GS-F-20, assumptions GS-A-15 to GS-A-19, FRs GS-FR-38, GS-FR-68, GS-FR-78, GS-FR-79, GS-FR-90 to GS-FR-97, GS-BR-11, GS-E-22 to GS-E-27, scenarios GS-AC-52 to GS-AC-59. Choices made by the requirements engineer, to confirm:
  - `caddy` role form: a new optional key `caddy_sites[].body` rather than a new role variable; GS-Q-13 lists the fallback without a role change;
  - presigned requests (`X-Amz-Signature` query parameter) take the API route, read as "signed requests" in decision A;
  - `garage-meta` is snapshotted before `garage` in a run (GS-FR-79), the default mitigation of GS-Q-14;
  - the btrbk per-source keys are `mount_path` (the 0.2 proposal for GS-Q-05 b) and `snapshot_dir`; a per-source `snapshot_dir` inside its source is refused (GS-FR-92);
  - the Garage `caddy_sites` entry and the Garage freshness checks follow `garage_enabled`, like the btrbk sources (GS-FR-32, GS-FR-74);
  - `GET /<bucket>` without a trailing slash is required to be non-2xx rather than 404, because the empty second capture of the decided regexp is unverified (GS-FR-37, GS-A-16 f);
  - removed the unused W2/W3 inputs (GS-CC-21);
  - named the fixture buckets `quota-test` and `private-test` (GS-FR-68);
  - GS-AC-14, GS-AC-16 and GS-AC-21 became scenario outlines over both Garage paths.
- 0.2 (2026-10-17): refactor after a requirements-auditor NOT READY verdict and the owner decisions of 2026-10-17 (read path option B with one host per bucket; back up the store). All contract changes are listed under GS-CC-01 to GS-CC-12. Changes made without asking (to confirm):
  - converted to the rubric layout: Actors, Inputs, Outputs, Error Cases, NFRs, Verification and Open Questions as a table;
  - added a MoSCoW label to every FR; document priority `should`;
  - split the compound FRs: 0.1 GS-FR-11/12/13/15/17 became GS-FR-11, -12, -13, -14, -15, -16, -17, -20 to -29 and -80 to -85;
  - GS-FR-18 (a duplicate of GS-FR-10) now covers Renovate detection;
  - GS-FR-42 and GS-FR-46 merged into GS-FR-41;
  - the duplicate of GS-FR-06 in the old section 9 (items 7 and 8) became the single question GS-Q-11;
  - GS-BR-02 (an assert about an exclusion that btrbk has no setting for) became a real subvolume rule;
  - the wording of GS-AC-05 is fixed;
  - corrected repo facts GS-F-04, GS-F-05 and GS-F-08, which contradict 0.1.
- 0.1: first draft.
