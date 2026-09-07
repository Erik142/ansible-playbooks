# immich

[Immich](https://immich.app/) self-hosted photo/video backup: Valkey +
PostgreSQL (with the vectorchord vector-search extension) + a machine-learning
service + the app itself, each a separate Podman Quadlet on a private
`immich` network, with the app additionally joined to the shared
`caddy.network` and reverse-proxied by the `caddy` role. Logs in via the
Pocket ID instance at `pocket_id_app_url` (served by cloud-wahlberger-dev).

Not exposed publicly: like every other service on this NAS, `immich_url`
resolves to a private LAN IP (see `roles/cloudflare_dns/README.md`) — reach
it over the ZeroTier overlay or the home LAN, including from the mobile app
while away from home.

## Role variables

See `defaults/main.yml` for the full list with inline documentation. The
required ones (no usable default) are `immich_url` and
`immich_oidc_client_id` — set them in `group_vars`, and provide
`vault_immich_db_password` and `vault_immich_oidc_client_secret` in Ansible
Vault.

## Register the OIDC client in Pocket ID

Create an OIDC client in the Pocket ID dashboard:

- Redirect URIs: `{{ immich_url }}/auth/login`, `{{ immich_url }}/user-settings`,
  and `app.immich:///oauth-callback` (required for the mobile app).
- Logout callback URL: `{{ immich_url }}/auth/login`. **Not**
  `{{ immich_url }}/api/oauth/backchannel-logout`, despite Immich's own
  [OAuth docs](https://immich.app/docs/administration/oauth) suggesting a
  "Backchannel logout URL" there — Pocket ID has no true (server-to-server)
  backchannel logout. Its "Logout callback URL" is the OIDC
  `post_logout_redirect_uri`: purely where your *browser* lands after
  Pocket ID ends your session (confirmed in Pocket ID's own source,
  `end_session_service.go`: "returns the client's post-logout callback
  URL"). Pointing it at Immich's backend-only, POST-only backchannel
  endpoint made the browser GET it on every logout, showing
  `{"message":"Cannot GET /api/oauth/backchannel-logout"}` instead of
  actually landing anywhere.

Then set `immich_oidc_client_id` in group_vars and
`vault_immich_oidc_client_secret` in Vault to the values Pocket ID gives you.

## Why OIDC config lives in a JSON file, not env vars

Unlike mealie/paperless_ngx, Immich doesn't expose OAuth settings as plain
environment variables — they're either set through the Administration
Settings web UI, or declaratively via a config file
(`IMMICH_CONFIG_FILE`, see [docs](https://docs.immich.app/install/config-file)).
This role uses the file so OAuth is fully managed by Ansible/Vault like every
other service here, rather than a manual step in the web UI after first
boot. Only `oauth`, `passwordLogin`, `ffmpeg.accel`, `storageTemplate.enabled`
and `library.watch.enabled` are overridden; everything else keeps Immich's
built-in default and stays editable from the Administration Settings page —
only the overridden fields show there as read-only.

## How Immich organizes files — and per-user folders without a manual step

Every uploaded photo/video lands under `immich_library_root` in one of a
fixed set of subfolders Immich manages itself (`library/`, `thumbs/`,
`encoded-video/`, `profile/`, `upload/`, `backups/` — see
[`enum.ts`](https://github.com/immich-app/immich/blob/main/server/src/enum.ts)'s
`StorageFolder`). Only `library/` holds actual original files meant to be
browsed; the rest are Immich-internal caches.

Within `library/`, Immich **always** nests by user first — `library/<storage
label or, failing that, the user's raw UUID>/...` — regardless of the
storage template, which only controls the path *within* that per-user
folder (`storageTemplate.enabled: true` sets it to
`{{ y }}/{{ y }}-{{ MM }}-{{ dd }}/{{ filename }}`, so e.g.
`library/erikwahlberger/2026/2026-09-07/IMG_1234.jpg`).

The "storage label" needed for a readable folder name (instead of a raw
UUID) is normally a manual per-user admin setting — but `oauth.storageLabelClaim:
"preferred_username"` in `immich-config.json.j2` populates it automatically
from Pocket ID's ID token **at account-creation time** (this only applies
going forward, to accounts that don't exist yet — it can't rename yours
retroactively). After your first OIDC login, check Administration → Users
that your Storage Label actually got set to something sane; if Pocket ID
doesn't populate `preferred_username`, override the claim name here (e.g. to
`email`) and re-run — but this is exactly the kind of thing worth verifying
once rather than assuming.

## No persistent volume for Valkey

Unlike mealie's/paperless_ngx's Redis, `immich-redis` gets no `Volume=` —
matching Immich's own `docker-compose.yml`, which doesn't persist it either.
It only holds transient job-queue/cache state, not anything Immich needs to
survive a restart.

## Hardware acceleration

`immich_hwaccel_enabled` (default `true`) passes `/dev/dri` through to both
`immich-server` (QuickSync video transcoding) and `immich-machine-learning`
(OpenVINO-accelerated face detection/CLIP search), and switches the ML image
to its `-openvino` tag. This was enabled because nas.de.int.wahlberger.dev's
Intel Alder Lake-N iGPU was confirmed present (`/dev/dri`, `ansible_devices`)
in September 2026 — set it to `false` if this host's hardware ever changes,
or if `podman logs immich-machine-learning` shows it failing to find the
device after a first deploy.

## Storage layout

Every other Podman service on this NAS keeps its data under `/mnt/containers`
(the fast NVMe disk) — see the top-level `CLAUDE.md`. Immich's Postgres data
and the machine-learning model cache still do (`immich_data_dir`). The
photo/video library is the deliberate exception, and lives on `/mnt/data`
(the bulk HDD) in two parts:

- **`immich_library_root`** (`/mnt/data/immich-library`) is Immich's entire
  `UPLOAD_LOCATION` — `library/`, `thumbs/`, `encoded-video/`, `profile/`,
  `upload/`, `backups/`. Root-only, and deliberately **not** inside a Samba
  share directly: most of those subfolders are Immich-internal caches, not
  something worth seeing while browsing a share.
- **`immich_library_export_dir`** (`immich_photos_dir/library`, i.e.
  `Delat/Bilder/immich/library` — a plain subfolder of the existing Samba
  share, not a share of its own) is a **bind mount** of just
  `immich_library_root/library` — the actual per-user original files (see
  "How Immich organizes files" above) — so they're browsable over Samba too,
  without exposing Immich's internal folders alongside them.

  Why a bind mount and not a symlink: Samba's default `wide links = no`
  refuses to follow a symlink that leaves the share's own directory tree,
  and `immich_library_root` lives outside the share entirely — enabling
  `wide links` would need loosening a security setting share-wide. A bind
  mount sidesteps that: the kernel presents the exact same files at both
  paths, so as far as smbd is concerned it's already "inside" the share, no
  exception needed. Set up via `ansible.posix.mount` (the same module
  `storage` uses for its btrfs subvolumes) with `fstype: none, opts: bind,ro`,
  persisted in `/etc/fstab` the same way.

  **Read-only, deliberately.** A bind mount replaces the *target*'s
  permissions/ownership with the *source*'s — so it's `immich_library_root/library`'s
  own mode (`0755`, world-readable) that Samba guests actually hit, not
  whatever the export directory's own mode was before the mount landed on
  top of it (an earlier version of this role got this wrong: the source was
  `0750` root-only, leaving Samba guests with zero access at all — no read,
  no browse). And read-only rather than read-write: Immich has no idea this
  path exists (it's the same data reachable a second way, not a registered
  library), so a Samba client editing or deleting a file here would silently
  desync Immich's database from the actual files. Immich itself still has
  full read-write, via its own separate, non-read-only mount of
  `immich_library_root` as `/data` (see `immich-server.container.j2`) — `:ro`
  here only affects Samba clients. Want write access to these files from
  Samba too? Use an `immich_import_users` folder instead (below) — that path
  *is* a registered, rescanned External Library, so external changes there
  are expected and handled correctly.

## Depends on the `samba` role

`immich_photos_dir` defaults to `{{ samba_share_path }}/Bilder/immich` — a
subdirectory of the existing share (`samba_share_path` comes from the
`samba` role's defaults), the same pattern `paperless_ngx_inbox_dir` already
uses for its own subfolder of that same share. Everything Immich-related
(library and import folders alike) lives under this one `Bilder/immich/`
prefix, rather than scattered directly under `Bilder/`. Run `samba` before
this role in `site.yml` (already the case).

## Two different photo folders, two different purposes

- **The library** (browsable at `Bilder/immich/library/<user>/...`) is
  Immich's own managed upload location — where photos land when the mobile
  app or web client uploads them, per-user and storage-template-organized
  automatically (see above). Treat it as Immich's, not a manual drop
  folder — files here get renamed/moved by Immich itself.
- **Import folders** (`Bilder/immich/import/<user>/...`, one per
  `immich_import_users` entry) are plain folders *you* manage directly over
  Samba — copy an old photo archive, scanned photos, whatever, straight in.
  Immich only *reads* them (mounted `:ro`); it never renames, moves, or
  deletes anything there.

Files copied into an import folder are **not** automatically visible in
Immich until it's registered as an External Library — this is a one-time
manual step per user (like registering the OIDC client in Pocket ID above),
because Immich's external libraries are per-user database records with a
fixed owner chosen at creation (can't be changed later), not something the
declarative config file covers:

1. Administration → External Libraries → Create Library, and pick the
   Pocket ID user this one belongs to.
2. Add Library → Import Paths → Add → enter `/mnt/media/import/<user>` (the
   path *inside the container* — see `immich-server.container.j2` — not the
   host path).
3. Click Scan. Everything already there gets indexed within seconds; new
   files added later are picked up automatically too, since
   `library.watch.enabled: true` is set in `immich-config.json.j2` — plus a
   nightly rescan regardless, as a fallback.

**Onboarding another family member later:** add their name to
`immich_import_users`, re-run the playbook (creates their import folder and
mounts it into `immich-server`), have them log in once via Pocket ID (their
Immich account + library folder are created automatically —
`oauth.autoRegister: true`), then repeat the 3 steps above for their import
folder. No role changes needed.

Immich's own docs flag file watching as **experimental** ("can hang in rare
cases, preventing Immich from starting up"). Import folders are plain local
bind-mounted-from-Podman directories (not a network share, from Immich's
point of view), so it should work reliably — but if `immich-server` ever
fails to start after a deploy, set `library.watch.enabled` to `false` in
`immich-config.json.j2` and rely on the nightly scan (or Administration →
External Libraries → Scan) instead.

## SELinux

Only the import folders need the treatment this repo already established
for `paperless_ngx_inbox_dir`: they're guest-writable directories inside a
Samba share, labeled `samba_share_t` by the `samba` role, but Podman's `:Z`
suffix on their volume mounts relabels them `container_file_t` on every
container start. Unlike Paperless-ngx's inbox, this role doesn't fight that
relabeling with `SecurityLabelDisable=true` — it just lets `:Z` win, because
`samba_export_all_rw` (enabled by the `samba` role) already makes smbd
ignore per-file SELinux types on export, so which label wins doesn't matter
functionally. This keeps `immich-server` normally SELinux-confined instead
of running the whole container unconfined for the sake of one volume.

`immich_library_export_dir` needs no SELinux handling at all: being a bind
mount, Samba sees the exact same `container_file_t`-labeled files Immich
itself already wrote (see Storage layout above) — nothing to relabel or
reconcile.

## Backup

`restic_backup` covers Immich the same way it already covers Paperless-ngx:
nightly `pg_dump` of `immich-postgres` into `restic_backup_staging_dir` (the
raw Postgres data directory is excluded — a live filesystem copy isn't
guaranteed restorable). `immich_library_root` and the import folders need no
special handling — they're plain files under `samba_mount_path`, already
covered by `restic_backup_paths`. `immich_library_export_dir` is separately
excluded there, since (being a bind mount of `immich_library_root/library`)
it's the exact same files reachable a second time — backing it up too would
just mean walking/checksumming everything twice for no benefit. See
`roles/restic_backup/README.md`.
