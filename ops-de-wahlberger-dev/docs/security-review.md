# Security review of ops-de-wahlberger-dev (T-18)

AUDIT: ops-de-wahlberger-dev (roles, vars, vault.yml.example, tools/, tests/, README.md, CLAUDE.md, docs/) plus the `ssh_authorized_keys` diff in nas-de-int-wahlberger-dev and cloud-wahlberger-dev
Commit: d584f49 (branch feature/semaphore-to-hetzner; the whole `ops-de-wahlberger-dev/` directory is still untracked, so the review reads the working tree)
Date: 2026-10-11. Read-only review, no live access, no `op`, no `.vault_pass.sh`, `vault.yml` not read (only `grep -c '^\$ANSIBLE_VAULT'` = 1, mode 0600).
Tools run: manual read of every file in scope, `grep` secret-pattern sweep (no hit), `shellcheck` on tools/ and tests/ shell (style only, no security hit).
Tools missing (not installed, not installed by this review): gitleaks, trufflehog, semgrep, bandit, osv-scanner, trivy, ruff. `ansible-lint`/`pytest` were deliberately not run: from this directory `ansible.cfg` would call `.vault_pass.sh`.
SH-R-01 (public SSH) is accepted by Erik and is not re-opened here.

SUMMARY: critical 0 | high 0 | medium 2 | low 12 | info 6

## Medium findings (each needs an owner and a re-review line before T-19)

[MEDIUM] F-01 Resend API key printed by `--diff` (notify_failure env file) - roles/notify_failure/tasks/main.yml:24-30
  Evidence: the task renders `notify-failure.env.j2` (line 5 `RESEND_API_KEY={{ ... }}`) with no `no_log` and no `diff: false`. The sibling tasks do protect their files: restic env `no_log: true` + `diff: false` (roles/restic_backup/tasks/main.yml:55-57), caddy.env `no_log` (roles/caddy/tasks/main.yml:103), semaphore.env/config.json `no_log` (roles/semaphore/tasks/main.yml:108,120). README mandates `--check --diff` first for every apply (README.md:322, 349), and step 2 includes the `notify_failure` tag.
  Impact: on the fresh VM the diff of a new file shows the whole file, so the Resend key (same value as the Pi's) lands in the operator's terminal and scrollback, and in the Semaphore task log (stored in the Semaphore database and in its backups) whenever a template runs with `--diff`.
  Fix: add `no_log: true` and `diff: false` to that task in the ops copy. Rotation: only if a `--diff` output of this task was ever captured (check Semaphore task logs of nas/cloud runs; the same unprotected task exists in the nas and cloud copies, outside the PR A file boundary, so fix those in a separate change).
  Owner: T-02 (notify_failure role copy, follow-up polish task).

[MEDIUM] F-02 Caddy image build is unpinned and never refreshed - roles/caddy/files/Containerfile:6-10, roles/caddy/tasks/main.yml:73-79
  Evidence: `FROM docker.io/library/caddy:2-builder`, `RUN xcaddy build --with github.com/caddy-dns/cloudflare` (no module version), `FROM docker.io/library/caddy:2` (floating tags, no digest). The task rebuilds only when the Containerfile changes (`force: caddy_containerfile.changed`), and root renovate.json disables Caddy bumps ("Caddy upgrades skipped for now", incl. `localhost/caddy-cloudflare`).
  Impact: the module is whatever upstream HEAD was at first build, with no integrity check, and the process holds the Cloudflare token (Zone:DNS:Edit on wahlberger.dev, so it can re-point every hostname of the zone, including id.wahlberger.dev). The same build also never receives Caddy security fixes. Reachability is limited to ZeroTier members (allowlist plus zone rule), which keeps this at medium.
  Fix: pin `caddy:<x.y.z>-builder` and `caddy:<x.y.z>` (ideally `@sha256:`), pin `--with github.com/caddy-dns/cloudflare@<tag>`, add a Renovate custom manager for the Containerfile, and decide a rebuild cadence (e.g. `force` on image change or a documented manual rebuild). Rotation: no.
  Owner: T-08 (caddy role, follow-up).

## Low findings

[LOW] F-03 Listeners on all interfaces behind the firewall - roles/beszel_agent/templates/beszel-agent.service.j2:12, roles/zerotier/templates/zerotier.container.j2:15
  Evidence: Beszel gets only `PORT=45876` (listens on `:45876`, all interfaces); ZeroTier runs with `Network=host`, so it binds UDP 9993 (and secondary UDP ports) on the public interface. Blocked by the public zone (ssh only, fixture FW-PUBLIC-SERVICES PASS) and the Cloud Firewall (README.md:191-196), so SH-FR-06 and SH-NFR-03 hold, but they rest on two filters.
  Fix: set Beszel `LISTEN=<vm_zt_ip>:45876` (check the 0.21.0 docs); ZeroTier `local.conf` to disable secondary port and port mapping. Rotation: no. Owner (informational): beszel_agent / zerotier role copies.

[LOW] F-04 beszel_agent: root-equivalent socket, binary never upgraded - roles/beszel_agent/tasks/main.yml:36-60, 134-139
  Evidence: the network-facing agent user is in group `podman`, which owns the rootful Podman API socket (container create = root). The archive is checksummed (lines 102-124, HTTPS, pinned version 0.21.0) but the checksum list comes from the same GitHub release, and `unarchive ... creates: <binary>` means a `beszel_agent_version` bump downloads the new archive and never installs it. The tarball stays in /tmp (predictable name, root-owned, sticky /tmp).
  Fix: drop the `podman` group on this host or front the socket read-only; replace `creates` with a version check or remove the binary on version change. Rotation: no.

[LOW] F-05 Bridge fallback: Semaphore subnet is not the ignored/`from=` subnet - roles/caddy/files/caddy.network:1-7, inventories/production/group_vars/all/vars.yml:56-64,143
  Evidence: in the primary design Semaphore joins `semaphore.network` (172.29.30.0/24, fixed). In `bridge_fallback` it joins `caddy.network`, which declares no Subnet (fixture: 10.89.0.0/24), yet fail2ban `ignoreip`, the login-mail ignore list and the `from=` check still use `semaphore_network_subnet`.
  Impact: only if A3 chooses the fallback: Semaphore's self-run SSH could be banned for 3600 s after 5 failures (violates SH-FR-124 for `<sem-subnet>`) and every self-run login mails.
  Fix: give `caddy.network` a declared Subnet and feed it to `semaphore_network_subnet` when `vm_proxy_design == bridge_fallback`. Rotation: no. Owner: T-08/T-12 (A3 decision).

[LOW] F-06 Secrets in process arguments - roles/notify_failure/templates/notify-failure.sh.j2:89-92, roles/restic_backup/templates/restic-backup.sh.j2:106-109, roles/reboot_notify/templates/reboot-notify.sh.j2:44-47, roles/semaphore/tasks/main.yml:174-197
  Evidence: `curl -H "Authorization: Bearer ${RESEND_API_KEY}"` puts the key into argv for the length of the request (readable in /proc by every local account, including the network-facing `beszel` service account; no `hidepid`). `podman exec ... users add --password <admin password>` does the same, but only when the admin does not exist (migrated database: never). `no_log` hides it from Ansible output only. The login-notify script does it right (in-process header, ssh-login-notify.py:92-104).
  Fix: `curl -K -` with the header on stdin (or `--config` from a 0600 file). Rotation: no.

[LOW] F-07 No sandboxing on the most exposed units - roles/semaphore/templates/semaphore.container.j2:11-42, roles/caddy/templates/caddy.container.j2:15-42, roles/zerotier/templates/zerotier.container.j2, roles/security/templates/ssh-login-notify.service.j2:7-18, roles/security/templates/zypper-dup.service.j2:8-12
  Evidence: no `NoNewPrivileges`, `DropCapability` or read-only root filesystem, config.json is bind-mounted rw, Caddy runs as container root on the host network, login-notify runs as root, `zypper-dup.service` (oneshot) has no `TimeoutStartSec` so a hung zypper holds the lock forever.
  Impact: the Semaphore container runs arbitrary playbook content and holds the automation key; a container escape would be root on the VM.
  Fix: `NoNewPrivileges=true`, `DropCapability=ALL` (+ `AddCapability=NET_BIND_SERVICE` for Caddy), `:ro` for config.json, `DynamicUser` or at least `ProtectKernel*`/`RestrictAddressFamilies` for the notify unit, `TimeoutStartSec=2h`. Test on the fixture first. Rotation: no.

[LOW] F-08 "Public zone: ssh only" is a deny-list - roles/firewall/tasks/main.yml:36-78, 82-89
  Evidence: services are enabled from `firewall_allowed_services` and a fixed list is removed (defaults:16-22). Extra ports, protocols, source-ports, forward-ports or rich rules already in the zone are not reconciled; masquerade is switched on for the public zone. The "exactly ssh" proof exists only in the fixture script (tests/vm/scenarios/s10-firewall.sh:31-33).
  Fix: add an assert (or an allow-list reconcile) of the final `--permanent` and runtime lists to the role, and re-check on the real image at OP-02/OP-03. Rotation: no. Owner: T-07.

[LOW] F-09 Database copy handling in the runbook - README.md:405-419, 433
  Evidence: `mkdir -p ~/semaphore-db-copy` (umask default) and `rsync -a` keep the Pi's 0644 modes, so the copy (bcrypt hashes, encrypted Key Store) is readable by other local users and by backups; the VM step says "scp to a temp file" without a location, mode or removal; deletion is `delete`, not `shred` (README.md:433).
  Impact: the DB alone does not decrypt the Key Store, but SH-R-06 names a DB copy plus `access_key_encryption` as the decryption path.
  Fix: `umask 077` / `install -d -m 0700`, scp into a 0700 directory, add the removal step. Rotation: no. Owner: T-17.

[LOW] F-10 Operator tools - tools/semaphore_record.py:97-98,122-135, tools/populate_vault.py:72-73,321-324, tools/db_prepare.py:142-163
  Evidence: `SemaphoreClient` accepts `http://` and POSTs the admin password in clear (TLS verification is on for https). `--show-hash` prints the first 8 hex of a SHA-256 of each secret (32 bits; a guess aid for the weak ones, e.g. an admin password). `db-prepare` copies the DB to a temp dir (0700, removed) and edits the given file in place (documented as a copy).
  Fix: refuse `http://` unless loopback; document `--show-hash` as off by default (it is). Owner: T-13.
  Confirmed clean: values never printed; the vault password goes through a pipe (`/dev/fd/N`), plaintext only on stdin; the new vault is written 0600 via temp file in the same directory and rename (populate_vault.py:306-318); YAML error text withheld (vault_hash.py:38-40); `user__token.id` never listed (db_prepare.py:193).

[LOW] F-11 sshd variables are free-form - roles/security/meta/argument_specs.yml:12-19, roles/security/tasks/sshd.yml:27-37
  Evidence: `security_ssh_permit_root_login` / `security_ssh_password_authentication` are unconstrained strings and `security_ssh_extra_directives` can add any keyword (fixed keywords win, others do not). `sshd -t` accepts `yes`. Production values are `no`. `AllowStreamLocalForwarding` stays at its default `yes` (SH-FR-120 covers TCP forwarding only).
  Fix: `choices: ["no"]` for the two strings, add `AllowStreamLocalForwarding no`. Owner: T-05.

[LOW] F-12 Check-mode tolerances: correct, but only the check-mode side is tested - roles/podman/tasks/main.yml:97-103, roles/caddy/handlers/main.yml:10, roles/beszel_agent/tasks/main.yml:85-87,144-146,158-160,187-189,216-218, roles/restic_backup/tasks/main.yml:109-111 (same pattern in security, disk_space, container, semaphore handlers)
  Evidence: see the table (SH-QA-1). The guards (tests/guards.d/security_check_mode.yml, firewall.yml) prove that `--check` passes; nothing asserts that a failing unit still fails a real run.
  Fix: one guard case with a failing `systemctl` stub in a non-check run. Owner: T-14 / T-06b.

[LOW] F-13 Supply chain floors - requirements.yml:8-27, .github/workflows/ci.yml (actions at `@v7`, outside this scope), roles/zerotier/defaults/main.yml:4
  Evidence: collections are `>=` floors with no lock (a Semaphore or CI install pulls the newest), images are tag-pinned (semaphore v2.19.16, zerotier 1.14.2), not digest-pinned; CI actions are tag-pinned, not SHA. No `curl | sh`, no `latest` image tag found.
  Fix: upper bounds or a collections lock, digests for the three images, SHA-pinned actions. Owner: T-02 / T-15.

[LOW] F-14 Detective gaps - roles/security/templates/zypper-dup-request-reboot.sh.j2:39-42, roles/security/files/ssh-login-notify.py:136-144, roles/security/templates/ssh-login-notify.service.j2:13-14
  Evidence: `rebootmgrctl reboot || echo ...` then `exit 0` (a reboot request that fails is never mailed, a kernel fix can sit unapplied); the login hook uses `--lines=0`, so logins during the 5 s restart gap or while the unit is broken produce no mail, and `Restart=always` never fires `OnFailure=`.
  Fix: mail on a failed request; consider a heartbeat for the hook. Owner: T-06.

## Info

- I-01 The login-mail regex (ssh-login-notify.py:37-40) was only tested on synthetic lines; the fixture runs with the hook disabled (inventories/vm/group_vars/all/vars.yml:27). Prove it live with SH-AC-47 after the first public login.
- I-02 The login-mail ignore list is the fail2ban ignore list (defaults:25). A login from cloud's public IP, the LAN or any ZeroTier member sends no mail (as specified); `cloud_public_ip` is hard-coded (vars.yml:47), so a changed address silently drops the exemption (fail2ban could then ban Cloud).
- I-03 `common_upgrade: true` runs a full `zypper update` on every playbook run, outside the update window (roles/common/tasks/main.yml:2-7).
- I-04 `.ansible_cache/facts` holds a Molecule host's facts (ansible_env, public host keys); ignored by git, no secret. Real runs will cache `ansible_env` of the VM for 7200 s (ansible.cfg:33-36).
- I-05 Root keeps the Hetzner-installed authorized key; unusable after hardening (`PermitRootLogin no`, `AllowUsers erikwahlberger`, locked password).
- I-06 restic talks `rest:http://` to the NAS (restic encrypts content; the REST basic-auth password crosses ZeroTier only).

## ID-by-ID result

| ID | Result | Evidence |
|---|---|---|
| SH-FR-04 one inbound rule TCP 22 | PASS (doc; live NOT COVERED) | README.md:191-196, 203-207 |
| SH-FR-06 no inbound except TCP 22 on public iface | PASS (see F-03, F-08) | roles/firewall/tasks/main.yml:37-78; defaults:6-22; tests/vm/RESULTS.md:25 |
| SH-FR-15 password auth refused | PASS (F-11) | roles/security/tasks/sshd.yml:28; defaults:9 |
| SH-FR-16 root login refused | PASS | sshd.yml:27,31 (`AllowUsers` also excludes root) |
| SH-FR-17 fail2ban active | PASS | tasks/fail2ban.yml:2-32; templates/jail.local.j2:9-14 |
| SH-FR-18 passwordless sudo | PASS | tasks/accounts.yml:26-34 (0440, `visudo -cf`); vars.yml:70-71 |
| SH-FR-115 no public IPv6 | PASS (doc; host side live NOT COVERED) | README.md:280-289 (`--without-ipv6`) |
| SH-FR-116 KbdInteractive no | PASS | sshd.yml:29 |
| SH-FR-117 AuthenticationMethods publickey | PASS | sshd.yml:30 |
| SH-FR-118 AllowUsers | PASS | sshd.yml:7-15 (non-empty, pattern), 31 |
| SH-FR-119 MaxAuthTries 3 | PASS | sshd.yml:32; defaults:14 |
| SH-FR-157 LoginGraceTime 30 | PASS | sshd.yml:33; defaults:15 |
| SH-FR-120 / 158 / 159 forwarding, agent, X11 | PASS (F-11) | sshd.yml:34-36 |
| SH-FR-121 `sshd -t` before reload | PASS | sshd.yml:75,109,127 (`validate`); handler only on change; RESULTS.md:29 |
| SH-FR-188 reload not restart | PASS | handlers/main.yml:8-15; sshd.yml:146-147; RESULTS.md:22 (session survives) |
| SH-FR-122 no usable password | PASS | accounts.yml:7-22 (every field not starting `!`/`*` is locked, incl. empty); README.md:296-310 |
| SH-FR-123 ban 3600 s after 5 in 600 s | PASS | defaults:30-32; jail.local.j2:12-14; RESULTS.md:23 |
| SH-FR-124 never ban list | PASS (F-05, I-02) | vars.yml:56-64; jail.local.j2:5 (`unique`, 127.0.0.0/8 always); `ignoreself` default |
| SH-FR-125 login mail | PASS (I-01, F-14) | login_notify.yml; ssh-login-notify.py:60-123 |
| Login hook cannot inject into a shell | PASS | no shell, argv list `journalctl` (py:136-141), JSON body via `json.dumps` (py:101), mail over HTTPS API, `text` only, regex anchored `\S+` with `^`..`$` (py:37-40); `-u` stream cannot be forged by unprivileged users; a forged line could only cause an extra mail |
| SH-FR-166 / 215 config.json 0600, UID owner | PASS | roles/semaphore/tasks/main.yml:101-109; RESULTS.md:24 |
| SH-FR-167 / 216 semaphore.env 0600 root | PASS | semaphore/tasks/main.yml:113-121 |
| SH-FR-217 / 218 caddy.env 0600 root | PASS | roles/caddy/tasks/main.yml:96-104 |
| SH-FR-168 / 219 data dir 0700, UID owner | PASS | semaphore/tasks/main.yml:69-75 |
| SH-FR-169 / 207 database.sqlite 0600, UID owner | PASS | semaphore/tasks/main.yml:82-89 |
| SH-FR-204 no -wal/-shm/-journal placed | PASS | role never creates a DB (tasks/main.yml:47-56); db_prepare.py:184-203 |
| SH-FR-171 / 151 no identity.secret, no env file in backups | PASS | restic_backup/defaults:22-43 (only staging dir; excludes `config.json`, `*.env`, `identity.secret`, wal/shm/journal); script 49-59 passes `--exclude` per entry; zerotier data dir 0700 root (zerotier/tasks:12-18) |
| SH-FR-129 / 183 / 184 Caddy allowlist, no :80, no admin | PASS | roles/caddy/templates/Caddyfile.j2:3-8,32-34 (`respond` precedes `reverse_proxy`); RESULTS.md:17,19; Caddy log redacts Authorization/Cookie by default |
| Caddy bound to ZT IP + remote_ip | PASS | Caddyfile.j2:11 `default_bind`; caddy/tasks:4-17 refuses empty/0.0.0.0; fallback `PublishPort=<zt ip>:443:443` (caddy.container.j2:26); `Network=host` real client address (RESULTS.md:19) |
| Quadlet ports (no listener beyond 22 on public iface) | PASS with F-03 | semaphore.container.j2:18 `127.0.0.1:3000` (primary), no PublishPort (fallback); caddy ZT IP only; aardvark-dns only on the bridge IP (RESULTS.md:17) |
| Firewalld zone logic (SH-FR-185, 189, 194, SH-A-20) | PASS | firewall/tasks/main.yml:6-21,91-103; zerotier.yml:7-82 (no reload, permanent-only until operator reload; fail-closed); RESULTS.md:15,18 |
| SH-BR-06 allow matrix | PASS (manual in Central; NOT COVERED live) | docs/zerotier-flow-rules.md:14-24; zone `zerotier` allows ssh, https, 45876/tcp from `cloud_zt_ip` only (zerotier.yml:45-64) |
| SH-BR-11 NAS holds no decrypting value | PASS | config.json and access_key_encryption excluded from backup; Key Store stays encrypted in the DB copy; restic repo password is the only secret shared with the NAS |
| SH-D-14 break-glass | PASS (doc) | README.md:621-633 (no console password) |
| SH-D-15 Cloud Firewall | PASS (doc) | README.md:186-217 |
| SH-D-16 automation key, `from=` | PASS | ssh_authorized_keys/tasks/main.yml:27-32 whole line stored verbatim (spike A-26); tools/check_from_list.py:95-103 checks exact set and ed25519; sem-subnet entry: see F-05 |
| Revoked list / both-lists failure (SH-FR-190) | PASS | ssh_authorized_keys/tasks/main.yml:13-25 (before any change), 34-41; vars/main.yml:5-6; nas and cloud copies identical to ops except README/meta platform (diff checked), default `[]` so a no-op on merge |
| SH-D-18 no mail per ban | PASS | no ban action mail; banaction `nftables-multiport` (defaults:41) |
| SH-D-19 identity not backed up | PASS | see SH-FR-171 |
| SH-D-20 step 9 order | PASS (doc) | README.md:520-545 |
| SH-D-21 unhardened window bounded | PASS (accepted) | README.md:316-337; cloud-init locks password (README.md:296-306) |
| SH-NFR-03 only TCP 22 open | PASS (static; scan is live) | Cloud Firewall + zone; see F-03 for the filtered listeners |
| SH-NFR-14 publickey only | PASS | sshd.yml:28-30 |
| SH-NFR-15 ban within 60 s | PASS (static; AC-46 live) | jail.local.j2:11-14, `backend = systemd`; fixture ban reproduced (RESULTS.md:23) |
| SH-R-04 fallback leaves 443 to FW + DNAT + allowlist | PASS (accepted risk) | RESULTS.md:20; caddy.container.j2:26; Caddyfile.j2:32-33 |
| SH-R-06 surviving config.json + DB copy | PASS for repo controls, F-09 for runbook | modes above; README.md:433, 534 |
| Secrets in logs/env/argv | FINDING F-01, F-06 | rest of the units use `EnvironmentFile` 0600 root (semaphore.container.j2:36, caddy.container.j2:30, restic-backup.service.j2:19-24); `Environment=` in beszel unit holds a public key only (beszel-agent.service.j2:14) |
| Update/reboot units | PASS (F-07, F-14) | updates.yml:13-143; zypper-dup.service.j2:9-16 (`SuccessExitStatus=102`; 103 fails and mails by decision); script never reboots, only `rebootmgrctl reboot`; rebootmgr.conf.j2 `maint-window` Sun 04:00 1h; marker only on mail success |
| Supply chain: image pins | PASS with F-13 | semaphore_image tag (vars.yml:138), zerotier 1.14.2, Caddy see F-02 |
| Supply chain: Beszel checksum | PASS with F-04 | beszel_agent/tasks/main.yml:102-124 (`sha256:` verified, HTTPS, no `validate_certs: false` anywhere) |
| Committed secrets | PASS | vault.yml encrypted header present, mode 0600; vault.yml.example values empty; regex sweep (Resend, AWS, GitHub, Slack, private-key blocks) over the tree: no hit; `.vault_pass.sh` only `op read`; `.gitignore` covers `.vault_pass*` and caches |

### SH-QA-1 Check-mode tolerances (podman, caddy, beszel_agent, restic_backup; same pattern in security, disk_space)

Every tolerance is a two-condition `failed_when`: `<result> is failed` AND `not (ansible_check_mode and msg is search('<exact miss text>'))`. A list under `failed_when` is an AND, and `ansible_check_mode` is false in a real run, so the second term is true and the task fails exactly when the module failed: real-run behaviour is unchanged and nothing is swallowed. Handlers (`caddy`, `container`, `semaphore`, `beszel-agent`) gain `when: not ansible_check_mode`, which is true in a real run, so a failing restart still fails loudly. The exact-miss strings are specific (`Could not find the requested service`, `failed to look up group`, `must be an existing dir`, `is absent, cannot continue`, `Failed to import the required Python library`). The login-notify credential assert is skipped only in check mode (login_notify.yml:19-22). Residual: F-12 (no negative real-run test). Unrelated pre-existing swallow: `podman` "Disable the image-prune timer" has `failed_when: false` (podman/tasks/main.yml:105-111), only when pruning is turned off (VM: on).

## NOT COVERED

Live host (sshd -T on the real image, SELinux enforcing, real `ss -tlnp`/nmap scan, Cloud Firewall contents, public-zone default on the Hetzner image), ZeroTier flow rules in Central, SH-AC-46/47 (ban and login mail on real traffic, including a ban test with the real user name), real Cloudflare/ACME, `zypper dup` exit 103 and rebootmgr overrun, `cloudflare_dns`/`notify_failure`/`reboot_notify`/`zerotier`/`ssh_authorized_keys` on the fixture, CI workflow and renovate.json (T-15/T-19), Molecule run. Dependency CVE and SAST scanners were not installed.

## Re-review

Open: F-01 (T-02), F-02 (T-08). Re-review line: pending (add the date and the commit when both are closed, before T-19 starts).

## Top 5 actions

1. F-01: `no_log: true` + `diff: false` on the notify_failure env task before the first `--check --diff` (OP-02).
2. F-02: pin the Caddy build (base tags, xcaddy module version) and Renovate it.
3. F-08/F-03: assert the final public-zone lists in the role, bind Beszel to the ZeroTier address, then confirm both at OP-02/OP-03 on the real image.
4. F-09: fix the DB copy commands in README steps 4-5 (umask, directory, removal) before step 4.
5. F-05/F-14: decide the subnet for the fallback at A3, and mail on a failed reboot request.

Re-review 2026-10-11: F-01, F-02 and F-05 fixed. F-01: roles/notify_failure/tasks/main.yml:24-32 (`no_log: true`, `diff: false`; caddy.env also got `diff: false`, roles/caddy/tasks/main.yml:103-104; other secret templates already had both: restic; semaphore config.json and semaphore.env also gained `diff: false`, roles/semaphore/tasks/main.yml:109,122). F-02: roles/caddy/files/Containerfile:16-21 (Caddy 2.11.7 builder and runtime by version+sha256, `xcaddy build v2.11.7`, caddy-dns/cloudflare@v0.2.4; bump how-to in the header; Containerfile change still triggers rebuild via roles/caddy/tasks/main.yml:67,78). F-05: roles/caddy/templates/caddy.network.j2:8-10, roles/caddy/defaults/main.yml (`caddy_network_subnet`), inventories/production/group_vars/all/vars.yml (`caddy_network_subnet: "{{ semaphore_network_subnet }}"`), argument_specs, tests/render.d/caddy.yml.
