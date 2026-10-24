# Garage security review (T-20)

Scope: branch garage-sstate, commit 1f9f102 (+ uncommitted working tree). Read-only static review of
roles/garage, roles/btrbk (source/snapshot_dir), roles/caddy (body), roles/container (handler),
inventories/production/group_vars/all/vars.yml, reqs/garage-sstate.md v1.5, README. Not run live;
VM results (garage-v1..v4.md) were read, not re-executed. Tools: manual review only
(gitleaks, trufflehog, semgrep, trivy not installed; ansible-lint not run). NAS, cloud, Pi and
1Password not touched.

Result: 0 critical, 0 high, 0 medium, 7 low, plus info items. No blocking findings for T-22.

## Confirmed good (no findings)

- Secrets handling: both secret tasks have no_log: true (roles/garage/tasks/secrets.yml:38,48); argument_specs
  mark both secrets no_log (meta/argument_specs.yml:61,66); the assert-only exception (preflight.yml:32-41)
  is compliant (untemplated conditions, static fail_msg, quiet: true); garage.toml holds only *_file paths
  (templates/garage.toml.j2:11,24); VM run V4 shows 0 matches for fixture secrets under -vvv.
- File modes/owners: secrets dir root:garage 0750, files garage:garage 0400 (secrets.yml:23-47), mounted :ro into the
  container (garage.container.j2:26); garage.toml 0644 root, no secret; data subvolume 0700 root, data/ and
  meta owned by garage 0700 (storage.yml:134-156). The garage user cannot write to the secrets dir.
- Outside snapshots/backups: default /var/lib/garage/secrets is on /@/var, not a btrbk source and not under
  /mnt/data or /mnt/containers; guard compares (fs UUID, root ID) pairs of the nearest existing parent against all
  btrbk_sources and snapper configs before any change (secrets_guard.yml:9-47); the paths are passed as argv, so
  no shell injection. VM runs confirm 0 secret files in snapshots/backup dirs (garage-v3.md GS-AC-67).
  Vault: vault.yml is tracked and ansible-vault encrypted ($ANSIBLE_VAULT header); example holds placeholders only;
  fixture secrets in inventories/vm are fake.
- Exposure: Quadlet has no PublishPort (garage.container.j2:14-16); rpc and admin API bind 127.0.0.1 inside the
  container (garage.toml.j2:9-10,24), so they are unreachable even from caddy.network; the only Caddy route for
  the S3 host is the vars.yml:152-168 body: unsigned GET/HEAD without Authorization or X-Amz-Signature go to
  garage:3902 (website endpoint, read-only, served only for buckets with website access enabled), everything else
  goes to the S3 API on :3900 where unsigned PUT/POST/DELETE are rejected by Garage's SigV4 check. Admin API and
  RPC are not proxied.
- Privilege: User=/Group= are the numeric ids of the dedicated account, asserted 0 < uid < 1000 (storage.yml:109-116,
  garage.container.j2:18-19); no Privileged, no AddCapability, no docker.sock, no host network; garage.toml and
  secrets mounted :ro; :Z only on data/ and meta, not on snapshots or the config dir.
- Injection: every command uses argv or `| quote` (storage.yml:26,61,128,160,168,176; deploy.yml:37); the only
  Garage CLI call is `status`.
- Anonymous route blast radius: limited to buckets for which the user ran `bucket website --allow`; a
  fail-safe on mis-cased X-Amz-Signature (such a request lands on the read-only website endpoint, no escalation).

## Findings

[LOW] 1. Garage ports 3900/3902 reachable from every container on caddy.network - roles/garage/templates/garage.toml.j2:14,18; garage.container.j2:16
  Evidence: garage joins the shared caddy.network and binds 0.0.0.0:3900/3902; any other container on that network
  (tandoor, forgejo, ...) reaches the S3 API and the anonymous web endpoint over plain HTTP, with any Host header.
  Impact: a compromised sibling container can read every website-enabled bucket and attempt S3 auth. No new data is exposed vs. the public route.
  Fix: put garage on a dedicated garage.network shared only with caddy (add a second Network= to the Caddy Quadlet); rotation: no.

[LOW] 2. Container hardening flags missing - roles/garage/templates/garage.container.j2:11-31
  Evidence: no NoNewPrivileges, DropCapability, ReadOnly, SeccompProfile; rootful podman keeps the default cap bounding set.
  Impact: weaker containment if the Garage process is compromised (non-root uid limits it).
  Fix: add NoNewPrivileges=true, DropCapability=ALL, ReadOnly=true (+ Tmpfs=/tmp if needed); verify in the VM with `garage status`; rotation: no.

[LOW] 3. Inputs reaching TOML, Quadlet, Caddyfile and btrbk.conf are not charset-validated - roles/garage/tasks/preflight.yml:18-57; roles/caddy/tasks/main.yml:5-18; roles/btrbk/tasks/validate.yml:6-43
  Evidence: garage_s3_domain only needs `.endswith('.'~zone)` (so `*.zone`, spaces, quotes, newlines, braces pass);
  garage_s3_region has no non-empty check (argument_specs promises one); paths only need `^/` (`:`, spaces, `..`
  pass into `Volume=` and TOML strings); caddy site.host/body/extra and btrbk snapshot_dir are written raw.
  Impact: a mistyped or hostile inventory value can add TOML keys (for example a wider admin bind), Caddy
  directives or extra Volume= mounts. Inputs are admin-owned, hence low.
  Fix: assert garage_s3_domain against a hostname regex, region against `^[a-z0-9-]+$`, all garage_*_path against
  `^/[A-Za-z0-9._/-]+$` without `..`; same charset for caddy site.host and btrbk snapshot_dir; rotation: no.

[LOW] 4. Secrets guard fails open when snapper cannot be read - roles/garage/tasks/secrets_guard.yml:27-35
  Evidence: `snapper list-configs | awk | while ...; exit 0` ignores a failing snapper (snapperd down); also
  only btrbk and snapper are checked, not other tools that might back up /var/lib.
  Impact: if snapper breaks, a custom garage_secrets_dir inside a snapper-covered subvolume passes silently.
  Fix: run snapper list-configs into a variable and `exit 2` on a non-zero status so the task fails; document that other backup tools must exclude the dir; rotation: no.

[LOW] 5. README tells the user to pass the S3 secret on a command line - roles/garage/README.md:81-83,99-101
  Evidence: `-e AWS_SECRET_ACCESS_KEY=<64 hex>` in a `podman run` (visible in ps and shell history); `key info --show-secret` prints to the terminal.
  Impact: local users see the S3 secret via ps or history on the NAS.
  Fix: use `--env-file` (mode 0600, deleted after) or `-e AWS_SECRET_ACCESS_KEY` inherited from a `read -s` variable; add `HISTCONTROL=ignorespace`/a note; rotation: no (only if a real key was already typed that way).

[LOW] 6. No response hardening or rate limit on the anonymous web route - inventories/production/group_vars/all/vars.yml:152-168
  Evidence: user-controlled objects are served as-is on the s3.<zone> origin, no nosniff/CSP, no request limits.
  Impact: stored HTML/JS in a website bucket runs on the S3 origin (no cookies there, so impact is small); unauthenticated read load on a LAN/ZeroTier-only host.
  Fix: add `header @web X-Content-Type-Options nosniff` and `Content-Security-Policy "sandbox"` inside `handle @web`; optionally `request_body max_size` on the API route; rotation: no.

[LOW] 7. Image pinned by tag only - roles/garage/defaults/main.yml:18
  Evidence: docker.io/dxflrs/garage:v2.4.1 (not a digest); the Caddy build (roles/caddy/files/Containerfile) uses unpinned caddy:2 and xcaddy plugin (pre-existing).
  Impact: a retagged or compromised image is pulled on the next pull/restart.
  Fix: pin `@sha256:` next to the tag (Renovate can update both); rotation: no.

## Info / hardening notes (not findings)

- Garage stores S3 access-key secrets and the node key in the metadata subvolume. By design (GS-BR-14, GS-A-25) they are
  in garage-meta snapshots and backup-disk replicas (/mnt/backup/btrbk/garage-meta, root 0700). The backup disk is
  not encrypted (backup_disk R-08 refuses dm-crypt), so physical theft of the disk exposes them; same exposure as the existing restic repos and DB dumps.
- admin_token is only usable inside the container (admin API binds 127.0.0.1 in the container netns); keep or drop the admin section, it is not reachable from the host.
- Handler guard (handlers/main.yml:16-23, roles/container/handlers/main.yml:16-23): if the unit is missing from service_facts the restart is silently skipped, so a rotated secret would not take effect until the next restart. Acceptable; the readiness wait follows.
- Tracked *.env.j2 templates contain only variable references (not scanned with gitleaks, tool missing); caddy.env (Cloudflare token, 0600) lives in /mnt/containers/caddy, which the existing `containers` btrbk source snapshots (pre-existing, out of scope).
- Presigned-URL hosts: the website endpoint ignores query strings, so unsigned `?acl`, `?uploads`, `?lifecycle` and listing requests get website responses, not S3 operations.

## Not covered

Live Caddy/Garage behaviour on the NAS (route behaviour was read, not requested), TLS/HSTS headers, firewalld state
for 80/443, the VM Quadlet generator output, dependency CVEs (osv-scanner missing), SAST (semgrep missing), history scan (gitleaks missing).

## Top actions

1. Dedicated garage.network instead of the shared caddy.network (finding 1).
2. Add NoNewPrivileges/DropCapability=ALL/ReadOnly to the Quadlet (finding 2).
3. Charset/hostname validation of garage_s3_domain, region and paths in preflight (finding 3).
4. Make the secrets guard fail closed on snapper errors (finding 4).
5. Fix the README secret-on-command-line example and add nosniff/CSP to the web route (findings 5, 6).
