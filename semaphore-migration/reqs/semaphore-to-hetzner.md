## Feature: Move Semaphore from the Pi to a Hetzner VM (UI over ZeroTier only, key-only public SSH) and retire the Pi
status:            ready
priority:          must
version:           1.3

IDs carry the prefix `SH-`. Deleted IDs are kept as "[Deleted in x.y]" and never reused. The owner's answers to SH-Q1 to SH-Q13 are in the question table under [Open Questions](#open-questions). Security-relevant IDs are listed in [Risks and accepted trade-offs](#risks-and-accepted-trade-offs). Every step's gate scenarios are in [Step gates](#step-gates).

### Problem Statement

Semaphore UI on `pi.de.int.wahlberger.dev` (playbook `pi-de-int-wahlberger-dev`) applies the `nas-de-int-wahlberger-dev`, `cloud-wahlberger-dev` and `pi-de-int-wahlberger-dev` playbooks over SSH. It is the only holder of the automation SSH key, which has passwordless sudo on every host, and of each playbook's Vault password. The owner needs the Raspberry Pi for embedded work. Semaphore needs a new host, and the Pi's other duties (a frozen restic REST server, a Beszel agent) need a defined end.

Owner decisions, not re-evaluated here:
- Semaphore moves to a new Hetzner Cloud CX23 VM running openSUSE Tumbleweed, separate from cloud-wahlberger-dev.
- The Semaphore UI and every other service on the VM are reachable only over ZeroTier.
- SSH (TCP 22) is permanently reachable on the VM's public IPv4, with public-key authentication only (2026-10-10). Public SSH is the repair path when ZeroTier is down, with no console password and no temporary bootstrap rule (SH-R-01).

The reasons for a separate VM:
- No additional always-on device at home. The NAS was bought to lower electricity use.
- The NAS holds the household's personal data and must not also hold the master SSH key and the Vault passwords.
- On the NAS, Semaphore would kill its own runner during NAS OS upgrades. On a separate VM, that problem is limited to the VM's own playbook (the self-run, group G).

Success means:
- Semaphore runs on the VM against the NAS, cloud and the VM itself, with its projects, Key Store, users and task history carried over from the Pi (except the Pi project, deleted in step 6);
- the Semaphore UI answers only to ZeroTier and home-LAN clients;
- the Pi performs no function for this repository;
- no file in the repository depends on the Pi, except the historical references listed in SH-FR-111.

Terms:
- **VM**: the new Hetzner Cloud server.
  - `<vm-fqdn>` = `ops.de.wahlberger.dev`: the public name; inventory hostname and system hostname. Its A record holds `<vm-public-ip>`, and it is used for SSH.
  - `<vm-zt-name>` = `ops.de.int.wahlberger.dev`: its A record holds `<vm-zt-ip>`, and it is the target of the `semaphore` CNAME.
  - `<vm-dir>` = `ops-de-wahlberger-dev`: the playbook directory.
  - `<vm-user>` = `ops`: the htpasswd user and repository name on the NAS rest-server.
  - `<vm-public-ip>`: the VM's public IPv4.
- **ZT IP**: a member's IPv4 address on ZeroTier network `8056c2e21cc5c789` (range 10.243.0.0/16), managed in ZeroTier Central.
  - `<vm-zt-ip>`: the VM's ZT IP, stored in `vars.yml` as `vm_zt_ip`.
  - `<cloud-zt-ip>`: cloud-wahlberger-dev's ZT IP.
- **ZeroTier interface** `<zt-iface>`: the network interface ZeroTier creates on the VM for network `8056c2e21cc5c789`. Its name is stored in `vm_zt_iface`, which feeds the `firewall` role input `firewall_zerotier_interface`.
- **ZeroTier zone** `<zt-zone>`: the firewalld zone `zerotier` that `<zt-iface>` is bound to.
- **Home LAN**: 10.10.0.0/16, routed into ZeroTier by the home router (SH-A-04).
- **Semaphore network**: the Podman network the Semaphore container is attached to: `semaphore.network` in the primary design, `caddy.network` (shared with Caddy) in the bridge fallback. Its IPv4 subnet `<sem-subnet>` is fixed in `<vm-dir>` as `semaphore_network_subnet`.
- **Semaphore UID**: the numeric UID the Semaphore process runs as inside its image. With rootful Podman it is the same number on the host (SH-A-32).
  - It is read read-only in step 3 on the Pi with `podman exec semaphore id -u` (a read permitted by SH-FR-200). The Pi runs the same pinned image tag (SH-FR-50), and Renovate is frozen (SH-FR-161).
  - Pull request A3 commits it as `semaphore_uid`, so every later run, including SH-FR-70 workstation reruns, uses it without an `-e` override.
  - Step 4 re-checks it on the VM (SH-AC-53).
- `semaphore_data_dir`: the VM's Semaphore host directory, `{{ podman_data_dir }}/semaphore`. It holds `config.json`, `semaphore.env` and `data/database.sqlite`.
- `<public-iface-zone>`: the firewalld zone of the VM's public interface, `public`.
- `<nas-lan-ip>`: the NAS's LAN IPv4, as returned by `dig +short nas.de.int.wahlberger.dev @1.1.1.1`.
- `<vm>` and `<vm-fw>`: the Hetzner server name `ops-de-wahlberger-dev` and the Cloud Firewall name `ops-de-wahlberger-dev-fw`.
- `<new key>`: the workstation file holding the new private key until step 6. `<old key>` is the old key's public key data (no private copy exists outside the Pi's Semaphore).
- **Migration notes**: draft pull request C, opened in step 4 and merged in step 6. Its description holds the step-6 deletion list (SH-FR-177, SH-FR-178, SH-AC-54). It lists names only, never secret values.
- **Step-9.3 log**: the terminal output of every step-9.3 command, captured on the workstation and pasted into the pull request E description before the next 9.3 action.
- **Old key**: the automation key whose public half ends in `semaphore-automation@pi.de.int.wahlberger.dev`. **New key**: the ed25519 keypair generated for the VM's Semaphore (SH-D-03). **Personal key**: the key ending in `erikwahlberger@personal`.
- **Public source**: an IPv4 source address outside 10.10.0.0/16, 10.243.0.0/16, 127.0.0.0/8 and `<sem-subnet>`.
- **Migrated DB**: the copy of the Pi's `/mnt/data/containers/semaphore/data/database.sqlite` placed on the VM in step 4.
- **Configuration objects**: the Semaphore projects, templates, inventories, repositories, environments, access keys, users and schedules.
- **Step-4 record**: the counts of every configuration-object kind, the newest task ID and the list of active schedules, read from the Pi's live Semaphore API immediately before the step-4 stop.
- **Monitored units**: `caddy.service`, `semaphore.service`, `zerotier.service`, `beszel-agent.service`, `restic-backup.service` and `zypper-dup.service` (the weekly update service).
- **Full run**: one task of each of the nas, cloud and `<vm-dir>` templates, started from the VM's Semaphore. Each task ends with Semaphore status `Success` and a PLAY RECAP with `failed=0 unreachable=0`.
- **Self-run**: a task of the `<vm-dir>` template run by the VM's own Semaphore. It connects to `<vm-fqdn>`, which the host delivers locally, so it does not depend on ZeroTier (SH-D-17).
- **Normal run**: `ansible-playbook site.yml` with or without `--tags` or `--skip-tags`, with no fault injection.
- **Stopped standby**: the state of the Pi's Semaphore between step 8 and step 9: `systemctl is-active semaphore` prints `inactive`, `systemctl is-enabled semaphore` prints `disabled`, and `/mnt/data/containers/semaphore` exists unchanged.
- **Cut-over**: runbook step 8, which switches `semaphore.de.int.wahlberger.dev` from the Pi to the VM.
- **Stabilization window**: the period from the end of step 8 to the start of step 9, at least 14 days.
- **Point of no return**: the first action of step 9.3, the secure deletion of the Pi's Semaphore data. From then on, no rollback to the Pi exists (SH-D-20).
- **Primary design / bridge fallback**: the two Caddy variants of SH-D-12, selected by `vm_proxy_design` (`primary` or `bridge_fallback`; SH-FR-220). Requirements marked "primary design" apply only while the fallback is not in use.
- **Maintenance window**: Sunday 04:00 to 05:00 Europe/Berlin.
- **Workstation**: the owner's laptop with the repository, the `op` CLI and ansible-core 2.16.
- **Allow matrix**: the table in SH-BR-06. **PR table**: the table in SH-BR-16.
- **[S]**: a static check in the repository or CI. **[H]**: a check on production systems or their consoles (Hetzner, ZeroTier Central, Cloudflare, Semaphore, Uptime Kuma, Beszel). [H] checks are:
  - inspections and normal runs;
  - manual starts of notification units and of cloud's backup;
  - owner-initiated reboots (SH-AC-09, SH-AC-29);
  - connection probes (`nc`, `ssh`, `curl`, `nmap`);
  - deliberate fail2ban bans followed by an unban (SH-AC-46);
  - the temporary changes that SH-AC-04 makes and then reverts.

Repository facts this spec builds on (checked 2026-10-10; "measured" means a recorded test result, "inference" means desk analysis only):
- Pi Semaphore:
  - image `docker.io/semaphoreui/semaphore:v2.19.16` (role default), SQLite;
  - the Pi role renders `config.json` from the Vault value (`semaphore_access_key_encryption`) on every run, with mode `0644`; the data directory has mode `0777`;
  - the local admin `erikwahlberger` is created only if absent;
  - OIDC redirect URI `{{ semaphore_url }}/api/auth/oidc/pocketid/redirect/` with `semaphore_url: https://semaphore.de.int.wahlberger.dev`, client ID `63093482-d2cc-4c77-89df-9f6ff78b160e`.
- Playbook directory names are the host FQDN with dots replaced by hyphens (`cloud.wahlberger.dev` → `cloud-wahlberger-dev`, `nas.de.int.wahlberger.dev` → `nas-de-int-wahlberger-dev`). Names under `.de.int.wahlberger.dev` hold private addresses.
- `cloudflare_dns` (all copies):
  - creates one A record for `inventory_hostname`, with value `cloudflare_dns_ip`, defaulting to `ansible_facts.default_ipv4.address`; on cloud-wahlberger-dev (Hetzner) that default is the public IPv4;
  - creates one CNAME per `caddy_sites` host, always pointing at `inventory_hostname`;
  - never deletes a record.
- `ssh_authorized_keys` uses `state: present` only. Removing a key from the list does not revoke it.
- The NAS `security` role:
  - sets only `PermitRootLogin` and `PasswordAuthentication`;
  - restarts (not reloads) sshd on change;
  - fail2ban jail: `backend = systemd`, `bantime` 3600, `maxretry` 5.
- The NAS `firewall` role applies every change permanent plus immediate, with no reload or restart task.
- firewalld and Podman:
  - Measured on the NAS VM fixture (BD-AC-45): with host networking, a firewalld rich rule is the effective gate (removing the rule turned an allowed external request into a timeout).
  - Measured (BD-A-23): netavark puts every Podman network's subnet into firewalld zone `trusted`, so traffic from containers to host addresses bypasses zone rules.
  - Inference only, never measured (NAS spike `tests/spikes/A-05-firewall-podman.md` is marked "desk study, evidence UNVERIFIED"): a port published from a bridge network is DNATed onto the FORWARD path and bypasses zone rules. This spec relies on host networking (measured) and tests the 443 gate itself (SH-AC-04).
- Name resolution for containers on `caddy.network`: the Pi's network resolves through the home-LAN resolvers 10.10.0.1 and 10.10.10.1, the NAS's through 1.1.1.1 and 8.8.8.8.
- NAS rest-server:
  - `--append-only` (server-wide), `--private-repos`, `--max-size` 100 GiB for the whole server;
  - port 8000 allowed from 10.10.0.0/16 and 10.243.0.0/16;
  - one client, `cloud`;
  - the maintenance run covers one repository and fails if the repository does not exist; the freshness check skips absent paths.
- NAS firewalld zone `public` allows service `ssh` from every source.
- cloud backs up to the NAS. The NAS→Pi job is decommissioned. The Pi still holds the frozen repositories:
  - `nas`: the only off-host copy of NAS data, as of 2026-10-10;
  - `cloud`: copied to the NAS on 2026-10-10.
- ZeroTier network `8056c2e21cc5c789` is managed in ZeroTier Central:
  - new members need manual authorization;
  - no flow rules exist (Central default rule set, owner 2026-10-10).
- Beszel systems and Uptime Kuma monitors are configured by hand.
- `renovate.json`:
  - a regex manager covers `roles/*/defaults/main.yml` in every directory;
  - minor and patch Docker bumps (including `semaphore_image`) are auto-merged;
  - no rule excludes a directory.
- CI validates every top-level directory with an `ansible.cfg`; ansible-core is pinned to 2.20.8, the version bundled in Semaphore on the Pi.
- Lessons already in the `podman` and `common` roles: containers do not inherit the host's `/etc/hosts`, and `net.ipv4.ip_forward` is persisted.

Constraints:
- SH-C-01: The VM playbook follows the conventions in `nas-de-int-wahlberger-dev/CLAUDE.md`:
  - FQCN and ansible-core 2.16 module names;
  - self-contained roles with `meta/argument_specs.yml` and `README.md`, no `meta/main.yml` dependencies, role-prefixed variables;
  - `community.general.zypper`, firewalld and the hand-rolled `security` role;
  - Quadlets through the `container` role;
  - ansible-lint `production` profile.

  `zerotier` is copied from `cloud-wahlberger-dev`. Roles are copied per playbook. Deviations from the NAS copies are listed in SH-CC-07 to SH-CC-09, SH-CC-14 and SH-CC-15.
- SH-C-02: Every secret lives in Ansible Vault, surfaced in `vars.yml` as `"{{ vault_<key> | default('') }}"`. The private half of an automation key is never stored in a repository file or in Vault.
- SH-C-03: The spec phase performs no action on a live system.
- SH-C-04: Owner decisions:
  - Hetzner CX23, openSUSE Tumbleweed, separate from cloud-wahlberger-dev;
  - the UI and every other service reachable only over ZeroTier;
  - SSH on the public IPv4, key-only, from server creation on;
  - Cloud Firewall managed by hand.

  Migrating cloud-wahlberger-dev to Tumbleweed is out of scope.
- SH-C-05: The VM's `access_key_encryption` equals the Pi's value. A different value makes every stored Key Store entry undecryptable.

Decisions (taken by this spec; the owner can override any of them):
- SH-D-01: The service hostname stays `semaphore.de.int.wahlberger.dev`. The Pocket ID client, its redirect URI and its secret do not change (SH-Q12).
- SH-D-02: Semaphore state moves by copying the Pi's SQLite database (SH-A-01).
- SH-D-03: The automation key is rotated, not migrated.
  - Reasons: the old private key and the value that decrypts it sit together on the Pi's USB drive, and the old key's comment names the Pi.
  - Scope: rotation protects only the automation key. The other Key Store secrets (each playbook's Vault password, and any repository keys) stay encrypted with the unchanged `access_key_encryption` (SH-C-05). Their protection rests on SH-D-04, on deleting every copy that could decrypt them (SH-FR-104, SH-FR-172, SH-FR-173, SH-FR-170), and on file modes (SH-FR-166 to SH-FR-169). See SH-R-06.
- SH-D-04: The NAS, cloud and Pi Vault passwords are not rotated (Won't).
- SH-D-05: Semaphore reaches cloud-wahlberger-dev through `cloud.wahlberger.dev` (public IPv4). Matrix row M-07 stays `drop` (SH-Q9).
- SH-D-06: Semaphore projects, templates, schedules and the Key Store stay configured in Semaphore's UI.
- SH-D-07: The Pi's Debian-specific roles are not ported (`journal_archive`, `storage`, the ufw `firewall`, `geerlingguy.security`).
- SH-D-08: The VM's backup runs from a systemd timer on the VM (cloud `restic_backup` pattern).
- SH-D-09: Between step 8 and step 9, the Pi's Semaphore is in stopped standby, as the rollback target.
- SH-D-10: Caddy serves only port 443. It has no port-80 listener (DNS-01 needs none) and no admin endpoint (SH-FR-183, SH-FR-184).
- SH-D-11: This spec lives in `semaphore-migration/reqs/`. The NAS backup specs are historical records and are not edited.
- SH-D-12: Caddy runs with host networking and binds to `<vm-zt-ip>`. Semaphore publishes port 3000 on 127.0.0.1 only, and Caddy proxies to `127.0.0.1:3000`.
  - Reason: with host networking, traffic to 443 is INPUT, so firewalld's zone rule (SH-FR-128) applies (measured mechanism, BD-AC-45), and Caddy sees client addresses without NAT.
  - The step-3 tests SH-AC-51 and SH-AC-04 decide whether this design stands. The decision is committed as `vm_proxy_design` in pull request A3.
  - Stop condition: SH-AC-51 is required in both designs. If it fails in the bridge fallback, step 3 halts, step 4 does not start, and the step-3 rollback runs. The design returns to requirements for the owner's decision (SH-E-47).
  - If either test fails, the bridge fallback applies (SH-FR-186, SH-FR-187): Caddy and Semaphore share a bridge network, Caddy publishes `<vm-zt-ip>:443:443` and proxies to `semaphore:3000`, and Semaphore publishes no port. The fallback's limitation is SH-R-04.
- SH-D-13: Names: `<vm-fqdn>` = `ops.de.wahlberger.dev` (owner choice), `<vm-dir>` = `ops-de-wahlberger-dev` (FQDN-to-directory rule), `<vm-zt-name>` = `ops.de.int.wahlberger.dev` (private addresses live under `.de.int.wahlberger.dev`).
- SH-D-14: Break-glass access is public SSH with the personal key; Hetzner rescue mode is the last resort. No console password is set, because it would create a password-holding account (contradicts SH-FR-122).
- SH-D-15: Hetzner Cloud Firewall, managed by hand (SH-Q11): inbound TCP 22 from `0.0.0.0/0` only, from creation on; no ICMP; UDP 9993 closed; outbound unrestricted.
- SH-D-16: The automation key logs in as `erikwahlberger` with passwordless sudo, as on the NAS and cloud. A separate automation account is Won't. The new key's reach is narrowed by `from=` (SH-FR-126).
- SH-D-17: The `<vm-dir>` inventory sets no `ansible_host`. Semaphore's self-run connects to `<vm-fqdn>`, which the host delivers locally. Workstation runs pass `-e ansible_host=<vm-zt-name>`; otherwise they trigger the SH-FR-125 email.
- SH-D-18: No email per fail2ban ban; only successful public-source logins email (SH-FR-125).
- SH-D-19: The ZeroTier identity is not backed up (SH-FR-171).
  - With the identity, NAS root could impersonate the VM on ZeroTier.
  - Recovery without it: a new identity, re-authorized in Central with the same fixed IP. SH-NFR-07 includes this.
  - SH-FR-79 is deleted.
- SH-D-20: Step 9 order. The reversible removals (9.2) run before the point of no return, which is the first action of 9.3. The rest of 9.3 runs after it: shutdown, detaching the drive, erasing the SD card and deleting the DNS record. These actions are not needed for a rollback, which is no longer possible by then. The old-key revocation and directory removal (pull request E, 9.4) come last.
  - This is the safer of the two orders. Until the first 9.3 action, the step-8 rollback stays complete: the old key is authorized, the Pi playbook exists, and the Pi's data is intact.
  - Pull request E runs only once a rollback has become impossible, so it cannot break one.
  - Its cost is a window in which the old public key is still authorized while its only private copy is already destroyed, which is harmless.
- SH-D-21: The unhardened window between server creation and the step-2 hardening is bounded, not closed by a temporary firewall rule, because the owner rejected a temporary rule (SH-Q3). The bound is 60 min (SH-FR-162). In that window no account has a usable password (SH-FR-122) and root accepts only the personal key.
- SH-D-22: In step 6 the new key is added as a separate Key Store entry. The nas and cloud templates are switched to it, and the `<vm-dir>` template is created with it. The old entry stays until step 9.3. A step-6 rollback switches the nas and cloud templates back to the old entry and deletes the `<vm-dir>` project, with no exported old private key needed.

#### Primary flow (runbook, documented in `<vm-dir>/README.md` by SH-FR-96)

Each step has a gate (see [Step gates](#step-gates)) that must hold before the next step starts (SH-BR-12), and a rollback. Pull requests (A, A2, A3, B, B2, C, C2, C-R, D, E) are described in SH-BR-16.

0. **Prepare.**
   - Run the checks of SH-FR-163 (personal key protection), SH-FR-164 (Hetzner two-factor authentication), SH-FR-165 (Central two-factor authentication) and SH-FR-180 (the Pi's `config.json` matches its Vault value).
   - Generate the new key on the workstation (SH-FR-56).
   - Save Central's current rule set into `<vm-dir>/docs/zerotier-flow-rules.md`.
   - Record the step-0 baseline (SH-FR-213) in the pull request A description.
   - Create the 1Password item `Ansible Vault - <vm-dir>` and the `<vm-dir>` Vault.
   - Merge pull request A.

   Rollback: revert pull request A.
1. **Provision.**
   - Create the VM by hand with `hcloud`: CX23, location nbg1 or fsn1, Tumbleweed (stock image, or the official Minimal-VM Cloud image written from rescue mode), public IPv4, no IPv6.
   - Use the personal key as the Hetzner SSH key, and attach the Cloud Firewall of SH-D-15 at creation.
   - Create the account `erikwahlberger` with the personal key, passwordless sudo and a locked password (cloud-init user-data, or by hand as root).
   - Start the 60-min clock of SH-FR-162.

   Rollback: delete the server and the firewall.
2. **Bootstrap** from the workstation (`-e ansible_host=<vm-public-ip>`): run `site.yml --tags common,notify_failure,disk_space,ssh_authorized_keys,security,reboot_notify,firewall,podman,zerotier`.

   Rollback: delete the server and repeat step 1. The same applies when the 60-min bound of SH-FR-162 is exceeded (SH-E-46).
3. **ZeroTier, DNS and Caddy.**
   - In Central: authorize the member, fix `<vm-zt-ip>`, read the ZeroTier interface name on the VM (`vm_zt_iface`), and create the flow rules in the Flow Rules editor (SH-FR-132).
   - Read the Semaphore UID on the Pi, read-only (`podman exec semaphore id -u`).
   - Merge pull request A2.
   - Run `site.yml --skip-tags semaphore,restic_backup` with `-e ansible_host=<vm-zt-ip>`.
   - Add the VM to the Beszel hub.
   - Run the step-3 tests.
   - If SH-AC-51 or the zone test of SH-AC-04 fails:
     - repeat the step-3 run from the workstation with `-e vm_proxy_design=bridge_fallback`;
     - repeat SH-AC-51 and the non-zone clauses of SH-AC-04;
     - read the Quadlets (SH-AC-61).
   - If SH-AC-51 fails in the fallback, stop: no step 4, run the step-3 rollback (SH-D-12, SH-E-47).
   - Merge pull request A3 (`vm_proxy_design`, `semaphore_uid`, README observations, SH-FR-221) and check it with SH-AC-64.

   Rollback: in Central, put back the saved "before" rule set and deauthorize the member. Delete the server. Delete the Cloudflare A records `ops.de.wahlberger.dev` and `ops.de.int.wahlberger.dev` by hand, because `cloudflare_dns` never deletes records.
4. **Migrate the database.**
   - Take a Hetzner snapshot if the owner applies SH-FR-102 (Could). The snapshot is then subject to the SH-FR-170 deadline.
   - Check SH-BR-13 (no Pi task running or due). Then take the step-4 record from the Pi's API.
   - Stop the Pi's `semaphore.service` cleanly. Copy the database and its companion files, then start the service again (at most 10 min stopped).
   - On the workstation, checkpoint the copy and run the integrity check. Set every schedule inactive in the copy.
   - Place the copy on the VM with the owner and mode of SH-FR-169 and SH-FR-207, and run `--tags semaphore` from the workstation.
   - Open draft pull request C (the migration notes).
   - Run SH-AC-20 before any task runs on the VM, then the other step-4 tests.
   - Add the Uptime Kuma HTTP monitor (SH-FR-91) and TCP monitor (SH-FR-212).
   - Finally, delete the workstation copy (SH-FR-172).

   Rollback: stop the VM's Semaphore and delete its database. The Pi's database was only read; if the Pi's service fails to start, follow SH-E-36.
5. **Backups.**
   - Merge pull request B and apply the NAS with `--tags restic_server`.
   - Apply the VM with `--tags restic_backup` and start one backup, which creates the repository.
   - Merge pull request B2, apply the NAS with `--tags restic_server,backup_disk`, then start one NAS maintenance run and run the restore test.

   Rollback: disable the VM's backup timer, revert pull requests B2 and B, and delete the `ops` line from `.htpasswd` by hand.
6. **New key and Semaphore configuration.**
   - Merge pull request C and apply `--tags ssh_authorized_keys` to nas, cloud and the VM from the workstation.
   - Add the new key as a second Key Store entry, and switch the nas and cloud templates to it (SH-FR-181).
   - Add the `<vm-dir>` project and template, which use the new entry.
   - Delete the Pi project, the API tokens, the integrations and every other item on the deletion list in the migration notes (SH-FR-177 to SH-FR-179).
   - Run the SH-FR-178 scan. The retained old-key entry is exempt until 9.3.
   - Run SH-AC-48. If SH-FR-191 finds another source address, merge pull request C2 and apply it like pull request C.
   - Delete the workstation key copy (SH-FR-58).

   Rollback:
   - switch the nas and cloud templates back to the old entry, and delete the `<vm-dir>` project (it never used the old key);
   - merge pull request C-R, which moves the new key to `ssh_authorized_keys_revoked`;
   - apply `--tags ssh_authorized_keys` to nas, cloud and the VM from the workstation.

   The deleted items (Pi project, API tokens, integrations) are not restored. Restoring them would require repeating step 4, which is allowed before step 6 restarts (SH-BR-03).

   A retry after this rollback follows SH-BR-18: a fresh keypair, a new pull request C, and step 6 again from the top.
7. **Full run** in a slot with no Pi schedule due (SH-BR-02). Rollback: none needed; these are normal runs of `master`.
8. **Cut-over**, within 72 h after the full run (SH-BR-15).
   - Take a Hetzner snapshot if the owner applies SH-FR-102 (Could), subject to SH-FR-170.
   - Check SH-BR-13 and SH-BR-14 on the Pi.
   - Merge pull request D. From the workstation, apply `<vm-dir>` with `--tags cloudflare_dns` and the NAS with `--tags homepage`, then wait 300 s.
   - Read the Pi's active schedules, immediately before the stop.
   - Put the Pi's Semaphore into stopped standby.
   - Activate on the VM the schedules from that reading, except the Pi project's and those starting in the SH-BR-07 window, which are listed in the pull request D description (SH-FR-101).
   - Add the Uptime Kuma TCP monitor.

   Rollback:
   - start and enable the Pi's `semaphore.service`;
   - run `pi-de-int-wahlberger-dev/site.yml --tags cloudflare_dns` from the workstation;
   - deactivate the VM's schedules;
   - revert pull request D.

   Tasks and settings changed on the VM after step 4 are not on the Pi.
9. **Retire the Pi** (order fixed by SH-D-20):
   1. Check that SH-BR-05 holds.
   2. Remove the Pi from Beszel and its monitors from Uptime Kuma. Reversible.
   3. **Point of no return** (first action), then the remaining actions. Record the date and time, and every command's output, in the step-9.3 log.
      - Overwrite and delete the Pi's Semaphore files over SSH from the workstation (SH-FR-173, SH-FR-104), and capture `ls /mnt/data/containers/semaphore`.
      - Delete the old-key Key Store entry on the VM (SH-FR-182).
      - Shut down the Pi, then detach and store its USB drive.
      - Erase the SD card in a card reader on another host (SH-FR-174), then re-image it.
      - Delete the Cloudflare A record `pi.de.int.wahlberger.dev` (SH-FR-108).
   4. Merge pull request E. Apply `--tags ssh_authorized_keys` to nas, cloud and the VM from the workstation (SH-FR-156).
   5. Archive the 1Password item and delete the VM's Hetzner snapshots.

   Rollback: until the first 9.3 action, use the step-8 rollback (9.2 is undone by re-adding the Beszel system and the monitors). From that action on, no rollback to the Pi exists. A VM loss is then recovered per SH-NFR-07.

### Actors

| Actor | Human/System | Description |
|---|---|---|
| Owner (Erik) | Human | Runs the runbook; authorizes the ZeroTier member and writes flow rules in Central; manages the Hetzner firewall, Cloudflare and the Semaphore UI; holds 1Password |
| Workstation | System | ansible-core 2.16 and `op` CLI; runs the bootstrap and every run that a self-run excludes |
| VM (`<vm-fqdn>`) | System | Hetzner CX23, openSUSE Tumbleweed x86_64; runs sshd (public), Caddy, Semaphore, ZeroTier, the Beszel agent and the restic client |
| Semaphore (VM) | System | Applies the nas, cloud and `<vm-dir>` playbooks from step 7 on |
| Semaphore (Pi) | System | Current runner until step 8; stopped standby until step 9.3 |
| Pi | System | Raspberry Pi OS host; frozen rest-server and Beszel agent; retired in step 9 |
| NAS | System | Target host; rest-server and maintenance run for the VM repository |
| cloud-wahlberger-dev | System | Target host; Pocket ID, Beszel hub and Uptime Kuma; ZeroTier member |
| Pocket ID | System | OIDC provider at `https://id.wahlberger.dev` |
| ZeroTier Central | System | Membership, IP assignment and the Flow Rules editor for network `8056c2e21cc5c789` |
| Hetzner Cloud | System | Server, Cloud Firewall, web console, rescue mode and snapshots |
| Cloudflare | System | `wahlberger.dev` zone; ACME DNS-01 |
| GitHub | System | Repository that Semaphore clones |
| Renovate | System | Opens and auto-merges image bump pull requests |
| Resend | System | Delivers alert emails |
| Internet clients | Human/System | Anyone able to reach TCP 22 on `<vm-public-ip>`, including scanners and attackers |

### Functional Requirements

#### A. Provisioning and network exposure
- SH-FR-01 [Must]: The VM shall be a Hetzner Cloud server of type CX23 (x86_64) running openSUSE Tumbleweed.
- SH-FR-02 [Must]: The VM shall have a public IPv4 address.
- SH-FR-03 [Must]: The VM shall have its Hetzner Cloud Firewall attached from server creation on.
- SH-FR-04 [Must]: The VM's Cloud Firewall shall contain exactly one inbound rule, allowing TCP 22 from `0.0.0.0/0`.
- SH-FR-05 [Deleted in 1.0]: was the temporary bootstrap rule (SH-Q3).
- SH-FR-06 [Must]: The VM's host firewall shall accept no inbound TCP or UDP connection on the public network interface except TCP 22.
- SH-FR-07 [Must]: Where the primary design applies, Caddy shall listen on port 443 of `<vm-zt-ip>` only, with no listener on `0.0.0.0`, `[::]` or `<vm-public-ip>`. In the bridge fallback, SH-FR-187 applies instead.
- SH-FR-08 [Must]: The VM's host firewall shall accept inbound TCP 22 in the ZeroTier zone.
- SH-FR-09 [Must]: The VM's host firewall shall accept inbound TCP 45876 (Beszel agent) only from `<cloud-zt-ip>`. Traffic from the VM's own Podman networks is accepted by zone `trusted` (measured mechanism) and is not covered by this rule.
- SH-FR-162 [Must]: SH-AC-05 (the step-2 hardening check) shall pass within 60 min of server creation. SH-AC-49 measures this; SH-AC-62 can run after the 60 min.
- SH-FR-164 [Must]: The Hetzner account that owns the VM shall have two-factor authentication enabled.
- SH-FR-165 [Must]: The ZeroTier Central account that administers network `8056c2e21cc5c789` shall have two-factor authentication enabled.

#### B. Playbook and base OS
- SH-FR-10 [Must]: The repository shall contain a playbook directory `<vm-dir>` with its own `ansible.cfg`, `site.yml` and `requirements.yml`.
- SH-FR-135 [Must]: `<vm-dir>/inventories/production/hosts.yml` shall list exactly one host, `<vm-fqdn>`.
- SH-FR-136 [Must]: `<vm-dir>/inventories/production/group_vars/all/` shall contain `vars.yml`, an Ansible-Vault-encrypted `vault.yml` and a plaintext `vault.yml.example`.
- SH-FR-137 [Must]: `<vm-dir>/.vault_pass.sh` shall read the Vault password from `op://DevOps/Ansible Vault - <vm-dir>/password`.
- SH-FR-138 [Must]: `<vm-dir>` shall contain `.yamllint` and `.ansible-lint`, which opt the directory into the CI lint steps.
- SH-FR-139 [Must]: `<vm-dir>` shall contain `README.md` and `CLAUDE.md`.
- SH-FR-11 [Must]: CI shall run ansible-lint with the `production` profile on `<vm-dir>` for every pull request.
- SH-FR-140 [Must]: CI shall run yamllint on `<vm-dir>` for every pull request.
- SH-FR-141 [Must]: CI shall install `<vm-dir>`'s Galaxy dependencies and run `ansible-playbook site.yml --syntax-check` in `<vm-dir>` for every pull request.
- SH-FR-142 [Must]: CI's vault-encryption check shall cover `<vm-dir>`'s `vault.yml`.
- SH-FR-12 [Must]: `<vm-dir>` shall have a Molecule scenario that converges `common`, `notify_failure`, `disk_space`, `ssh_authorized_keys` and `security` twice on openSUSE Tumbleweed, and that fails on any change in the second converge.
- SH-FR-13 [Must]: The set of roles in `site.yml` shall be exactly: `common`, `notify_failure`, `disk_space`, `ssh_authorized_keys`, `security`, `reboot_notify`, `firewall`, `podman`, `zerotier`, `beszel_agent`, `cloudflare_dns`, `caddy`, `semaphore`, `hush`, `restic_backup`.
  - Amendment 2026-10-24: `hush` added (Hush alerting, ZeroTier only, behind `caddy`; placed after `semaphore`, before the last role `restic_backup`). Role: `ops-de-wahlberger-dev/roles/hush`.
- SH-FR-143 [Must]: Each role entry in `site.yml` shall carry a tag equal to the role name.
- SH-FR-14 [Must]: The VM's hostname shall be `<vm-fqdn>`.
- SH-FR-15 [Must]: sshd on the VM shall refuse password authentication.
- SH-FR-16 [Must]: sshd on the VM shall refuse root login.
- SH-FR-17 [Must]: fail2ban shall be active for sshd on the VM.
- SH-FR-18 [Must]: `erikwahlberger` shall have passwordless sudo on the VM.
- SH-FR-19 [Must]: The VM's systemd journal shall persist across reboots.
- SH-FR-20 [Must]: When usage of `/` reaches 85 %, the owner shall receive an email within 20 min.
- SH-FR-21 [Must]: Each monitored unit shall have an `OnFailure=` line naming a `notify-failure` instance.
- SH-FR-144 [Must]: A monitored unit with `Restart=always` shall use `notify-failure@%n.service`.
- SH-FR-206 [Must]: `notify-failure@%n.service` on the VM shall email after 5 failures of its unit within 10 min (the `notify_failure` role's crash threshold).
- SH-FR-145 [Must]: A monitored unit without `Restart=always` shall use `notify-failure-immediate@%n.service`.
- SH-FR-22 [Must]: The VM's clock shall be synchronized by an NTP client that is enabled at boot.
- SH-FR-23 [Must]: Containers on the VM shall not inherit the host's `/etc/hosts`.
- SH-FR-24 [Must]: After every reboot, `net.ipv4.ip_forward` on the VM shall be `1`.
- SH-FR-25 [Should]: Where the VM's root filesystem is btrfs, every zypper transaction shall create a snapper pre/post snapshot pair.

#### C. ZeroTier
- SH-FR-26 [Must]: The VM shall join ZeroTier network `8056c2e21cc5c789` through a `zerotier` Quadlet with host networking and `/dev/net/tun`.
- SH-FR-27 [Must]: The VM's ZeroTier node ID shall stay the same across container restarts and VM reboots.
- SH-FR-28 [Must]: The VM shall become an authorized member only through manual authorization by the owner in ZeroTier Central.
- SH-FR-205 [Must]: The repository shall hold no ZeroTier Central API token.
- SH-FR-29 [Must]: `<vm-zt-ip>` shall be a fixed assignment in ZeroTier Central.
- SH-FR-30 [Must]: The flow rules shall permit every connection marked "allow" in the allow matrix.
- SH-FR-31 [Must]: The flow rules shall drop every other connection attempt from `<vm-zt-ip>` to a ZeroTier or home-LAN address.
- SH-FR-32 [Must]: The flow rules shall drop every connection attempt to `<vm-zt-ip>` that the allow matrix does not list.
- SH-FR-33 [Must]: Before the flow rules change (step 0), the rule set in force shall be saved, with its date, in `<vm-dir>/docs/zerotier-flow-rules.md`.
- SH-FR-34 [Must]: After the change (step 3), the new rule set shall be saved, with its date, in the same file (pull request A2).
- SH-FR-35 [Must]: After the flow-rule change, `nc -z -w5 <nas-lan-ip> 8000` from cloud shall succeed.
- SH-FR-197 [Must]: After the flow-rule change, the Beszel hub shall show the NAS and cloud as up.
- SH-FR-198 [Must]: After the flow-rule change, every Uptime Kuma monitor that was up in the step-0 baseline shall be up.
- SH-FR-199 [Must]: After the flow-rule change, `ping -c 3 <cloud-zt-ip>` from a home-LAN client shall succeed.
- SH-FR-132 [Must]: In step 3, the owner shall create the flow rules by hand in ZeroTier Central's Flow Rules editor for network `8056c2e21cc5c789`. The rules are written in Central's rules language, and the README links to its reference.
- SH-FR-185 [Must]: `<zt-iface>` shall be bound by name to the ZeroTier zone in firewalld's permanent configuration, so the binding applies when the interface appears after firewalld has started.

#### D. DNS, TLS and reverse proxy
- SH-FR-36 [Must]: The VM's `cloudflare_dns` role shall keep an unproxied A record `<vm-fqdn>` whose value is `<vm-public-ip>`.
- SH-FR-131 [Must]: The VM's `cloudflare_dns` role shall keep an unproxied A record `<vm-zt-name>` whose value is `<vm-zt-ip>`.
- SH-FR-37 [Must]: While `semaphore_dns_cutover_enabled` is false, a run of `<vm-dir>` shall not create or change the record `semaphore.de.int.wahlberger.dev`.
- SH-FR-38 [Must]: When a run of `<vm-dir>` with `semaphore_dns_cutover_enabled: true` ends, `semaphore.de.int.wahlberger.dev` shall be an unproxied CNAME to `<vm-zt-name>`.
- SH-FR-39 [Must]: Caddy on the VM shall obtain the certificate for `semaphore.de.int.wahlberger.dev` by ACME DNS-01 through Cloudflare, using the locally built image with the `caddy-dns/cloudflare` module.
- SH-FR-40 [Must]: Where the primary design applies, Caddy on the VM shall reverse-proxy `https://semaphore.de.int.wahlberger.dev` to `127.0.0.1:3000`. In the bridge fallback, the upstream is `semaphore:3000` (SH-FR-186).
- SH-FR-128 [Must]: Where the primary design applies, the VM's host firewall shall accept inbound TCP 443 only in the ZeroTier zone. Container-originated traffic passes zone `trusted` and is not covered by this rule. In the bridge fallback, this rule is expected to have no effect (SH-R-04).
- SH-FR-196 [Must]: Caddy shall write one access-log entry per request to the Semaphore site, including the client address.
- SH-FR-129 [Must]: Caddy shall answer HTTP 403 to every request whose client address is outside 10.243.0.0/16 and 10.10.0.0/16.
- SH-FR-130 [Must]: Where the primary design applies, Semaphore's port 3000 shall be published on 127.0.0.1 only. In the bridge fallback, it publishes no host port (SH-FR-186).
- SH-FR-183 [Must]: Caddy shall have no listener on TCP 80.
- SH-FR-184 [Must]: Caddy's admin endpoint shall be disabled.
- SH-FR-186 [Must]: Where the bridge fallback of SH-D-12 applies, Semaphore shall publish no host port, and Caddy shall reach it as `semaphore:3000` on a bridge network both containers join.
- SH-FR-187 [Must]: Where the bridge fallback of SH-D-12 applies, Caddy's port 443 shall be published on `<vm-zt-ip>` only.
- SH-FR-41 [Must]: Inside the Semaphore container, `nas.de.int.wahlberger.dev`, `cloud.wahlberger.dev`, `<vm-fqdn>` and `github.com` shall resolve to the addresses that `dig @1.1.1.1` returns for them.

#### E. Semaphore deployment and state migration
- SH-FR-42 [Must]: The VM's `semaphore_url` shall be `https://semaphore.de.int.wahlberger.dev`.
- SH-FR-43 [Must]: The VM's `vault_semaphore_access_key_encryption` shall be byte-identical to the Pi's.
- SH-FR-44 [Must]: The VM's `vault_semaphore_cookie_hash` shall equal the Pi's value.
- SH-FR-146 [Must]: The VM's `vault_semaphore_cookie_encryption` shall equal the Pi's value.
- SH-FR-45 [Must]: The VM's `semaphore_oidc_client_id` shall be the Pi's, `63093482-d2cc-4c77-89df-9f6ff78b160e`.
- SH-FR-201 [Must]: The VM's `vault_semaphore_oidc_client_secret` shall equal the Pi's value.
- SH-FR-202 [Must]: The Pocket ID client registration for Semaphore (redirect URI, client ID) shall not change, and no new Pocket ID client shall be created for this feature.
- SH-FR-46 [Must]: The VM's `vault_semaphore_admin_password` shall equal the Pi's value.
- SH-FR-147 [Must]: The VM's `vault_cloudflare_dns_api_token` shall equal the Pi's value.
- SH-FR-148 [Must]: The VM's `vault_notify_failure_resend_api_key` shall equal the Pi's value.
- SH-FR-180 [Must]: In step 0, the SHA-256 of the `access_key_encryption` value in the Pi's live `config.json` shall equal the SHA-256 of the Pi Vault's `vault_semaphore_access_key_encryption`.
- SH-FR-47 [Must]: The local admin `erikwahlberger` shall be able to log in to the VM's Semaphore with the `vault_semaphore_admin_password` value.
- SH-FR-48 [Must]: A "Sign in with Pocket ID" login on the VM's Semaphore shall reach the Semaphore user that the same Pocket ID account reaches on the Pi, with the same project roles.
- SH-FR-175 [Must]: The database shall be copied only after the Pi's `semaphore.service` has stopped cleanly: `systemctl is-active` prints `inactive`, not `failed`.
- SH-FR-176 [Must]: If a `database.sqlite-wal` or `database.sqlite-journal` file exists after the stop, it shall be copied together with the database.
- SH-FR-203 [Must]: The workstation copy shall be checkpointed with `PRAGMA wal_checkpoint(TRUNCATE)` before the integrity check.
- SH-FR-204 [Must]: No `database.sqlite-wal`, `database.sqlite-shm` or `database.sqlite-journal` file shall be placed on the VM.
- SH-FR-49 [Must]: The migrated DB shall return `ok` for `PRAGMA integrity_check` before it is placed on the VM.
- SH-FR-50 [Must]: The VM's `semaphore_image` at the VM Semaphore's first start shall be the same tag as the image running on the Pi when the database was copied.
- SH-FR-51 [Must]: On its first start, the VM's Semaphore shall open the migrated DB.
- SH-FR-52 [Must]: If `semaphore_require_existing_db` is true and the database file is absent, then the `semaphore` role shall fail before it starts the container, with a message naming the expected path.
- SH-FR-53 [Must]: Before the VM's Semaphore runs its first task, it shall report the same count for each configuration-object kind, and the same newest task ID, as the step-4 record.
- SH-FR-177 [Must]: In step 4, every access-key row in the migrated DB shall either be used by a `--check` task of the nas or cloud template that ends with `failed=0 unreachable=0`, or be put on the deletion list in the migration notes. Rows used only by the Pi project go on the deletion list; the Pi is not reachable from the VM (matrix row M-08).
- SH-FR-178 [Must]: In step 4, every occurrence of `pi.de.int.wahlberger.dev`, `pi-de-int-wahlberger-dev` or `/mnt/data` in the migrated DB shall be listed in the migration notes. After step 6, no occurrence shall remain, except in the retained old-key Key Store entry (SH-D-22), which is deleted in 9.3.
- SH-FR-179 [Must]: In step 6, every API token and every integration in the VM's database shall be deleted.
- SH-FR-54 [Must]: The VM's Semaphore shall start no scheduled task before step 8.
- SH-FR-55 [Must]: The Semaphore container on the VM shall open TCP connections to port 22 of `nas.de.int.wahlberger.dev`, `cloud.wahlberger.dev` and `<vm-fqdn>`.
- SH-FR-127 [Must]: The Semaphore network's IPv4 subnet `<sem-subnet>` shall be declared in `<vm-dir>`.
- SH-FR-166 [Must]: `config.json` on the VM shall have mode `0600`.
- SH-FR-215 [Must]: `config.json` on the VM shall be owned by the Semaphore UID.
- SH-FR-167 [Must]: `semaphore.env` on the VM shall have mode `0600`.
- SH-FR-216 [Must]: `semaphore.env` on the VM shall be owned by root.
- SH-FR-217 [Must]: `caddy.env` on the VM shall have mode `0600`.
- SH-FR-218 [Must]: `caddy.env` on the VM shall be owned by root.
- SH-FR-168 [Must]: The VM's Semaphore data directory (holding `database.sqlite`) shall have mode `0700`.
- SH-FR-219 [Must]: The VM's Semaphore data directory shall be owned by the Semaphore UID.
- SH-FR-210 [Must]: While `semaphore_uid` is empty, the `semaphore` role of `<vm-dir>` shall fail before any change, naming `semaphore_uid`.
- SH-FR-169 [Must]: The placed `database.sqlite` shall have mode `0600`.
- SH-FR-207 [Must]: The placed `database.sqlite` shall be owned by the Semaphore UID.
- SH-FR-208 [Must]: After the VM container's first start, `database.sqlite` shall carry SELinux type `container_file_t`.
- SH-FR-172 [Must]: At the end of step 4, after its gate has passed, the workstation copy of the Pi database and its companion files shall be deleted.

#### F. Automation key
- SH-FR-56 [Must]: A new ed25519 keypair with the comment `semaphore-automation@<vm-fqdn>` shall be generated on the workstation in step 0.
- SH-FR-57 [Must]: From the end of step 6 on, the new key's private half shall exist only in the VM Semaphore's Key Store (and therefore, encrypted, in its database and the backups of that database).
- SH-FR-58 [Must]: At the end of step 6, after SH-AC-48's workstation attempt, the workstation copy of the new private key shall be deleted.
- SH-FR-181 [Must]: In step 6, the new key shall be added to the VM's Key Store as an entry separate from the old key's. The nas and cloud templates shall be switched to it, and the `<vm-dir>` template shall be created with it.
- SH-FR-59 [Must]: Before step 7 starts, the nas, cloud and `<vm-dir>` templates shall use the Key Store entry holding the new key.
- SH-FR-182 [Must]: In step 9.3, the old-key Key Store entry shall be deleted from the VM's Semaphore.
- SH-FR-60 [Must]: The `ssh_authorized_keys` role in nas, cloud and `<vm-dir>` shall remove every key listed in `ssh_authorized_keys_revoked` from the user's `authorized_keys`.
- SH-FR-190 [Must]: If a key appears in both `ssh_authorized_keys_list` and `ssh_authorized_keys_revoked` (compared by key type and key data, ignoring options and comment), then the `ssh_authorized_keys` role shall fail before any change, naming the key's comment.
- SH-FR-61 [Must]: After step 9.4, an SSH login with the old key to the NAS, cloud or the VM shall be refused.
- SH-FR-62 [Must]: In every pull request of this feature, each `ssh_authorized_keys_list` in nas, cloud and `<vm-dir>` shall contain the personal key.
- SH-FR-126 [Must]: The new key's line in `ssh_authorized_keys_list` (nas, cloud, `<vm-dir>`) shall carry a `from=` option listing exactly `<vm-public-ip>`, `<vm-zt-ip>` and `<sem-subnet>`, plus any address added by SH-FR-191.
- SH-FR-191 [Must]: In step 6, the NAS sshd log entry for the VM's first login with the new key shall show a source address in the `from=` list. If it shows another address (for example the router's, when it masquerades ZeroTier traffic), that address shall be added to the `from=` list in all three playbooks before step 7.
- SH-FR-163 [Must]: The personal private key shall be passphrase-protected or held by a hardware-backed or agent-only store (FIDO2 `sk-` key, 1Password SSH agent or Secure Enclave), and never stored as an unencrypted file.

#### G. Semaphore projects, templates and the self-run
- SH-FR-63 [Must]: The VM's Semaphore shall have one task template for each of `nas-de-int-wahlberger-dev`, `cloud-wahlberger-dev` and `<vm-dir>`. Each template runs `site.yml` with that playbook's `inventories/production/hosts.yml`.
- SH-FR-64 [Must]: The `<vm-dir>` template shall use the `<vm-dir>` Vault password stored in the Key Store.
- SH-FR-65 [Must]: From step 6 on, the VM's Semaphore shall have no template whose inventory targets `pi.de.int.wahlberger.dev`.
- SH-FR-66 [Must]: A self-run shall not restart `semaphore.service`.
- SH-FR-149 [Must]: The `<vm-dir>` template shall pass `--skip-tags semaphore,zerotier`.
- SH-FR-67 [Must]: A self-run shall not restart `zerotier.service`.
- SH-FR-68 [Must]: A self-run shall not upgrade OS packages.
- SH-FR-150 [Must]: The `<vm-dir>` template shall pass `-e common_upgrade=false`.
- SH-FR-188 [Must]: When the `<vm-dir>` `security` role changes the sshd configuration, it shall reload sshd, not restart it.
- SH-FR-189 [Must]: The `<vm-dir>` `firewall` role shall apply changes as permanent plus immediate rule changes, without reloading or restarting firewalld.
- SH-FR-69 [Must]: Every self-run's task shall have an end time recorded in Semaphore within 60 min of its start.
- SH-FR-70 [Must]: `<vm-dir>/README.md` shall give the workstation command that applies the roles a self-run excludes, and shall state that a `semaphore_image` change in `<vm-dir>` takes effect only through that command.

#### H. OS updates and reboots
- SH-FR-71 [Must]: The VM shall run an unattended `zypper dup` through `zypper-dup.service`, started by `zypper-dup.timer` every Sunday at 04:00 Europe/Berlin.
- SH-FR-72 [Must]: If `zypper-dup.service` fails, then the owner shall receive an email within 10 min.
- SH-FR-73 [Must]: When `zypper-dup.service` ends and `zypper needs-rebooting` exits 102, the VM shall request a reboot from rebootmgr, which carries it out within the maintenance window. If the run ends after the window has closed, the reboot happens in the next window, never outside one.
- SH-FR-214 [Must]: The update service shall not reboot the VM itself. Its script calls no `reboot` or `systemctl reboot`; reboots happen only through rebootmgr.
- SH-FR-74 [Must]: The VM shall not reboot for updates outside the maintenance window.
- SH-FR-195 [Must]: rebootmgr on the VM shall use strategy `maint-window`, with window start Sunday 04:00 and duration 1h.
- SH-FR-75 [Must]: Before an update-triggered reboot, the owner shall receive a heads-up email through `reboot_notify`.
- SH-FR-76 [Must]: After any reboot, `https://semaphore.de.int.wahlberger.dev` shall answer HTTP 200 over ZeroTier within 5 min of boot, without manual action.

#### I. Backups
- SH-FR-77 [Must]: A systemd timer on the VM shall start a restic backup to the NAS rest-server, as user `<vm-user>` into repository `<vm-user>`, every day at 05:00 Europe/Berlin, with `Persistent=true`.
- SH-FR-78 [Must]: Each backup shall contain a transactionally consistent copy of Semaphore's SQLite database.
- SH-FR-79 [Deleted in 1.1]: was "each backup contains the ZeroTier identity directory". Replaced by SH-FR-171 (SH-D-19).
- SH-FR-171 [Must]: No backup shall contain the ZeroTier identity secret (`identity.secret`).
- SH-FR-80 [Must]: No backup shall contain Semaphore's `config.json`.
- SH-FR-151 [Must]: No backup shall contain a rendered environment file (`semaphore.env`, `caddy.env`, the restic environment file).
- SH-FR-81 [Must]: The VM's backup job shall run no `restic forget` and no `restic prune`.
- SH-FR-82 [Must]: Each backup run shall run `restic check`. The single invocation `restic check --read-data-subset=10%` of SH-FR-152 satisfies both requirements.
- SH-FR-152 [Must]: Each backup run shall run `restic check --read-data-subset=10%`.
- SH-FR-83 [Must]: If a backup or a check fails, then the owner shall receive an email within 10 min.
- SH-FR-84 [Must]: The NAS `restic_server_clients` shall contain an entry `<vm-user>` whose password is `vault_restic_server_<vm-user>_htpasswd_password`.
- SH-FR-85 [Must]: The NAS maintenance run shall forget snapshots in the `<vm-user>` repository with keep 7 daily, 4 weekly and 6 monthly.
- SH-FR-154 [Must]: The NAS maintenance run shall apply its prune guard to the `<vm-user>` repository before any forget.
- SH-FR-153 [Must]: The NAS maintenance run shall prune the `<vm-user>` repository after its forget.
- SH-FR-155 [Must]: The NAS maintenance run shall run its check on the `<vm-user>` repository.
- SH-FR-86 [Must]: The commands and keep values the NAS maintenance run applies to the `cloud` repository shall be identical before and after SH-CC-01.
- SH-FR-87 [Should]: The NAS `backup_disk_freshness_checks` shall contain `/mnt/data/restic-repos/<vm-user>/snapshots` with `max_age_hours: 26`.
- SH-FR-88 [Must]: The value of `<vm-dir>`'s `vault_restic_backup_repo_password` shall also be stored in 1Password.
- SH-FR-89 [Must]: Restoring the latest snapshot to a scratch directory shall yield a database file that returns `ok` for `PRAGMA integrity_check`, with the same number of project, template and access-key rows as the live database.
- SH-FR-90 [Must]: `<vm-dir>/README.md` shall describe how to restore the Semaphore database from the NAS repository: stop the service, replace the file, set its owner and mode, start the service.

#### J. Monitoring
- SH-FR-91 [Must]: From step 4 on, Uptime Kuma shall have an HTTP monitor for `https://semaphore.de.int.wahlberger.dev/api/ping` (fallback `/`, SH-A-09), with a 60 s interval and 3 retries, that notifies the owner. Until step 8 the hostname resolves to the Pi, so this monitor checks the Pi until then.
- SH-FR-212 [Must]: From step 4 on, Uptime Kuma shall have a TCP monitor for `ops.de.int.wahlberger.dev` port 443, reached by cloud over ZeroTier (matrix row M-04).
- SH-FR-213 [Must]: In step 0, the owner shall record in the pull request A description which Beszel systems and which Uptime Kuma monitors are up (the step-0 baseline for SH-FR-197 and SH-FR-198).
- SH-FR-92 [Should]: From step 8 on, Uptime Kuma shall have a TCP monitor for `<vm-fqdn>` port 22.
- SH-FR-93 [Must]: The Beszel hub shall show the VM as a system with status up.
- SH-FR-94 [Must]: After step 9.2, the Beszel hub shall have no system for the Pi.
- SH-FR-95 [Must]: After step 9.2, Uptime Kuma shall have no monitor whose target is `pi.de.int.wahlberger.dev` or one of its addresses.

#### K. Cut-over
- SH-FR-96 [Must]: `<vm-dir>/README.md` shall contain runbook steps 0 to 9, each with its gate scenarios and its rollback.
- SH-FR-97 [Must]: Until step 7 ends, no commit shall change files under `pi-de-int-wahlberger-dev/`.
- SH-FR-200 [Must]: Until step 7 ends, the owner shall make no change on the Pi. The only permitted actions are reads (including logins to the Pi's Semaphore API and the step-3 `podman exec semaphore id -u`) and, per database copy, one stop and start of `semaphore.service` with the service stopped for at most 10 min.
- SH-FR-98 [Must]: Step 8 shall start only after a full run.
- SH-FR-99 [Must]: In step 8, the Pi's Semaphore shall be put into stopped standby.
- SH-FR-100 [Must]: During the stabilization window, the Pi's Semaphore shall stay in stopped standby, and the old key shall stay authorized on the NAS and cloud.
- SH-FR-101 [Must]: In step 8, every schedule active on the Pi when read immediately before the Pi's stop shall be activated on the VM, except:
  - the Pi project's schedules;
  - schedules that start inside the SH-BR-07 window, which stay inactive and are listed in the pull request D description for the owner to re-time.
- SH-FR-102 [Could]: A Hetzner snapshot of the VM shall be taken before step 4 and before step 8.
- SH-FR-170 [Must]: Each Hetzner snapshot of the VM shall be deleted no later than 30 days after its creation.
- SH-FR-209 [Must]: After step 9.5, no Hetzner snapshot of the VM shall exist.

#### L. Pi retirement
- SH-FR-103 [Must]: Step 9 shall start only when every SH-BR-05 precondition holds.
- SH-FR-173 [Must]: In step 9.3, `database.sqlite` and its companion files, `config.json` and `semaphore.env` on the Pi's USB drive shall be overwritten with `shred -n 1` before deletion.
- SH-FR-104 [Must]: In step 9.3, before the Pi's USB drive is detached, `/mnt/data/containers/semaphore` shall be deleted from the drive.
- SH-FR-105 [Must]: This feature shall not delete the Pi's frozen restic repositories `nas` and `cloud`.
- SH-FR-106 [Must]: In step 9.3, the Pi's USB drive shall be disconnected from the Pi and stored offline.
- SH-FR-174 [Should]: In step 9.3, the Pi's SD card shall be erased in a card reader on a host other than the Pi, with `blkdiscard` or a full overwrite, before re-imaging.
- SH-FR-107 [Must]: In step 9.3, the Pi's SD card shall be re-imaged before the Pi is reused.
- SH-FR-108 [Should]: In step 9.3, the Cloudflare A record `pi.de.int.wahlberger.dev` shall be deleted.
- SH-FR-109 [Must]: Pull request E (step 9.4) shall remove the directory `pi-de-int-wahlberger-dev/`.
- SH-FR-110 [Must]: Pull request E shall move the old key from `ssh_authorized_keys_list` to `ssh_authorized_keys_revoked` in nas and cloud. `<vm-dir>`'s lists do not change, because they never contained the old key.
- SH-FR-156 [Must]: In step 9.4, after pull request E is merged, `--tags ssh_authorized_keys` shall be applied to nas, cloud and the VM from the workstation.
- SH-FR-111 [Must]: After step 9.4, `git grep -n -e 'pi\.de\.int\.wahlberger\.dev' -e 'pi-de-int-wahlberger-dev'` shall match only files in this allowlist:
  - `*/reqs/*` and `*/PLAN*.md`;
  - dated update notes in `architecture/` or `homelab-architecture/`;
  - the NAS README section DOC-O5;
  - the runbook section of `<vm-dir>/README.md`, kept as the historical record of the migration.
- SH-FR-112 [Must]: The NAS README DOC-O5 shall describe restoring from the frozen `nas` repository on the detached drive through a local repository path, without a rest-server.
- SH-FR-113 [Could]: In step 9.5, the 1Password item `Ansible Vault - pi-de-int-wahlberger-dev` shall be archived.

#### M. Documentation
- SH-FR-114 [Must]: Each row of the documentation table ([Documentation updates](#documentation-updates)) shall hold at the end of the step named in that row.

#### N. Public SSH exposure (security)
- SH-FR-115 [Must]: The VM shall have no public IPv6 address.
- SH-FR-116 [Must]: sshd on the VM shall refuse keyboard-interactive authentication (`KbdInteractiveAuthentication no`).
- SH-FR-117 [Must]: sshd on the VM shall accept public-key authentication only (`AuthenticationMethods publickey`).
- SH-FR-118 [Must]: sshd on the VM shall accept logins only for `erikwahlberger` (`AllowUsers erikwahlberger`).
- SH-FR-119 [Should]: sshd on the VM shall set `MaxAuthTries 3`.
- SH-FR-157 [Should]: sshd on the VM shall set `LoginGraceTime 30`.
- SH-FR-120 [Should]: sshd on the VM shall refuse TCP forwarding (`AllowTcpForwarding no`).
- SH-FR-158 [Should]: sshd on the VM shall refuse agent forwarding (`AllowAgentForwarding no`).
- SH-FR-159 [Should]: sshd on the VM shall refuse X11 forwarding (`X11Forwarding no`).
- SH-FR-121 [Must]: If the rendered sshd configuration fails `sshd -t`, then the `security` role shall fail without reloading or restarting sshd.
- SH-FR-122 [Must]: From server creation on, no account on the VM, root included, shall have a usable password: every password field in `/etc/shadow` starts with `!` or `*`.
- SH-FR-123 [Must]: fail2ban's sshd jail shall ban a source IPv4 for 3600 s after 5 failed attempts within 600 s.
- SH-FR-124 [Must]: fail2ban shall never ban 127.0.0.0/8, `<sem-subnet>`, 10.10.0.0/16, 10.243.0.0/16 or cloud-wahlberger-dev's public IPv4.
- SH-FR-211 [Must]: fail2ban's sshd jail shall use a ban action that adds no firewalld rich rule (nftables- or ipset-based).
- SH-FR-125 [Must]: When an SSH login to the VM succeeds from a public source, the owner shall receive an email within 5 min naming the user, the source address and the key fingerprint. The VM itself sends this email, so an attacker who already controls the VM can suppress it (SH-R-01).
- SH-FR-133 [Must]: `<vm-dir>/README.md` shall contain the Cloud Firewall rule table (inbound TCP 22 from `0.0.0.0/0` only; outbound unrestricted; no ICMP, no UDP 9993) and the `hcloud` commands that create it.
- SH-FR-134 [Must]: `<vm-dir>/README.md` shall describe break-glass access: public SSH with the personal key, Hetzner rescue mode as the last resort, and no console password.

#### O. Change control
- SH-FR-160 [Must]: From pull request A until pull request E, `renovate.json` shall contain a package rule with `enabled: false` matching the files under `pi-de-int-wahlberger-dev/`.
- SH-FR-161 [Must]: From pull request A until pull request D, `renovate.json` shall contain a package rule with `enabled: false` matching `<vm-dir>/roles/semaphore/defaults/main.yml`.
- SH-FR-192 [Must]: Pull request A2 shall set `vm_zt_ip`, `vm_zt_iface`, and the "in force" rule set in `docs/zerotier-flow-rules.md`, and shall be merged before the step-3 run.
- SH-FR-193 [Must]: While `vm_zt_ip` is empty, the `caddy` and `cloudflare_dns` roles of `<vm-dir>` shall fail before any change, naming `vm_zt_ip`.
- SH-FR-194 [Must]: While `vm_zt_iface` is empty (steps 0 to 2), the `<vm-dir>` `firewall` role shall configure the public zone, and shall skip the ZeroTier zone's interface binding and rules with a task message naming `vm_zt_iface`.
- SH-FR-220 [Must]: `vm_proxy_design` shall select the design: `primary` (default) or `bridge_fallback`. `<vm-dir>` shall pass its value to the role inputs `caddy_design` and `semaphore_design`.
- SH-FR-221 [Must]: Pull request A3 shall:
  - set `vm_proxy_design` to the step-3 decision and `semaphore_uid` to the value read on the Pi in step 3;
  - add the README observations: SH-AC-05 directives not applied, the SH-AC-08 rollback note, and the SH-AC-04 and SH-AC-61 results with the SH-R-04 text if the fallback is used;
  - change no file outside `<vm-dir>`;
  - be merged after the step-3 tests and before step 4.

### Business Rules

- SH-BR-01: Single writer. Before step 8, only the Pi's Semaphore runs scheduled tasks. The VM's Semaphore runs only the tasks the owner starts in steps 4 to 7. From step 8 on, only the VM's Semaphore runs scheduled tasks. The workstation can apply at any time.
- SH-BR-02: A step-7 task against a host starts only when no Pi schedule that targets that host is due within the next 60 min.
- SH-BR-03: The Pi database is copied to the VM only before step 6 starts. A copy repeated after step 6 has started discards the step-6 Semaphore changes, and step 6 must then be repeated. After step 8, the Pi database is never copied to the VM.
- SH-BR-04: After step 8, `pi-de-int-wahlberger-dev/site.yml` runs only as the step-8 rollback (`--tags cloudflare_dns`).
- SH-BR-05: Pi retirement preconditions. All must hold:
  - a) at least 14 days have passed since step 8;
  - b) the last 7 nightly VM backups ended `Result=success`, and the newest snapshot is at most 26 h old;
  - c) the SH-AC-33 restore test passed within the last 7 days;
  - d) each of the nas, cloud and `<vm-dir>` templates has at least one `Success` task on the VM within the last 7 days;
  - e) no snapshot file under the Pi's `/mnt/data/restic-repos/*/snapshots/` is newer than 2026-10-11 00:00 Europe/Berlin; cloud's `restic_backup_rest_server_host` is `nas.de.int.wahlberger.dev`; the NAS's `restic_backup_decommission_enabled` is `true`;
  - f) `restic check` exits 0 on the Pi's frozen `nas` and `cloud` repositories, read through the Pi's rest-server;
  - g) `restic check --read-data` exits 0 on the NAS repositories `cloud` and `<vm-user>`;
  - h) SH-AC-28 (update and reboot policy) passes;
  - i) SH-AC-29 (recovery after a reboot) passed within the stabilization window;
  - j) SH-AC-39 (rollback material in place) passes.
- SH-BR-06: Allow matrix for ZeroTier traffic involving the VM (accepted by the owner, SH-Q9). "Initiator" is the side that opens the connection. Replies to an allowed connection are allowed. The rules affect only traffic to or from `<vm-zt-ip>`; all other members keep Central's current accept-all behaviour. Public SSH to `<vm-public-ip>` does not cross ZeroTier and is not governed by this matrix.

  | Row | Initiator | Destination | Port | Purpose | Decision |
  |---|---|---|---|---|---|
  | M-01 | `<vm-zt-ip>` | NAS LAN IPv4 | 22/tcp | Semaphore applies the NAS playbook | allow |
  | M-02 | `<vm-zt-ip>` | NAS LAN IPv4 | 8000/tcp | Restic backup to the NAS rest-server | allow |
  | M-03 | home LAN 10.10.0.0/16 | `<vm-zt-ip>` | 22/tcp, 443/tcp | Owner SSH and UI; NAS homepage status ping | allow |
  | M-04 | ZeroTier members 10.243.0.0/16 | `<vm-zt-ip>` | 22/tcp, 443/tcp | Owner devices on ZeroTier; cloud's Uptime Kuma | allow |
  | M-05 | `<cloud-zt-ip>` | `<vm-zt-ip>` | 45876/tcp | Beszel hub → agent | allow |
  | M-06 | home LAN, ZeroTier members | `<vm-zt-ip>` | ICMP echo | Diagnostics | allow |
  | M-07 | `<vm-zt-ip>` | `<cloud-zt-ip>` | 22/tcp | Cloud stays reached over its public IPv4 (SH-D-05) | drop |
  | M-08 | `<vm-zt-ip>` | any other ZeroTier or home-LAN address or port | any | none | drop |
  | M-09 | any other initiator | `<vm-zt-ip>` | any other port | none | drop |
- SH-BR-07: No schedule on the VM's Semaphore starts between 03:00 and 05:30 Europe/Berlin on any day. A migrated schedule that starts in this window stays inactive until the owner re-times it (SH-FR-101).
- SH-BR-08: The old key is revoked in step 9.4 only, never earlier.
- SH-BR-09: Shared secrets:
  - the NAS's `vault_restic_server_<vm-user>_htpasswd_password` equals `<vm-dir>`'s `vault_restic_backup_rest_server_password`;
  - the NAS's `vault_restic_server_<vm-user>_repo_password` equals `<vm-dir>`'s `vault_restic_backup_repo_password`.
- SH-BR-10: Authorized key lists (`ssh_authorized_keys_list`):

  | Period | nas, cloud | `<vm-dir>` |
  |---|---|---|
  | Steps 0 to 5 | personal key, old key | personal key |
  | Step 6 (pull request C) to step 9.4 | personal key, old key, new key (with `from=`) | personal key, new key (with `from=`) |
  | After step 9.4 (pull request E) | personal key, new key | personal key, new key |

  The nas and cloud lists are identical at every step, and the new key's line is the same string in all three playbooks.
- SH-BR-11: The NAS holds no value that decrypts the VM Semaphore's Key Store. `access_key_encryption` is never on the NAS and never in a backup stored on the NAS.
- SH-BR-12: If a step's gate fails, the next step does not start. Either the step's rollback runs, or the step is repeated after the fix.
- SH-BR-13: The Pi's `semaphore.service` is stopped (step 4 and step 8) only when no Pi task is running and no Pi schedule is due within the next 60 min. Otherwise the stop waits.
- SH-BR-14: From the step-4 record until step 8, the owner changes no configuration object in the Pi's Semaphore. Task runs are allowed.
  - If a change is unavoidable before step 6, step 4 is repeated (SH-BR-03).
  - If it is unavoidable after step 6 has started, the owner makes the same change on the VM and records both changes in the pull request D description.
  - Step 8 starts only when the Pi's live configuration-object counts equal the step-4 record plus the recorded changes.
- SH-BR-15: Step 8 starts at most 72 h after the full run ended. Otherwise step 7 is repeated.
- SH-BR-16: Pull requests and "merge is deploy". Until step 8, the Pi's Semaphore can apply `master` to nas and cloud at any time after a merge. Every pull request merged before step 8 is therefore safe to apply at any moment after its merge:

  | PR | Merged in step | Content | Applied by | Why it is safe to apply early |
  |---|---|---|---|---|
  | A | 0 | `<vm-dir>` with empty `vm_zt_ip`; `ssh_authorized_keys_revoked` (empty) and the both-lists check in nas, cloud and `<vm-dir>`; SH-CC-06; Renovate rules (SH-FR-160, SH-FR-161); "before" flow-rule record | workstation (VM); Pi or workstation (nas, cloud) | An empty revoked list and an unchanged effective backup host change nothing on nas and cloud |
  | A2 | 3 (start) | `vm_zt_ip`, `vm_zt_iface`, "in force" flow-rule record | workstation | Only `<vm-dir>` changes, which the Pi does not apply |
  | A3 | 3 (end, after the step-3 tests, before step 4) | `vm_proxy_design` as decided, `semaphore_uid`, README observations (SH-FR-221) | workstation | Only `<vm-dir>` and its README change, which the Pi does not apply |
  | B | 5 | NAS client `ops` and its Vault keys | workstation or Pi | Adds one htpasswd line; nothing uses it until the VM's backup runs |
  | B2 | 5, after the first VM backup | NAS maintenance list (SH-CC-01), freshness path | workstation or Pi | The `ops` repository already exists, so maintenance does not fail (SH-E-18) |
  | C | 6 (draft from step 4) | New key with `from=` in nas, cloud and `<vm-dir>`; the migration notes in its description | workstation | Adds a key usable only from the VM's addresses |
  | C2 | 6, only if SH-FR-191 finds another source address | That address added to the new key's `from=` list in nas, cloud and `<vm-dir>` | workstation | Widens `from=` by one address; the key still works only from the listed sources |
  | C-R | 6, only on a step-6 rollback | New key moved from `ssh_authorized_keys_list` to `ssh_authorized_keys_revoked` in nas, cloud and `<vm-dir>` | workstation | Removes a key that nothing uses after the rollback |
  | D | 8 | `semaphore_dns_cutover_enabled: true`; step-8 documentation; Renovate rule for `<vm-dir>` removed; NAS homepage group label (SH-CC-10) | workstation (`<vm-dir>`, NAS `--tags homepage`); Pi (NAS) until stopped | The NAS change is a cosmetic label; the link URL is unchanged |
  | E | 9.4 | Old key revoked in nas and cloud; `pi-de-int-wahlberger-dev/` removed; documentation; Renovate rule for the Pi removed | workstation | Runs after the point of no return, so no rollback depends on it |
- SH-BR-17: Step 9 runs in the order of SH-D-20. No action of step 9.3 or later starts before every action of step 9.2 has completed.
- SH-BR-18: After a C-R rollback, the revoked new key stays in `ssh_authorized_keys_revoked`. A retry of step 6 generates a fresh keypair (SH-FR-56 repeated), opens a new pull request C, and runs step 6 again from the top.

### Inputs

| Name | Type | Required | Constraints |
|---|---|---|---|
| `<vm-fqdn>`, `<vm-zt-name>`, `<vm-dir>`, `<vm-user>` | str | yes | `ops.de.wahlberger.dev`, `ops.de.int.wahlberger.dev`, `ops-de-wahlberger-dev`, `ops` |
| Hetzner server | `hcloud` input | yes | CX23; Tumbleweed x86_64; nbg1 or fsn1; public IPv4; no IPv6; personal key as the Hetzner SSH key |
| Cloud Firewall | Hetzner firewall, by hand | yes | Attached at creation; inbound TCP 22 from `0.0.0.0/0` only; outbound unrestricted |
| Initial account | cloud-init user-data or manual | yes | `erikwahlberger` with the personal key, passwordless sudo and a locked password, before step 2 |
| `zerotier_network_id` | str | yes | `8056c2e21cc5c789` |
| `vm_zt_ip` | IPv4 | yes | Empty in pull request A; `<vm-zt-ip>` from pull request A2; in 10.243.0.0/16; fixed in Central |
| `vm_proxy_design` | str | yes | `primary` (default, pull request A) or `bridge_fallback`; the step-3 decision is set in pull request A3 (SH-FR-220); during the step-3 fallback test it is passed as `-e vm_proxy_design=bridge_fallback` |
| `caddy_design`, `semaphore_design` | str | yes | Role inputs with the same two values; `vars.yml` sets both to `"{{ vm_proxy_design }}"` (pull request A) |
| `<cloud-zt-ip>` | IPv4 | yes | cloud-wahlberger-dev's member IP in Central; in pull request A |
| `vm_zt_iface` | str | yes | Empty in pull request A; read on the VM in step 3 (`ip -br link`) and set in pull request A2; feeds `firewall_zerotier_interface` |
| `cloudflare_dns_ip` | IPv4 | yes | Role default `ansible_facts.default_ipv4.address` = `<vm-public-ip>` (SH-A-19) |
| `cloudflare_dns_extra_a_records` | list of `{record, value}` | yes | `[{record: ops.de.int.wahlberger.dev, value: "{{ vm_zt_ip }}"}]` |
| `cloudflare_dns_cname_target` | str | yes | `<vm-zt-name>` (role default `inventory_hostname`) |
| `cloudflare_dns_cnames_enabled` | bool | yes | Equals `semaphore_dns_cutover_enabled` |
| `semaphore_dns_cutover_enabled` | bool | yes | `false` until pull request D; then `true` |
| `semaphore_require_existing_db` | bool | yes | Role default `false`; production `true` |
| `semaphore_image` | str | yes | At step 4, the tag running on the Pi |
| `semaphore_url` | str | yes | `https://semaphore.de.int.wahlberger.dev` |
| `semaphore_oidc_client_id` | str | yes | `63093482-d2cc-4c77-89df-9f6ff78b160e` |
| `semaphore_network_subnet` | IPv4 CIDR | yes | `<sem-subnet>`; set in pull request A; outside 10.10.0.0/16 and 10.243.0.0/16 |
| `semaphore_uid` | int | yes | Empty by default (the `semaphore` role then fails, SH-FR-210); read on the Pi read-only in step 3 and set in pull request A3; re-checked on the VM in step 4 (SH-AC-53, SH-A-32) |
| `caddy_bind_address` | IPv4 | yes | `"{{ vm_zt_ip }}"` |
| `caddy_allowed_sources` | list of CIDR | yes | `10.243.0.0/16`, `10.10.0.0/16` |
| `caddy_sites` | list | yes | One entry: `semaphore.de.int.wahlberger.dev` → `127.0.0.1:3000` (fallback: `semaphore:3000`) |
| `security_ssh_allow_users` | list[str] | yes | `[erikwahlberger]` |
| `security_fail2ban_findtime`, `security_fail2ban_ignoreip` | int, list | yes | 600; the SH-FR-124 list |
| `ssh_authorized_keys_list` | list[str] | yes | SH-BR-10; entries are full `authorized_keys` lines, options allowed |
| `ssh_authorized_keys_revoked` | list[str] | no | Default `[]`; the old key from pull request E |
| `beszel_agent_hub_key` | str | yes | The value used on the other hosts |
| `restic_backup_*` (VM) | various | yes | Host `nas.de.int.wahlberger.dev`, port 8000, username `ops`, `restic_backup_forget_enabled: false`, `restic_backup_on_calendar: "*-*-* 05:00:00"`, paths per SH-FR-78, SH-FR-80, SH-FR-151, SH-FR-171 |
| Vault values copied verbatim from the Pi | str (Vault) | yes | `vault_cloudflare_dns_api_token`, `vault_semaphore_admin_password`, `vault_semaphore_access_key_encryption`, `vault_semaphore_cookie_hash`, `vault_semaphore_cookie_encryption`, `vault_semaphore_oidc_client_secret`, `vault_notify_failure_resend_api_key` |
| New `<vm-dir>` Vault values | str (Vault) | yes | `vault_restic_backup_repo_password`, `vault_restic_backup_rest_server_password` (32 alphanumeric characters each) |
| NAS inputs | list, str (Vault) | yes | Pull request B: `restic_server_clients` entry, `vault_restic_server_ops_htpasswd_password`, `vault_restic_server_ops_repo_password`. Pull request B2: maintenance list (SH-CC-01), freshness path |
| New key | ed25519 keypair | yes | Comment `semaphore-automation@ops.de.wahlberger.dev` |
| Flow rules | Central rules text | yes | Implements SH-BR-06 |
| `<vm-dir>` Vault password | str (1Password, Key Store) | yes | 1Password item `Ansible Vault - ops-de-wahlberger-dev`; the same value in the Semaphore Key Store |

### Outputs

| Name | Type | Constraints |
|---|---|---|
| VM services | systemd units | `sshd`, `fail2ban`, `firewalld`, `caddy`, `semaphore`, `zerotier`, `beszel-agent` active; timers for `restic-backup`, `zypper-dup` and `disk-space-check` active |
| A record `<vm-fqdn>` | DNS | Unproxied; `<vm-public-ip>` |
| A record `<vm-zt-name>` | DNS | Unproxied; `<vm-zt-ip>` |
| `semaphore.de.int.wahlberger.dev` | DNS CNAME | Points at `pi.de.int.wahlberger.dev` until step 8, at `<vm-zt-name>` afterwards; unproxied |
| TLS certificate | X.509 | Issued by Let's Encrypt for `semaphore.de.int.wahlberger.dev`; served on `<vm-zt-ip>:443` only |
| Semaphore state on the VM | SQLite | Migrated DB; templates per SH-FR-63; schedules per SH-FR-101; no API tokens or integrations |
| NAS repository `ops` | restic repository | `/mnt/data/restic-repos/ops`, append-only, retention by the NAS |
| Monitoring entries | Uptime Kuma monitors, Beszel system | SH-FR-91 to SH-FR-95 |
| Flow-rule record | Markdown | `<vm-dir>/docs/zerotier-flow-rules.md`, before (pull request A) and in force (pull request A2), dated |
| Emails | Resend | Failure, reboot heads-up, backup success and public-login emails |
| Retired Pi | state | Semaphore data overwritten and deleted; USB drive offline with frozen repositories; SD card erased and re-imaged; DNS record deleted; playbook directory removed |
| Documentation | Markdown | Every row in [Documentation updates](#documentation-updates) |

### Error Cases

| ID | Condition | Expected behaviour |
|---|---|---|
| SH-E-01 | `semaphore_require_existing_db: true` and no database file on the VM | The `semaphore` role fails before starting the container and names the path. No empty database is created |
| SH-E-02 | The VM's `access_key_encryption` differs from the Pi's | The step-4 `--check` tasks fail to decrypt and the step-4 gate fails. Correct the Vault value (SH-FR-180 makes this unlikely) |
| SH-E-03 | The copied database fails `PRAGMA integrity_check` | The copy is not placed. Repeat the copy after a clean stop |
| SH-E-04 | The VM's `semaphore_image` differs from the Pi's running tag at step 4 | The step-4 gate fails before the first start. Pin the Pi's tag |
| SH-E-05 | The ZeroTier member is not authorized, or ZeroTier on the VM is down, in step 3 | The ZeroTier path fails and the step-3 gate fails. Public SSH is used to fix it |
| SH-E-06 | ZeroTier on the VM is down after step 3 | Tasks against the NAS fail with `unreachable`, and the UI is unreachable. Uptime Kuma alerts within 5 min. The owner repairs over public SSH |
| SH-E-07 | `<vm-zt-ip>` changes | The `<vm-zt-name>` record and Caddy's bind address are stale. Uptime Kuma alerts. Fix the IP in Central, update `vm_zt_ip`, apply `--tags cloudflare_dns,caddy` |
| SH-E-08 | The flow rules block an allow-matrix row or an existing member's traffic | The SH-AC-11 or SH-AC-13 gate fails. Restore the saved rule set and correct the rules |
| SH-E-09 | The flow rules allow a connection the matrix does not list | The SH-AC-12 deny test fails. Correct the rules before step 4 |
| SH-E-10 | The Cloud Firewall is detached or gains an inbound rule | The host still accepts only TCP 22 on the public interface, and Caddy listens on `<vm-zt-ip>` only. The SH-AC-03 scan shows the drift |
| SH-E-11 | DNS-01 fails (Cloudflare API error or invalid token) | Caddy retries. Before the first certificate exists, the step-4 gate fails. After that, the existing certificate keeps serving until it expires |
| SH-E-12 | `cloudflare_dns` creates a second record instead of updating the CNAME | The task fails with a Cloudflare API error. Set the CNAME by hand, then re-run to confirm no change |
| SH-E-13 | The Pi playbook is run after step 8 | The CNAME points back at the stopped Pi and Uptime Kuma alerts. Re-apply `<vm-dir>` with `--tags cloudflare_dns` |
| SH-E-14 | A Pi schedule and a VM step-7 task hit the same host | One task fails on the package-manager lock. Re-run in a free slot |
| SH-E-15 | A self-run includes the `semaphore` or `zerotier` tag | A `semaphore` restart kills the task. Apply those tags from the workstation |
| SH-E-16 | `zypper-dup.service` fails (for example on a solver conflict) | An email arrives within 10 min. No reboot happens. The next weekly run retries; the owner resolves the conflict by hand |
| SH-E-17 | The VM reboots during a running task | The task is aborted. After boot, every service is back within 5 min. SH-BR-07 keeps schedules out of the update window |
| SH-E-18 | The NAS maintenance run starts before the `ops` repository exists | Prevented by merging pull request B2 only after the first VM backup. If it happens anyway, the run fails and emails |
| SH-E-19 | The backup fails (NAS unreachable, rest-server down, or the shared 100 GiB quota full) | An email arrives within 10 min. After 26 h, the NAS freshness check also alerts |
| SH-E-20 | The NAS prune guard trips on the `ops` repository (client clock skew) | Maintenance ends `failed` and emails; nothing is pruned. SH-FR-22 prevents skew |
| SH-E-21 | `/` reaches 85 % | The `disk_space` email arrives within 20 min |
| SH-E-22 | The VM runs out of memory during a task | The task fails. SH-NFR-08 detects it in the full run |
| SH-E-23 | The Pi database is copied again after step 6 or after step 8 | Before step 8, step 6 is repeated. After step 8, the copy is forbidden |
| SH-E-24 | The old key is revoked before step 9.4 | A rollback to the Pi can no longer reach the hosts. Re-authorize the old key from the workstation |
| SH-E-25 | The Pi's USB drive is detached with Semaphore data still on it | The step-9 gate fails (SH-AC-41). Reattach the drive, overwrite and delete the data |
| SH-E-26 | ZeroTier Central is unavailable | Members keep their cached configuration. Authorization and rule changes wait |
| SH-E-27 | GitHub is unreachable, or the VM has no public IPv4 | Cloning fails and the task fails |
| SH-E-28 | The Beszel hub cannot reach the VM agent | The hub shows the VM as down. Check matrix row M-05 and SH-FR-09 |
| SH-E-29 | Internet scanners or brute-force attempts hit TCP 22 | sshd offers `publickey` only. fail2ban bans the source for 3600 s after 5 failures in 600 s. No email per ban |
| SH-E-30 | A role change renders an sshd configuration that fails `sshd -t` | The role fails; sshd keeps its previous configuration. If a lockout happens anyway, use rescue mode |
| SH-E-31 | fail2ban bans the owner's public address | The owner connects through `<vm-zt-name>` (ZeroTier sources are never banned) or waits 3600 s |
| SH-E-32 | The public-login email cannot be sent (Resend error) | The login is not blocked. The failure is logged in the journal; there is no retry |
| SH-E-33 | Caddy starts before `<vm-zt-ip>` exists (boot or ZeroTier restart) | The bind fails and Caddy restarts until the address exists. The UI is back within the SH-FR-76 limit |
| SH-E-34 | Caddy sees a NAT or bridge address instead of the client address | The allowlist answers 403 to every request (fails closed). The step-3 test SH-AC-51 detects this and triggers the fallback decision |
| SH-E-35 | A login with a stolen personal key from a public source | The SH-FR-125 email arrives within 5 min, unless the attacker suppresses it after gaining root, or the exploit is pre-authentication (SH-R-01). The README incident note covers the response |
| SH-E-36 | The Pi's `semaphore.service` does not start again after the step-4 copy | The owner reads `journalctl -u semaphore` and starts it again. The database was only read. Step 4 halts until the Pi is active, because the Pi is still the writer (SH-BR-01). Uptime Kuma's semaphore monitor alerts |
| SH-E-37 | A Pi task is running, or a Pi schedule is due within 60 min, at the planned stop (step 4 or 8) | The stop waits (SH-BR-13) |
| SH-E-38 | A Pi configuration object changes after the step-4 record | Handled per SH-BR-14. The step-8 count check detects an unrecorded change |
| SH-E-39 | More than 72 h pass between the full run and step 8 | Step 7 is repeated (SH-BR-15) |
| SH-E-40 | The same key is in `ssh_authorized_keys_list` and `ssh_authorized_keys_revoked` | The role fails before any change, naming the key (SH-FR-190) |
| SH-E-41 | The NAS sees the VM's SSH source outside the `from=` list | The automation login to the NAS is refused and the step-6 gate fails. Add the observed address per SH-FR-191 |
| SH-E-42 | An access-key row fails to decrypt in a step-4 `--check` task of the nas or cloud template | The step-4 gate fails; see SH-E-02. Rows used by neither template go on the deletion list (SH-FR-177) |
| SH-E-43 | `<zt-iface>` differs from the bound name, or the binding is missing | ZeroTier traffic falls into the default zone (`ssh` only), and the UI is unreachable. Uptime Kuma alerts. Correct `<zt-iface>` and apply `--tags firewall` |
| SH-E-44 | Renovate opens a pull request for `pi-de-int-wahlberger-dev/` or for `<vm-dir>`'s `semaphore_image` before its rule is removed | The rule is missing or wrong. Close the pull request unmerged and fix `renovate.json` |
| SH-E-45 | The workstation still holds the database copy after step 4, or the key copy after step 6 | The step's gate (SH-AC-55 or SH-AC-24) fails until the copy is deleted |
| SH-E-46 | SH-AC-05 has not passed 60 min after server creation (SH-FR-162) | The owner deletes the server and repeats step 1. No hardening is attempted on a server that has exceeded the bound |
| SH-E-47 | SH-AC-51 fails in the bridge fallback | Step 3 halts, and step 4 does not start. The step-3 rollback runs. The design returns to requirements for the owner's decision (SH-D-12) |
| SH-E-48 | `semaphore_uid` is empty when the `semaphore` role runs (pull request A3 not merged) | The role fails before any change, naming `semaphore_uid` (SH-FR-210) |

### Acceptance Criteria

Scenario SH-AC-01 [S]: The playbook skeleton passes CI (SH-FR-10 to SH-FR-13, SH-FR-135 to SH-FR-143, SH-FR-62)
- Given pull request A
- When CI runs
- Then the `validate` job for `<vm-dir>` passes ansible-lint (production profile), yamllint, `ansible-galaxy` install, `--syntax-check` and the vault-encryption check
- And the `molecule` job for `<vm-dir>` passes with zero changes on the second converge
- And `site.yml` contains exactly the SH-FR-13 roles, each tagged with its own name
- And `hosts.yml` lists only `ops.de.wahlberger.dev`; `group_vars/all/` holds `vars.yml`, an encrypted `vault.yml` and `vault.yml.example`; `.vault_pass.sh` reads `op://DevOps/Ansible Vault - ops-de-wahlberger-dev/password`; `.yamllint`, `.ansible-lint`, `README.md` and `CLAUDE.md` exist
- And every `ssh_authorized_keys_list` in nas, cloud and `<vm-dir>` contains the personal key

Scenario SH-AC-02 [H]: The provisioning contract and a safe stock configuration (SH-FR-01 to SH-FR-04, SH-FR-115, SH-FR-122)
- Given step 1 has completed
- When the owner runs `hcloud server describe <vm>` and `hcloud firewall describe <vm-fw>`, then logs in as `erikwahlberger` and runs `sudo sshd -T | grep permitrootlogin` and ``sudo awk -F: '$2 !~ /^[!*]/ {print $1}' /etc/shadow``
- Then the server type is `cx23`, a public IPv4 is assigned, and no IPv6 is assigned
- And the firewall is applied, with exactly one inbound rule (TCP 22 from `0.0.0.0/0`)
- And `permitrootlogin` is `no`, `prohibit-password` or `without-password`
- And the `awk` command prints nothing
- And `/etc/os-release` shows `ID="opensuse-tumbleweed"`, and `uname -m` prints `x86_64`

Scenario SH-AC-03 [H]: Only SSH is reachable from the internet (SH-FR-04, SH-FR-06, SH-FR-07, SH-FR-130, SH-FR-187, SH-FR-220, SH-NFR-03)
- Given step 4 has completed
- When the owner runs, from cloud's public address, `nmap -Pn -p- <vm-public-ip>` and `nmap -Pn -sU --top-ports 100 -p U:9993 <vm-public-ip>`; and, on the VM, `firewall-cmd --zone=<public-iface-zone> --list-all`, `ss -tlnp` and `podman port semaphore`
- Then nmap reports exactly one open TCP port, 22, and no open UDP port
- And the public zone lists service `ssh` only, with no ports, and `firewall-cmd --permanent --zone=public --list-rich-rules` prints nothing
- And every listener on `0.0.0.0`, `[::]` or `<vm-public-ip>` is sshd (22) or beszel-agent (45876)
- And, in the primary design, `ss` shows Caddy on `<vm-zt-ip>:443` only, and `podman port semaphore` shows `3000/tcp -> 127.0.0.1:3000` only
- And, in the bridge fallback, `podman port caddy` shows `443/tcp -> <vm-zt-ip>:443` only, and `podman port semaphore` shows nothing

Scenario SH-AC-04 [H]: The host firewall is the effective gate (SH-FR-06, SH-FR-09, SH-FR-128, SH-FR-185)
- Given step 3, with Caddy running and a home-LAN client that gets an HTTP response from `https://<vm-zt-ip>/` (SH-AC-51)
- When (primary design only) the owner runs `firewall-cmd --zone=zerotier --remove-service=https` (runtime only), repeats the client request, runs `firewall-cmd --zone=zerotier --add-service=https` (runtime only) and repeats the request again
- Then the request with the service removed gets no connection (timeout or reset), and the request after re-adding gets an HTTP response again
- And in the bridge fallback this zone test is not a gate: its result is recorded in `<vm-dir>/README.md` under SH-R-04 through pull request A3, and the clauses below still apply
- And `firewall-cmd --get-zone-of-interface=<zt-iface>` prints `zerotier`, and `firewall-cmd --permanent --zone=zerotier --list-interfaces` lists `<zt-iface>`
- And `firewall-cmd --permanent --zone=<public-iface-zone> --list-services` prints only `ssh`
- When the owner adds a temporary Cloud Firewall rule allowing TCP 45876 from cloud's public IPv4/32, runs `nc -z -w5 <vm-public-ip> 45876` from cloud, and deletes the rule
- Then `nc` fails to connect, and `hcloud firewall describe` again shows exactly one inbound rule (TCP 22 from `0.0.0.0/0`)

Scenario SH-AC-05 [H]: SSH hardening (SH-FR-14 to SH-FR-19, SH-FR-22, SH-FR-116 to SH-FR-120, SH-FR-157 to SH-FR-159, SH-NFR-14)
- Given step 2 has completed
- When the owner runs `hostnamectl --static`, `sudo sshd -T`, `sudo -n true`, `ls -d /var/log/journal`, `timedatectl show -p NTPSynchronized` and `sudo fail2ban-client status sshd`; and, from the internet, `ssh -v -o PreferredAuthentications=none <vm-public-ip>`
- Then `hostnamectl` prints `ops.de.wahlberger.dev`
- And `sshd -T` shows `passwordauthentication no`, `kbdinteractiveauthentication no`, `permitrootlogin no`, `authenticationmethods publickey` and `allowusers erikwahlberger`
- And for each of the Should directives SH-FR-119, SH-FR-157, SH-FR-120, SH-FR-158 and SH-FR-159 that is applied, `sshd -T` shows its value (`maxauthtries 3`, `logingracetime 30`, `allowtcpforwarding no`, `allowagentforwarding no`, `x11forwarding no`). A directive not applied is recorded in `<vm-dir>/README.md` through pull request A3
- And `sudo -n true` exits 0, the journal directory exists, `NTPSynchronized=yes`, and the jail is active
- And the `ssh -v` output lists only `publickey` under "Authentications that can continue"

Scenario SH-AC-06 [H]: Alert email paths work (SH-FR-20, SH-FR-21, SH-FR-72, SH-FR-83, SH-FR-144, SH-FR-145, SH-FR-206)
- Given step 5 has completed
- When the owner starts `notify-failure-immediate@restic-backup.service` and `notify-failure-immediate@zypper-dup.service` by hand, and reads the monitored units' `OnFailure=` lines
- Then two emails arrive within 10 min, each naming its unit
- And `caddy.service`, `semaphore.service`, `zerotier.service` and `beszel-agent.service` name `notify-failure@%n.service`, while `restic-backup.service` and `zypper-dup.service` name `notify-failure-immediate@%n.service`
- And the rendered `disk_space` configuration lists `/` with threshold 85 and interval 15min
- And the rendered `notify_failure` configuration has crash threshold 5 and window 600 s

Scenario SH-AC-07 [H]: Podman lessons are carried over (SH-FR-23, SH-FR-24)
- Given step 4 has completed, and the owner reboot of SH-AC-09 (step 3) has happened
- When the owner runs `sysctl net.ipv4.ip_forward` and `sudo podman exec semaphore getent hosts ops.de.wahlberger.dev`
- Then the first prints `net.ipv4.ip_forward = 1`, and the second prints `<vm-public-ip>`

Scenario SH-AC-08 [H]: Snapper pairs exist on a btrfs root (SH-FR-25)
- Given step 2 has run zypper transactions
- When the owner runs `sudo snapper list`
- Then, on a btrfs root, a `pre` and a `post` snapshot exist for the last transaction
- And on another root filesystem, `<vm-dir>/README.md` names the Hetzner snapshot as the update rollback (added through pull request A3)

Scenario SH-AC-09 [H]: The ZeroTier identity and zone binding persist (SH-FR-26, SH-FR-27, SH-FR-185)
- Given step 3 has completed
- When the owner records `sudo podman exec zerotier zerotier-cli info`, restarts `zerotier.service`, reboots the VM, and records it again together with `firewall-cmd --get-zone-of-interface=<zt-iface>`
- Then the node ID is the same all three times
- And after the reboot, `<zt-iface>` is in zone `zerotier`, and `zerotier-cli listnetworks` shows `8056c2e21cc5c789` as `OK` with `<vm-zt-ip>`

Scenario SH-AC-10 [H]: Membership is manual and the IP is fixed (SH-FR-28, SH-FR-29, SH-FR-205)
- Given step 3 has completed
- When the owner opens the member in Central and runs `git grep -n -i -e 'zerotier.*token' -e 'ZT_TOKEN'`
- Then the member is authorized with `<vm-zt-ip>` as a fixed assignment, and the grep prints nothing

Scenario SH-AC-11 [H]: Allowed ZeroTier paths work (SH-FR-08, SH-FR-09, SH-FR-30)
- Given step 3 has completed
- When the owner runs, from the VM, `nc -z -w5 <nas-lan-ip> 22` and `nc -z -w5 <nas-lan-ip> 8000`; from cloud, `nc -z -w5 <vm-zt-ip> 443` and `nc -z -w5 <vm-zt-ip> 45876`; and from a home-LAN client, `ssh ops.de.int.wahlberger.dev true`
- Then every command exits 0

Scenario SH-AC-12 [H]: Deny test for the flow rules (SH-FR-31, SH-FR-32, SH-FR-09)
- Given step 3 has completed
- When the owner runs, from the VM, `nc -z -w5` against `<nas-lan-ip>` ports 445, 2222 and 443, against `10.10.0.1` port 53, and against `<cloud-zt-ip>` port 22; and, from a home-LAN client, `nc -z -w5 <vm-zt-ip> 45876` and `nc -z -w5 <vm-zt-ip> 8080`
- Then every command fails

Scenario SH-AC-13 [H]: Rule sets are recorded and existing traffic is unchanged (SH-FR-33, SH-FR-34, SH-FR-35, SH-FR-132, SH-FR-197 to SH-FR-199)
- Given the flow rules were created in Central's Flow Rules editor in step 3
- When the owner opens `<vm-dir>/docs/zerotier-flow-rules.md` and runs the checks of SH-FR-35 and SH-FR-197 to SH-FR-199, comparing with the step-0 baseline
- Then the file holds the dated "before" rule set (Central's default) and the dated "in force" rule set, and links to Central's rules-language reference
- And all four checks succeed

Scenario SH-AC-14 [H]: DNS before the cut-over (SH-FR-36, SH-FR-37, SH-FR-131)
- Given step 3 has completed with `semaphore_dns_cutover_enabled: false`
- When the owner runs `dig +short A ops.de.wahlberger.dev @1.1.1.1`, `dig +short A ops.de.int.wahlberger.dev @1.1.1.1` and `dig +short CNAME semaphore.de.int.wahlberger.dev @1.1.1.1`, then re-runs `--tags cloudflare_dns`
- Then the first prints `<vm-public-ip>` (equal to `hcloud server ip <vm>`), and the second prints `<vm-zt-ip>`
- And the CNAME is still `pi.de.int.wahlberger.dev.`
- And the re-run reports `changed=0`

Scenario SH-AC-15 [H]: TLS and the proxy with Semaphore running (SH-FR-39, SH-FR-40)
- Given step 4 has completed
- When a home-LAN client runs `curl -sS --resolve semaphore.de.int.wahlberger.dev:443:<vm-zt-ip> https://semaphore.de.int.wahlberger.dev/api/ping`
- Then the response is HTTP 200 with a certificate issued by Let's Encrypt for `semaphore.de.int.wahlberger.dev`
- And `sudo podman images` lists the locally built Caddy image with the Cloudflare module

Scenario SH-AC-16 [H]: Container name resolution and SSH reachability (SH-FR-41, SH-FR-55)
- Given step 4 has completed
- When the owner runs `sudo podman exec semaphore getent hosts <name>` for `nas.de.int.wahlberger.dev`, `cloud.wahlberger.dev`, `ops.de.wahlberger.dev` and `github.com`; and `sudo podman exec semaphore ssh -o BatchMode=yes -o ConnectTimeout=5 <host> true` against the first three
- Then each `getent` answer equals `dig +short <name> @1.1.1.1`
- And each `ssh` fails with `Permission denied`, not with a timeout

Scenario SH-AC-17 [S]: Vault values are carried over (SH-FR-42 to SH-FR-46, SH-FR-146 to SH-FR-148, SH-FR-201)
- Given both Vaults are unlocked through 1Password
- When the owner pipes each Vault key named in SH-FR-43, SH-FR-44, SH-FR-146, SH-FR-201, SH-FR-46, SH-FR-147 and SH-FR-148 from `ansible-vault view` of both `vault.yml` files through `sha256sum`, without printing the values
- Then each pair of hashes is equal
- And `<vm-dir>`'s `vars.yml` sets `semaphore_url` and `semaphore_oidc_client_id` to the SH-FR-42 and SH-FR-45 values

Scenario SH-AC-18 [H]: Clean stop, complete copy and matching version (SH-FR-49, SH-FR-50, SH-FR-175, SH-FR-176, SH-FR-200, SH-FR-203, SH-FR-204, SH-BR-13)
- Given the Pi's Semaphore task list shows no running task and no schedule due within 60 min
- When the owner stops the Pi's `semaphore.service`, runs `systemctl is-active semaphore` and `ls /mnt/data/containers/semaphore/data/`, copies the database and any companion files, and starts the service again
- Then `is-active` prints `inactive`
- And every `database.sqlite*` file listed was copied
- And on the workstation, after `PRAGMA wal_checkpoint(TRUNCATE)`, `PRAGMA integrity_check` prints `ok`, and no companion file remains beside the copy
- And `ls <semaphore_data_dir>/data/` on the VM shows `database.sqlite` with no `-wal`, `-shm` or `-journal` file before the first start
- And `podman inspect --format '{{.ImageName}}' semaphore` prints the same image on the Pi and on the VM
- And the Pi's service was active again at most 10 min after the stop

Scenario SH-AC-19 [H]: The missing-database guard (SH-FR-52)
- Given step 3, with no database file on the VM
- When the owner runs `site.yml --tags semaphore`
- Then the run fails before the container starts, with a message naming `<semaphore_data_dir>/data/database.sqlite`
- And the file still does not exist

Scenario SH-AC-20 [H]: The migrated state matches the live Pi (SH-FR-51, SH-FR-53, SH-FR-54)
- Given the step-4 record taken from the Pi's API before the stop, and no task has yet run on the VM
- When the owner reads the same counts and the newest task ID from the VM's Semaphore API, and opens the VM's schedule list
- Then every count and the newest task ID equal the step-4 record
- And every schedule on the VM is inactive

Scenario SH-AC-21 [H]: Both logins work on the VM (SH-FR-47, SH-FR-48, SH-FR-202)
- Given the workstation's `/etc/hosts` maps `semaphore.de.int.wahlberger.dev` to `<vm-zt-ip>`
- When the owner logs in as `erikwahlberger` with the Vault password, logs out, and then uses "Sign in with Pocket ID"
- Then both logins succeed, and the Pocket ID session shows the same projects as on the Pi
- And Pocket ID's client list shows the Semaphore client with the unchanged client ID and redirect URI, and no client created during this feature

Scenario SH-AC-22 [H]: Every access-key row decrypts or is listed (SH-FR-43, SH-FR-51, SH-FR-177)
- Given SH-AC-20 has passed, and the Key Store holds only migrated entries
- When the owner runs the nas and cloud templates from the VM with `--check`, and lists the access keys in the VM's Key Store
- Then each task ends with `failed=0 unreachable=0`, with no error mentioning decryption or a Vault password
- And every access key either was used by one of these tasks or appears on the deletion list in the migration notes (Pi-only rows included)

Scenario SH-AC-23 [S]: Key lists after pull request C (SH-FR-56, SH-FR-57, SH-FR-62, SH-FR-126, SH-BR-10)
- Given pull request C is merged
- When the owner reads `ssh_authorized_keys_list` in nas, cloud and `<vm-dir>`, and runs `git grep -n 'PRIVATE KEY'`
- Then the lists match the "step 6 to step 9.4" row of SH-BR-10
- And the new key's line is the same string in all three files, with the comment `semaphore-automation@ops.de.wahlberger.dev` and a `from=` option listing exactly `<vm-public-ip>`, `<vm-zt-ip>` and `<sem-subnet>`, plus any SH-FR-191 address
- And the grep prints nothing

Scenario SH-AC-24 [H]: The new key is in use and the old entry is kept (SH-FR-58, SH-FR-59, SH-FR-181)
- Given step 6 has completed
- When the owner runs the nas template from the VM, reads `journalctl -u sshd` on the NAS for that time, opens the VM's Key Store and template settings, and searches the workstation for the new private key
- Then the accepted publickey fingerprint equals `ssh-keygen -lf <new key>.pub`
- And the Key Store holds two automation entries, and the nas, cloud and `<vm-dir>` templates use the new one
- And no file with the new private key exists on the workstation

Scenario SH-AC-25 [H]: Templates and cleaned database (SH-FR-63, SH-FR-64, SH-FR-65, SH-FR-149, SH-FR-150, SH-FR-178, SH-FR-179)
- Given step 6 has completed
- When the owner opens the VM's Semaphore projects and template settings, and runs `sqlite3 database.sqlite .dump | grep -c -e 'pi.de.int.wahlberger.dev' -e 'pi-de-int-wahlberger-dev' -e '/mnt/data'` on a copy of the VM's database
- Then exactly the nas, cloud and `<vm-dir>` templates exist, each with `site.yml` and its playbook's production inventory
- And the `<vm-dir>` template uses the `<vm-dir>` Vault password secret and passes `--skip-tags semaphore,zerotier` and `-e common_upgrade=false`
- And every remaining match belongs to the retained old-key Key Store entry (SH-D-22)
- And the VM's Semaphore lists no API token and no integration

Scenario SH-AC-26 [H]: A self-run does not disrupt the VM (SH-FR-66 to SH-FR-69)
- Given step 6 has completed
- When the owner records `systemctl show -p ActiveEnterTimestamp semaphore.service zerotier.service firewalld.service sshd.service` and `rpm -qa --last | head -1`, runs the `<vm-dir>` template from the VM, and records both again
- Then all four timestamps and the newest package are unchanged
- And the task has an end time within 60 min of its start
- And the log contains no task from `common : Refresh repositories and upgrade all packages` with status `changed`

Scenario SH-AC-27 [S]: README content (SH-FR-70, SH-FR-90, SH-FR-96, SH-FR-133, SH-FR-134)
- Given pull request A
- When the owner reads `<vm-dir>/README.md`
- Then it contains:
  - steps 0 to 9 with gate scenarios and a rollback each, and the PR table;
  - the workstation command for the excluded roles, with the `semaphore_image` note and the `-e ansible_host=ops.de.int.wahlberger.dev` hint;
  - the database restore procedure;
  - the Cloud Firewall rule table and its `hcloud` commands;
  - the break-glass section.

Scenario SH-AC-28 [H]: The update and reboot policy (SH-FR-71, SH-FR-73, SH-FR-74, SH-FR-75, SH-FR-195, SH-NFR-13)
- Given the VM has run for at least 14 days
- When the owner runs `systemctl list-timers zypper-dup.timer` and `systemctl show -p Result -p ExecMainExitTimestamp zypper-dup.service`, reads the rebootmgr configuration, and runs `last -x reboot`
- Then the timer fires on Sunday at 04:00, and the last successful run is at most 8 days old
- And rebootmgr uses strategy `maint-window`, start 04:00, duration 1h, on Sunday
- And every reboot not started by the owner falls inside the window and was preceded by a heads-up email

Scenario SH-AC-29 [H]: Recovery after a reboot (SH-FR-76, SH-FR-27, SH-FR-07)
- Given step 8 has completed
- When the owner runs `sudo systemctl reboot` on the VM and polls `https://semaphore.de.int.wahlberger.dev/api/ping` from a home-LAN client every 10 s
- Then HTTP 200 returns within 5 min of the reboot command
- And the ZeroTier node ID is unchanged
- And the SH-AC-03 Caddy listener clause for the design in use holds again

Scenario SH-AC-30 [S]: The backup unit configuration (SH-FR-77, SH-FR-80, SH-FR-81, SH-FR-82, SH-FR-151, SH-FR-152, SH-FR-171)
- Given pull request A
- When the owner renders the VM's `restic_backup` templates
- Then the timer has `OnCalendar=*-*-* 05:00:00` and `Persistent=true`
- And the repository URL is `rest:http://ops:…@nas.de.int.wahlberger.dev:8000/ops/`
- And the script contains no `forget` and no `prune`, and does contain `restic check --read-data-subset=10%`
- And the backup paths and excludes keep `config.json`, every `*.env` file and `identity.secret` out of every backup

Scenario SH-AC-31 [H]: The first backup succeeds (SH-FR-77, SH-FR-78, SH-FR-80, SH-FR-84, SH-FR-88, SH-FR-151, SH-FR-171, SH-BR-11, SH-NFR-06)
- Given pull request B is applied on the NAS
- When the owner starts `restic-backup.service` and runs `restic ls latest` on the VM
- Then the unit ends `Result=success` within 10 min
- And the snapshot contains the consistent database copy
- And it contains no `config.json`, no `*.env` file and no `identity.secret`
- And the 1Password item for `<vm-dir>` holds `vault_restic_backup_repo_password`

Scenario SH-AC-32 [H]: NAS maintenance covers both repositories (SH-FR-85, SH-FR-86, SH-FR-87, SH-FR-153, SH-FR-154, SH-FR-155, SH-BR-09)
- Given pull request B2 is applied on the NAS after SH-AC-31
- When the owner starts `restic-server-maintenance.service` and reads its journal, and diffs the rendered `cloud` commands against the version before SH-CC-01
- Then the journal shows, for `ops`: prune guard, forget with keep 7, 4 and 6, prune, check
- And the unit ends `Result=success`
- And the `cloud` command diff is empty
- And, where SH-FR-87 is applied, `backup_disk_freshness_checks` contains the `ops` path with 26 h

Scenario SH-AC-33 [H]: The restore test (SH-FR-89)
- Given SH-AC-31 has passed
- When the owner runs `restic restore latest --target /tmp/restore-test` on the VM, then `sqlite3` with `PRAGMA integrity_check` and the project, template and access-key counts on the restored file
- Then the check prints `ok`, and the counts equal the live database's counts

Scenario SH-AC-34 [H]: A Hetzner snapshot exists before a risky step (SH-FR-102)
- Given the owner chose to take a snapshot before step 4 or step 8
- When the owner runs `hcloud image list --type snapshot`
- Then a snapshot of the VM created within the last hour is listed

Scenario SH-AC-35 [H]: Monitoring after the cut-over (SH-FR-92, SH-FR-93, SH-NFR-12)
- Given step 8 has completed
- When the owner opens Uptime Kuma and the Beszel hub
- Then, where SH-FR-92 is applied, a TCP monitor for `ops.de.wahlberger.dev:22` exists and is up
- And the semaphore HTTP monitor (SH-AC-58) is up and reaches the VM
- And Beszel lists the VM as up, with CPU, memory and container metrics

Scenario SH-AC-36 [S]: The Pi is untouched and merges were safe until step 7 ends (SH-FR-97, SH-FR-200, SH-BR-16)
- Given steps 0 to 7 have completed
- When the owner runs `git log --since=<step-0 date> --until=<step-7 end> -- pi-de-int-wahlberger-dev`, reads the Pi's `/var/log/apt/history.log`, and reads the Pi Semaphore's task list for that period
- Then the `git log` prints nothing
- And the apt log shows no owner-started transaction in that period
- And no Pi task against nas or cloud after the merge of pull request A, A2, B, B2 or C ended `Failed`

Scenario SH-AC-37 [H]: The full run (SH-FR-98, SH-NFR-08, SH-NFR-10, SH-NFR-11)
- Given step 6 has completed and SH-BR-02 holds
- When the owner runs the nas, cloud and `<vm-dir>` templates from the VM
- Then all three end `Success` with `failed=0 unreachable=0`
- And `journalctl -k -g 'Out of memory'` on the VM prints nothing for that period, and the Beszel memory peak is at most 80 %
- And the nas task's duration is at most 1.5 times the median of the last 5 successful nas tasks on the Pi
- And, run 20 times from the VM, `ssh nas.de.int.wahlberger.dev true` has a p95 of at most 3 s

Scenario SH-AC-38 [H]: The cut-over (SH-FR-38, SH-FR-99, SH-FR-101, SH-FR-161, SH-BR-07, SH-BR-13 to SH-BR-15, SH-NFR-04)
- Given SH-AC-37 ended at most 72 h ago, and the Pi's live configuration-object counts equal the step-4 record plus the changes recorded under SH-BR-14
- When the owner checks that no Pi task is running or due, applies pull request D (`<vm-dir>` with `--tags cloudflare_dns`, the NAS with `--tags homepage`), waits 300 s, reads the Pi's active schedules, puts the Pi's Semaphore into stopped standby, and activates the SH-FR-101 schedules on the VM
- Then `dig +short CNAME semaphore.de.int.wahlberger.dev @1.1.1.1` prints `ops.de.int.wahlberger.dev.`, and a second run reports `changed=0`
- And a home-LAN client's `curl -sv https://semaphore.de.int.wahlberger.dev/api/ping` connects to `<vm-zt-ip>` and gets HTTP 200
- And the Pi is in stopped standby
- And the VM's active schedules equal the Pi's active schedules read before the stop, minus the Pi project's and minus those starting between 03:00 and 05:30, which are listed in the pull request D description
- And `renovate.json` no longer contains the SH-FR-161 rule
- And the semaphore monitor recorded at most 10 min without HTTP 200

Scenario SH-AC-39 [H]: Rollback material stays in place during the window (SH-FR-100)
- Given the stabilization window is running
- When the owner checks the Pi's Semaphore state, and greps the old key's key data in `~erikwahlberger/.ssh/authorized_keys` on the NAS and cloud (no copy of the old private key exists outside the Pi's Semaphore, so no login is attempted)
- Then the Pi is in stopped standby, and the old key's line is present on the NAS and cloud

Scenario SH-AC-40 [H]: Retirement preconditions (SH-FR-103, SH-BR-05)
- Given the owner is about to start step 9
- When the owner collects the evidence for SH-BR-05 a) to j)
- Then each item holds, and the evidence is noted in the pull request E description

Scenario SH-AC-41 [H]: Retirement actions up to the point of no return (SH-FR-94, SH-FR-95, SH-FR-104 to SH-FR-108, SH-FR-173, SH-FR-174, SH-FR-182, SH-BR-17)
- Given SH-AC-40 has passed
- When the owner completes steps 9.2 and 9.3
- Then Beszel and Uptime Kuma list nothing for the Pi, and this happened before the first 9.3 action
- And the step-9.3 log shows `shred -n 1` on each SH-FR-173 file, and `ls /mnt/data/containers/semaphore` printing "No such file or directory", both before the Pi's shutdown
- And `/mnt/data/restic-repos/nas` and `/mnt/data/restic-repos/cloud` still exist, with the same snapshot counts as in SH-BR-05 f)
- And the VM's Key Store has no old-key entry
- And the drive is detached and labelled, and the SD card was re-imaged
- And, where SH-FR-174 is applied, the step-9.3 log shows the SD card erase (`blkdiscard` or full overwrite) run on a host other than the Pi
- And, where SH-FR-108 is applied, `dig +short A pi.de.int.wahlberger.dev @1.1.1.1` prints nothing

Scenario SH-AC-42 [H]: The old key is revoked and the personal key still works (SH-FR-60, SH-FR-61, SH-FR-62, SH-FR-110, SH-FR-156, SH-BR-08)
- Given pull request E is applied to nas, cloud and the VM
- When the owner reads `authorized_keys` on the three hosts, and runs `ssh <host> true` with the personal key for each
- Then no `authorized_keys` contains the old key's key data
- And every personal-key login exits 0

Scenario SH-AC-43 [S]: The repository is clean (SH-FR-62, SH-FR-109, SH-FR-111, SH-FR-112, SH-FR-114, SH-FR-160, SH-NFR-01)
- Given pull request E is merged
- When the owner runs the SH-FR-111 `git grep`, reads `renovate.json`, and checks each documentation row
- Then `pi-de-int-wahlberger-dev/` does not exist, and every grep match is inside the allowlist
- And `renovate.json` contains neither the SH-FR-160 nor the SH-FR-161 rule
- And every `ssh_authorized_keys_list` in nas, cloud and `<vm-dir>` contains the personal key
- And DOC-O5 shows a local-path restore, and each row of [Documentation updates](#documentation-updates) holds

Scenario SH-AC-44 [S]: Revoked keys, options and conflicts (SH-FR-60, SH-FR-126, SH-FR-190)
- Given the `ssh_authorized_keys` role of nas, cloud and `<vm-dir>`
- When the owner reads `meta/argument_specs.yml` and runs three Molecule converges:
  - first, with a test key carrying a `from=` option in `ssh_authorized_keys_list`;
  - then, with that key only in `ssh_authorized_keys_revoked`;
  - finally, with the key in both lists.
- Then `ssh_authorized_keys_revoked` is declared as a list of str with default `[]`
- And after the first converge, the test user's `authorized_keys` holds the key line with its `from=` option
- And after the second, the key is absent, and a repeat reports no change
- And the third fails before any change, naming the key's comment

Scenario SH-AC-45 [S]: An invalid sshd configuration is not applied (SH-FR-121)
- Given the `<vm-dir>` Molecule scenario
- When the converge runs with an sshd override that fails `sshd -t`
- Then the `security` role fails, and `sshd -T` output is unchanged

Scenario SH-AC-46 [H]: fail2ban bans and ignores the configured sources (SH-FR-17, SH-FR-123, SH-FR-124, SH-FR-211, SH-NFR-15)
- Given step 3 has completed
- When the owner runs `ssh -o PubkeyAuthentication=no nobody@ops.de.wahlberger.dev` 5 times within 600 s from a public source outside the ignore list (for example a mobile hotspot), then a sixth attempt, then `sudo fail2ban-client status sshd` and `sudo fail2ban-client get sshd ignoreip`
- Then the sixth attempt is refused or times out
- And the address was banned within 60 s of the fifth failure, with bantime 3600
- And `ignoreip` lists exactly the SH-FR-124 entries
- And while the address is banned, `firewall-cmd --zone=public --list-rich-rules` and `firewall-cmd --permanent --zone=public --list-rich-rules` print nothing
- And the owner unbans the address with `fail2ban-client set sshd unbanip <ip>`

Scenario SH-AC-47 [H]: Public logins send an email; ZeroTier logins do not (SH-FR-125)
- Given step 3 has completed
- When the owner logs in with the personal key to `ops.de.wahlberger.dev` from a public source, and then to `ops.de.int.wahlberger.dev` over ZeroTier
- Then exactly one email arrives within 5 min, naming `erikwahlberger`, the public source address and the personal key's fingerprint

Scenario SH-AC-48 [H]: The new key works only from the VM's addresses (SH-FR-126, SH-FR-127, SH-FR-191)
- Given pull request C is applied
- When the owner:
  - runs `ssh -i <new key> -o BatchMode=yes nas.de.int.wahlberger.dev true` from the workstation;
  - runs the nas template, the cloud template and the `<vm-dir>` template (a self-run) from the VM;
  - reads the sshd logs of the NAS, cloud and the VM for those logins.
- Then the workstation attempt fails with `Permission denied`
- And all three templates connect with the new key, and each logged source address is in the `from=` list
- And the `from=` list is exactly `<vm-public-ip>`, `<vm-zt-ip>`, `<sem-subnet>`, plus any SH-FR-191 address
- And `<vm-dir>` declares the Semaphore network's subnet

Scenario SH-AC-49 [H]: The unhardened window is bounded (SH-FR-162)
- Given the server creation time from `hcloud server describe`
- When the owner notes the time SH-AC-05 passed
- Then at most 60 min lie between the two

Scenario SH-AC-50 [H]: Cloud's backup works under the flow rules (SH-FR-35)
- Given the step-3 flow-rule change is in force
- When the owner starts cloud's `restic-backup.service` by hand, outside 03:00 to 06:00, and then runs `systemctl show -p Result restic-backup.service` on cloud
- Then it prints `Result=success`

Scenario SH-AC-51 [H]: Caddy sees real client addresses and listens only where intended (SH-FR-129, SH-FR-183, SH-FR-184, SH-FR-196, SH-FR-07)
- Given step 3, with Caddy running and Semaphore not yet running, in the design in use (this scenario is required in both designs; in the bridge fallback a failure stops step 3, SH-E-47)
- When a home-LAN client runs `curl -sk --resolve semaphore.de.int.wahlberger.dev:443:<vm-zt-ip> -o /dev/null -w '%{http_code}' https://semaphore.de.int.wahlberger.dev/`; the owner runs the same request on the VM host with `--interface <vm-public-ip>`; the owner reads Caddy's access log and runs `ss -tlnp`
- Then the home-LAN client gets 502 (allowed, no upstream yet), and the host request gets 403
- And the access log shows the client's address inside 10.10.0.0/16 or 10.243.0.0/16, not a Podman bridge address
- And `ss` shows no listener on port 80 and none on port 2019

Scenario SH-AC-52 [H]: The Pi's Vault value is the one in use (SH-FR-180)
- Given step 0
- When the owner pipes the `access_key_encryption` value from the Pi's live `config.json` and the Pi Vault's `vault_semaphore_access_key_encryption` through `sha256sum`, without printing them
- Then the two hashes are equal

Scenario SH-AC-53 [H]: File modes, owners and labels on the VM (SH-FR-166 to SH-FR-169, SH-FR-207, SH-FR-208, SH-FR-215 to SH-FR-219)
- Given step 4 has completed
- When the owner runs `stat -c '%a %u %n'` on `config.json`, `semaphore.env`, `caddy.env`, the Semaphore data directory and `database.sqlite`, and `ls -Z` on `database.sqlite`, and compares the owners with `semaphore_uid` (pull request A3) and with `sudo podman exec semaphore id -u` on the VM
- Then `config.json` is `600` owned by the Semaphore UID; both env files are `600` owned by `0`; the data directory is `700` and `database.sqlite` is `600`, both owned by the Semaphore UID
- And `semaphore_uid` equals the UID reported inside the VM's container
- And `database.sqlite` carries type `container_file_t`

Scenario SH-AC-54 [H]: Pi-specific values and access tokens are listed (SH-FR-178, SH-A-11)
- Given step 4 has completed
- When the owner runs the SH-AC-25 `grep`, without `-c`, on a copy of the VM's database, and lists the API tokens and integrations
- Then every match, every token and every integration is written by name (never by value) into the deletion list in the migration notes

Scenario SH-AC-55 [H]: The workstation database copy is gone (SH-FR-172)
- Given every other step-4 gate scenario has passed
- When the owner deletes the copy and searches the workstation for `database.sqlite*` files from the Pi
- Then none is found

Scenario SH-AC-56 [S]: Self-run safety of the handlers and the update script (SH-FR-188, SH-FR-189, SH-FR-214)
- Given pull request A
- When the owner reads `<vm-dir>/roles/security/handlers/main.yml` and `<vm-dir>/roles/firewall/`
- Then the sshd handler uses `state: reloaded`
- And no task or handler in the `firewall` role reloads or restarts `firewalld`
- And the rendered `zypper-dup.service` script contains no `reboot` or `systemctl reboot` call; its only reboot path is `rebootmgrctl reboot`

Scenario SH-AC-57 [H]: Snapshots are deleted in time and the Pi's Vault item is archived (SH-FR-170, SH-FR-209, SH-FR-113)
- Given step 9.5 has completed, or any day during the feature
- When the owner runs `hcloud image list --type snapshot`, and after step 9.5 opens 1Password's archive
- Then no snapshot of the VM is older than 30 days, and after step 9.5 none exists
- And, where SH-FR-113 is applied, after step 9.5 `Ansible Vault - pi-de-int-wahlberger-dev` is in the archive

Scenario SH-AC-58 [H]: The monitors exist from step 4 (SH-FR-91, SH-FR-212)
- Given step 4 has completed
- When the owner opens Uptime Kuma
- Then an HTTP monitor for the SH-FR-91 URL exists, with interval 60 s, 3 retries and the owner's notification, and it is up (until step 8 it checks the Pi)
- And a TCP monitor for `ops.de.int.wahlberger.dev:443` exists and is up, which shows that the VM answers over ZeroTier

Scenario SH-AC-59 [H]: Account and key protection (SH-FR-163, SH-FR-164, SH-FR-165)
- Given step 0
- When the owner inspects the personal key's storage, the Hetzner account security page and the ZeroTier Central account settings
- Then the personal private key is either agent-only (1Password SSH agent, FIDO2 `sk-` key or Secure Enclave), or on disk with `ssh-keygen -y -P '' -f <key>` failing for lack of the passphrase
- And two-factor authentication is enabled on the Hetzner account and on the Central account

Scenario SH-AC-60 [S]: Renovate leaves the Pi and the VM's Semaphore image alone (SH-FR-160, SH-FR-161)
- Given pull request A is merged
- When the owner reads `renovate.json` and Renovate's Dependency Dashboard
- Then a package rule with `enabled: false` matches `pi-de-int-wahlberger-dev/**`, and another matches `ops-de-wahlberger-dev/roles/semaphore/defaults/main.yml`
- And the dashboard lists no pending or open update for those files

Scenario SH-AC-61 [H]: The bridge fallback works (SH-FR-186, SH-FR-187, SH-FR-220)
- Given the fallback of SH-D-12 was chosen in step 3 (`-e vm_proxy_design=bridge_fallback`)
- When the owner reads the rendered Caddy and Semaphore Quadlets
- Then Caddy's upstream is `semaphore:3000`, and both containers join the same bridge network
- And Caddy's Quadlet is on `caddy.network`, and no `semaphore.network` is used
- And pull request A3 sets `vm_proxy_design: bridge_fallback` and records the fallback and SH-R-04 in `<vm-dir>/README.md`

Scenario SH-AC-62 [H]: Empty ZeroTier address and interface guards (SH-FR-193, SH-FR-194)
- Given step 2, with `vm_zt_ip` and `vm_zt_iface` empty
- When the owner runs `site.yml --tags cloudflare_dns` and, separately, `site.yml --tags caddy`, and reads the step-2 output of the `firewall` role
- Then each run fails before any change, naming `vm_zt_ip`
- And `dig +short A ops.de.int.wahlberger.dev @1.1.1.1` prints nothing
- And the `firewall` role's output contains the skip message naming `vm_zt_iface`, and no interface is bound to a `zerotier` zone (`firewall-cmd --permanent --zone=zerotier --list-interfaces` prints nothing, or the zone does not exist)

Scenario SH-AC-63 [S]: Pull request A2 content (SH-FR-34, SH-FR-192)
- Given pull request A2
- When the owner reads its diff
- Then it sets `vm_zt_ip` to a 10.243.0.0/16 address and sets `vm_zt_iface`
- And it adds the dated "in force" rule set to `docs/zerotier-flow-rules.md`
- And it changes no file outside `<vm-dir>`

Scenario SH-AC-64 [S]: Pull request A3 content (SH-FR-220, SH-FR-221)
- Given pull request A3, after the step-3 tests and before step 4
- When the owner reads its diff and runs `ansible-playbook site.yml --syntax-check` in `<vm-dir>`
- Then `vm_proxy_design` is `primary` or `bridge_fallback` and matches the step-3 decision, and `caddy_design` and `semaphore_design` are set from it
- And `semaphore_uid` is a positive integer equal to the value read on the Pi in step 3
- And the README observation sections (SH-AC-05 directives not applied, the SH-AC-08 note, and the SH-AC-04 and SH-AC-61 results with SH-R-04 if the fallback is used) are filled in
- And it changes no file outside `<vm-dir>`, and the syntax check passes

Scenario SH-AC-65 [H]: The step-0 baseline is recorded (SH-FR-213)
- Given step 0
- When the owner opens Beszel and Uptime Kuma before merging pull request A
- Then the pull request A description lists every Beszel system and every Uptime Kuma monitor with status up, and the date and time of the reading

Scenario SH-AC-66 [S]: Empty `semaphore_uid` guard (SH-FR-210)
- Given the `<vm-dir>` `semaphore` role with `semaphore_uid` empty
- When the role's guard test runs it against a disposable container
- Then the role fails before any change, naming `semaphore_uid`

### Step gates

| Step | Gate scenarios (all must pass before the next step) |
|---|---|
| 0 | SH-AC-01, SH-AC-17, SH-AC-27, SH-AC-30, SH-AC-44, SH-AC-45, SH-AC-52, SH-AC-56, SH-AC-59, SH-AC-60, SH-AC-65, SH-AC-66 |
| 1 | SH-AC-02 |
| 2 | SH-AC-05 (within 60 min of creation), SH-AC-49 (its time check), SH-AC-62 (can run after the 60 min) |
| 3 | SH-AC-63 (first), SH-AC-04 (zone test not a gate in the fallback), SH-AC-08 to SH-AC-14, SH-AC-19, SH-AC-46, SH-AC-47, SH-AC-51 (required in both designs; stop condition SH-E-47); SH-AC-61 if the fallback applies; SH-AC-64 (last, after pull request A3 is merged) |
| 4 | SH-AC-18, then SH-AC-20 (before any task runs on the VM), then SH-AC-03, SH-AC-07, SH-AC-15, SH-AC-16, SH-AC-21, SH-AC-22, SH-AC-53, SH-AC-54, SH-AC-58; SH-AC-34 if a snapshot was taken; SH-AC-55 last |
| 5 | SH-AC-06, SH-AC-31, SH-AC-32, SH-AC-33, SH-AC-50 |
| 6 | SH-AC-23, SH-AC-24, SH-AC-25, SH-AC-48 |
| 7 | SH-AC-26, SH-AC-36, SH-AC-37 |
| 8 | SH-AC-35, SH-AC-38; SH-AC-34 if a snapshot was taken |
| Stabilization window (feeds SH-BR-05 h to j) | SH-AC-28, SH-AC-29, SH-AC-39 |
| 9 | SH-AC-40 (before 9.2), SH-AC-41 (after 9.3), SH-AC-42 and SH-AC-43 (after 9.4), SH-AC-57 (after 9.5) |

### Non-Functional Requirements

- SH-NFR-01: After step 9, no function of this repository requires a powered device at home other than the NAS and the router.
- SH-NFR-02: The VM's recurring cost is at most €6.00 per month, excluding VAT and including the primary IPv4. Specification and price are verified at order time.
- SH-NFR-03 (security): From an internet host, a scan of TCP 1 to 65535, the top 100 UDP ports and UDP 9993 on `<vm-public-ip>` finds exactly one open port, TCP 22.
- SH-NFR-04: During the cut-over, `https://semaphore.de.int.wahlberger.dev` goes unanswered for at most 10 min, measured by the SH-FR-91 monitor at a 60 s interval.
- SH-NFR-05: The Semaphore state loses at most 26 h of changes (RPO).
- SH-NFR-06: A backup run (backup plus both checks) takes at most 10 min wall-clock time.
- SH-NFR-07: Recovery from loss of the VM to a new VM serving the restored database takes at most 4 h (RTO), provided Hetzner and ZeroTier Central are available. This includes re-authorizing a new ZeroTier identity with the same fixed IP (SH-D-19).
- SH-NFR-08: During a nas template run from the VM, memory use peaks at no more than 80 % of RAM, and 0 OOM-killer events occur.
- SH-NFR-09: 30 days after step 8, usage of `/` on the VM is at most 70 %.
- SH-NFR-10: A nas template run on the VM takes at most 1.5 times the median duration of the last 5 successful nas template runs on the Pi.
- SH-NFR-11: Over ZeroTier, `ssh nas.de.int.wahlberger.dev true` from the VM completes with a p95 of at most 3 s over 20 attempts.
- SH-NFR-12: Uptime Kuma notifies the owner at most 5 min after the Semaphore UI stops answering.
- SH-NFR-13 (security): At any check, the last successful `zypper-dup.service` run is at most 8 days old.
- SH-NFR-14 (security): To an unauthenticated client, sshd on the VM offers `publickey` as its only authentication method.
- SH-NFR-15 (security): A public source that fails SSH authentication 5 times within 600 s is banned within 60 s of the fifth failure, for 3600 s.

### Verification

| Requirement | Method | Scenario |
|---|---|---|
| SH-FR-01 to SH-FR-04, SH-FR-115, SH-FR-122 | inspection [H] | SH-AC-02 |
| SH-FR-06, SH-FR-07, SH-FR-130, SH-NFR-03 | demonstration [H] | SH-AC-03 |
| SH-FR-06, SH-FR-09, SH-FR-128, SH-FR-185 | demonstration [H] (runtime zone change, temporary rule) | SH-AC-04, SH-AC-09 |
| SH-FR-08, SH-FR-09 | demonstration [H] | SH-AC-11, SH-AC-12 |
| SH-FR-10 to SH-FR-13, SH-FR-135 to SH-FR-143 | test [S] (CI) | SH-AC-01 |
| SH-FR-14 to SH-FR-19, SH-FR-22, SH-FR-116 to SH-FR-120, SH-FR-157 to SH-FR-159, SH-NFR-14 | inspection [H] | SH-AC-05 |
| SH-FR-20, SH-FR-21, SH-FR-72, SH-FR-83, SH-FR-144, SH-FR-145 | demonstration [H] | SH-AC-06 |
| SH-FR-23, SH-FR-24 | inspection [H] | SH-AC-07 |
| SH-FR-25 | inspection [H] | SH-AC-08 |
| SH-FR-26 to SH-FR-29 | inspection [H] | SH-AC-09, SH-AC-10 |
| SH-FR-30 to SH-FR-32 | demonstration [H] | SH-AC-11, SH-AC-12 |
| SH-FR-33 to SH-FR-35, SH-FR-132 | inspection [H] | SH-AC-13, SH-AC-50 |
| SH-FR-36, SH-FR-37, SH-FR-131 | demonstration [H] | SH-AC-14 |
| SH-FR-38 | demonstration [H] | SH-AC-38 |
| SH-FR-39, SH-FR-40 | demonstration [H] | SH-AC-15 |
| SH-FR-41, SH-FR-55 | demonstration [H] | SH-AC-16 |
| SH-FR-42 to SH-FR-46, SH-FR-146 to SH-FR-148 | inspection [S] | SH-AC-17 |
| SH-FR-47, SH-FR-48 | demonstration [H] | SH-AC-21 |
| SH-FR-49, SH-FR-50, SH-FR-175, SH-FR-176 | inspection [H] | SH-AC-18 |
| SH-FR-51, SH-FR-53, SH-FR-54 | inspection [H] | SH-AC-20 |
| SH-FR-177 | demonstration [H] | SH-AC-22 |
| SH-FR-178, SH-FR-179 | inspection [H] | SH-AC-54, SH-AC-25 |
| SH-FR-52 | test [H] | SH-AC-19 |
| SH-FR-56, SH-FR-57, SH-FR-62 | inspection [S] | SH-AC-23, SH-AC-42 |
| SH-FR-58, SH-FR-59, SH-FR-181 | inspection [H] | SH-AC-24 |
| SH-FR-60, SH-FR-190 | test [S] (Molecule) | SH-AC-44 |
| SH-FR-126, SH-FR-127, SH-FR-191 | demonstration [H] | SH-AC-23, SH-AC-48 |
| SH-FR-61, SH-FR-110, SH-FR-156 | demonstration [H] | SH-AC-42 |
| SH-FR-63 to SH-FR-65, SH-FR-149, SH-FR-150 | inspection [H] | SH-AC-25 |
| SH-FR-66 to SH-FR-69 | demonstration [H] | SH-AC-26 |
| SH-FR-188, SH-FR-189 | inspection [S] | SH-AC-56 |
| SH-FR-70, SH-FR-90, SH-FR-96, SH-FR-133, SH-FR-134 | inspection [S] | SH-AC-27 |
| SH-FR-71, SH-FR-73 to SH-FR-75, SH-NFR-13 | inspection [H] | SH-AC-28 |
| SH-FR-76 | demonstration [H] | SH-AC-29 |
| SH-FR-77, SH-FR-80 to SH-FR-82, SH-FR-151, SH-FR-152, SH-FR-171 | inspection [S] | SH-AC-30 |
| SH-FR-78, SH-FR-84, SH-FR-88, SH-NFR-06 | demonstration [H] | SH-AC-31 |
| SH-FR-85 to SH-FR-87, SH-FR-153 to SH-FR-155 | demonstration [H] | SH-AC-32 |
| SH-FR-89 | test [H] | SH-AC-33 |
| SH-FR-91 | inspection [H] | SH-AC-58 |
| SH-FR-92, SH-FR-93, SH-NFR-12 | inspection [H] | SH-AC-35 |
| SH-FR-94, SH-FR-95, SH-FR-104 to SH-FR-108, SH-FR-173, SH-FR-174, SH-FR-182 | inspection [H] | SH-AC-41 |
| SH-FR-97 | inspection [S], [H] | SH-AC-18, SH-AC-36 |
| SH-FR-98, SH-NFR-08, SH-NFR-10, SH-NFR-11 | demonstration [H] | SH-AC-37 |
| SH-FR-99, SH-FR-101, SH-NFR-04 | demonstration [H] | SH-AC-38 |
| SH-FR-100 | inspection [H] | SH-AC-39 |
| SH-FR-102 | inspection [H] | SH-AC-34 |
| SH-FR-103, SH-BR-05 | inspection [H] | SH-AC-40 |
| SH-FR-109, SH-FR-111, SH-FR-112, SH-FR-114, SH-NFR-01 | inspection [S] | SH-AC-43 |
| SH-FR-113 | inspection [H] (1Password archive list) | SH-AC-57 |
| SH-FR-121 | test [S] (Molecule) | SH-AC-45 |
| SH-FR-17, SH-FR-123, SH-FR-124, SH-NFR-15 | demonstration [H] | SH-AC-46 |
| SH-FR-125 | demonstration [H] | SH-AC-47 |
| SH-FR-162 | inspection [H] | SH-AC-49 |
| SH-FR-129, SH-FR-183, SH-FR-184 | demonstration [H] | SH-AC-51 |
| SH-FR-180 | inspection [H] | SH-AC-52 |
| SH-FR-166 to SH-FR-169 | inspection [H] | SH-AC-53 |
| SH-FR-172 | inspection [H] | SH-AC-55 |
| SH-FR-170 | inspection [H] | SH-AC-57 |
| SH-FR-163 to SH-FR-165 | inspection [H] | SH-AC-59 |
| SH-FR-160, SH-FR-161 | inspection [S] | SH-AC-60, SH-AC-38, SH-AC-43 |
| SH-FR-186, SH-FR-187 | demonstration [H] (only if the fallback applies) | SH-AC-61 |
| SH-FR-193 | test [H] | SH-AC-62 |
| SH-FR-192 | inspection [S] | SH-AC-63 |
| SH-FR-194 | test [H] | SH-AC-62 |
| SH-FR-195 | inspection [H] | SH-AC-28 |
| SH-FR-196 | demonstration [H] | SH-AC-51 |
| SH-FR-197 to SH-FR-199 | demonstration [H] | SH-AC-13 |
| SH-FR-200 | inspection [H] | SH-AC-18, SH-AC-36 |
| SH-FR-201 | inspection [S] | SH-AC-17 |
| SH-FR-202 | inspection [H] (Pocket ID client list) | SH-AC-21 |
| SH-FR-203, SH-FR-204 | inspection [H] | SH-AC-18 |
| SH-FR-205 | inspection [S] | SH-AC-10 |
| SH-FR-206 | demonstration [H] | SH-AC-06 |
| SH-FR-207, SH-FR-208 | inspection [H] | SH-AC-53 |
| SH-FR-209 | inspection [H] | SH-AC-57 |
| SH-FR-210 | test [S] (guard test) | SH-AC-66 |
| SH-FR-211 | demonstration [H] | SH-AC-46 |
| SH-FR-212 | inspection [H] | SH-AC-58 |
| SH-FR-213 | inspection [H] | SH-AC-65 |
| SH-FR-214 | inspection [S] | SH-AC-56 |
| SH-FR-215 to SH-FR-219 | inspection [H] | SH-AC-53 |
| SH-FR-220, SH-FR-221 | inspection [S] | SH-AC-64, SH-AC-61, SH-AC-03 |
| SH-BR-18 | inspection (runbook log in the new pull request C description) | SH-AC-23, SH-AC-44 |
| SH-BR-01, SH-BR-02, SH-BR-16 | inspection [H] (runbook log in pull request descriptions) | SH-AC-36, SH-AC-37 |
| SH-BR-03, SH-BR-04 | inspection (runbook log) | SH-AC-38 |
| SH-BR-06 | demonstration [H] | SH-AC-11, SH-AC-12 |
| SH-BR-07, SH-BR-13 to SH-BR-15 | inspection [H] | SH-AC-18, SH-AC-38 |
| SH-BR-08, SH-BR-10 | inspection [S], [H] | SH-AC-23, SH-AC-39, SH-AC-42 |
| SH-BR-09 | demonstration [H] | SH-AC-31, SH-AC-32 |
| SH-BR-11 | inspection [H] | SH-AC-31 |
| SH-BR-12 | inspection (runbook) | SH-AC-27 |
| SH-BR-17 | inspection [H] | SH-AC-41 |
| SH-NFR-02 | inspection (Hetzner price at order, first invoice) | none |
| SH-NFR-05, SH-NFR-07 | analysis (backup schedule; timed runbook steps in the README) | none |
| SH-NFR-09 | inspection [H] (`df /` on day 30) | none |

### Contract changes

- SH-CC-01 (NAS `restic_server`, pull request B2): the single maintenance repository (`restic_server_maintenance_repo` str, `restic_server_maintenance_repo_password` str) becomes a list of `{repo, password}` entries, production `cloud` and `ops`. The DOC-O6, O7, O8 and O10 commands take the repository name as a parameter. `cloud` is unchanged (SH-FR-86).
- SH-CC-02 (NAS, pull request B): `restic_server_clients` gains `ops`. The NAS Vault and `vault.yml.example` gain `vault_restic_server_ops_htpasswd_password` and `vault_restic_server_ops_repo_password`. The 100 GiB quota is shared with `cloud`.
- SH-CC-03 (NAS, pull request B2): `backup_disk_freshness_checks` gains `/mnt/data/restic-repos/ops/snapshots`.
- SH-CC-04 (`ssh_authorized_keys` in nas, cloud and `<vm-dir>`, pull request A):
  - new optional input `ssh_authorized_keys_revoked` (list of str, default `[]`); listed keys are removed;
  - a key present in both lists fails the role before any change;
  - list entries can carry `authorized_keys` options.
- SH-CC-05 (nas, cloud `vars.yml`): `ssh_authorized_keys_list` gains the new key with `from=` in pull request C and loses the old key in pull request E.
- SH-CC-06 [Should] (cloud `restic_backup`, pull request A): the role default `restic_backup_rest_server_host` changes from `pi.de.int.wahlberger.dev` to `nas.de.int.wahlberger.dev`. Production already overrides it, so behaviour does not change.
- SH-CC-07 (`<vm-dir>` `semaphore`, compared with the Pi's copy):
  - new input `semaphore_require_existing_db`;
  - new inputs `semaphore_uid` (empty by default; the role fails while it is empty, SH-FR-210) and `semaphore_design` (`primary` or `bridge_fallback`, from `vm_proxy_design`);
  - joins `semaphore.network` with subnet `semaphore_network_subnet` in the primary design, and `caddy.network` in the fallback;
  - joins the Semaphore network (fixed subnet), not `caddy.network`, and publishes port 3000 on 127.0.0.1 only;
  - `config.json` mode `0600`, owned by the Semaphore UID; data directory `0700`;
  - `semaphore_data_dir` derives from the VM's `podman_data_dir`.

  In the bridge fallback, it joins Caddy's bridge network and publishes no port.
- SH-CC-08 (`<vm-dir>` `cloudflare_dns`):
  - new inputs `cloudflare_dns_extra_a_records` (an empty value fails the role), `cloudflare_dns_cname_target` (default `inventory_hostname`) and `cloudflare_dns_cnames_enabled` (default `true`; production equals `semaphore_dns_cutover_enabled`);
  - the default `cloudflare_dns_ip` stays.
- SH-CC-09 (`<vm-dir>` `caddy`, compared with the NAS copy):
  - `Network=host`; binds `caddy_bind_address`;
  - a `remote_ip` allowlist from `caddy_allowed_sources`, answering 403 to every other source;
  - upstream `127.0.0.1:3000`;
  - no port-80 listener and no admin endpoint;
  - an access log with the client address (SH-FR-196);
  - fails while `vm_zt_ip` is empty;
  - new input `caddy_design` (`primary` or `bridge_fallback`, from `vm_proxy_design`).

  In the bridge fallback: `caddy.network`, `PublishPort=<vm-zt-ip>:443:443`, upstream `semaphore:3000`.
- SH-CC-10 (NAS `homepage`, pull request D): the dashboard group "Pi (pi.de.int.wahlberger.dev)" is renamed to `ops.de.wahlberger.dev`. `homepage_semaphore_url` does not change.
- SH-CC-11 (Pi): stopped standby from step 8; Semaphore data destroyed in step 9.3; playbook directory removed by pull request E.
- SH-CC-12 (configuration outside the repository):
  - the Hetzner server, firewall, snapshots and account two-factor authentication;
  - the ZeroTier member, flow rules and Central account two-factor authentication;
  - Semaphore projects, templates, Key Store, schedules, API tokens and integrations;
  - Uptime Kuma monitors and Beszel systems;
  - the Cloudflare record for the Pi;
  - 1Password items.
- SH-CC-13: In NAS and cloud sshd logs, the automation login's key fingerprint and comment change to the new key's.
- SH-CC-14 (`<vm-dir>` `security`, compared with the NAS copy):
  - sshd directives SH-FR-116 to SH-FR-120 and SH-FR-157 to SH-FR-159;
  - `sshd -t` validation before any reload (SH-FR-121), and a reload-not-restart handler (SH-FR-188);
  - new inputs `security_ssh_allow_users`, `security_fail2ban_findtime` and `security_fail2ban_ignoreip`;
  - the public-login email hook, which uses `notify_failure`'s Resend credentials (SH-FR-125);
  - every account password locked (SH-FR-122);
  - `zypper-dup.service` and `zypper-dup.timer` replace the NAS's weekly `zypper patch` (SH-FR-71);
  - rebootmgr strategy `maint-window` instead of the NAS's `best-effort` (SH-FR-195), and an update script that never reboots by itself (SH-FR-214);
  - a fail2ban ban action that adds no firewalld rich rule (SH-FR-211).
- SH-CC-15 (`<vm-dir>` `firewall`, compared with the NAS copy):
  - the public interface's zone allows service `ssh` only;
  - `<zt-iface>` is bound by name, permanently, to zone `zerotier`, which allows `ssh` and `https` and has a rich rule for 45876/tcp from `<cloud-zt-ip>`;
  - the NAS default services `samba`, `http` and `https` are not used on the public zone;
  - new input `firewall_zerotier_interface`, fed by `vm_zt_iface`; while it is empty, the ZeroTier zone binding and its rules are skipped (SH-FR-194).
- SH-CC-16 (`renovate.json`): two disabling package rules are added in pull request A (SH-FR-160, SH-FR-161). Pull request D removes the `<vm-dir>` rule and pull request E removes the Pi rule.

### Assumptions

- SH-A-01: The SQLite file format is identical on arm64 and x86_64.
- SH-A-02: The Pi runs `semaphoreui/semaphore:v2.19.16`. Steps 0 and 4 confirm this with `podman inspect`.
- SH-A-03: Cloudflare's public DNS returns the private A records of `*.de.int.wahlberger.dev` (cloud's 2026-10-10 backup to the NAS used this).
- SH-A-04: ZeroTier routes 10.10.0.0/16 through the home router, and the NAS sees ZeroTier sources as 10.243.0.0/16 (owner, 2026-10-09). SH-FR-191 handles a deviation for the VM.
- SH-A-05: `github.com` has no IPv6 address. Verify with `dig AAAA github.com`.
- SH-A-06: `community.general.cloudflare_dns` with `state: present` updates an existing CNAME's target in place. Verify with `--check --diff` in step 8.
- SH-A-07: ZeroTier works with no inbound UDP allowed by the Cloud Firewall (direct or relayed paths; SH-NFR-11 measures).
- SH-A-08: The `zerotier` container's `/dev/net/tun` access and the `:Z` volumes work under SELinux enforcing. Verify in step 2 with `ausearch -m avc`.
- SH-A-09: Semaphore v2.19 answers `GET /api/ping` with HTTP 200 without a login. If not, the monitor uses `/`.
- SH-A-10: Semaphore encrypts Key Store secrets, including Vault passwords, with `access_key_encryption`, which `config.json` holds.
- SH-A-11: Whether API tokens or integrations exist is unknown. SH-AC-54 lists them in step 4, and SH-FR-179 deletes them in step 6.
- SH-A-12: The Hetzner Cloud Firewall also filters traffic from other Hetzner servers, so scans and the SH-AC-04 test from cloud's public address are valid.
- SH-A-13: No client has written to the Pi's rest-server since 2026-10-10. SH-BR-05 e) verifies this.
- SH-A-14: The migrated database contains the admin `erikwahlberger`, so the `semaphore` role creates no new admin.
- SH-A-15: Whether schedules exist on the Pi today is unknown. The step-4 record lists the active ones.
- SH-A-16: CX23 is orderable in nbg1 or fsn1 with a Tumbleweed-capable image.
- SH-A-17: The Semaphore container reaches the host's own addresses (the self-run to `<vm-fqdn>`) through zone `trusted` (measured, BD-A-23).
- SH-A-18: ZeroTier members keep working with their cached network configuration while Central is unreachable.
- SH-A-19: On Hetzner Cloud, `ansible_facts.default_ipv4.address` is the public IPv4 (cloud-wahlberger-dev uses the same default). Verify in SH-AC-14.
- SH-A-20: With host networking, Caddy's bind fails while `<vm-zt-ip>` does not exist, and `Restart=always` brings Caddy back once it does. Verify in step 3 (restart `zerotier.service`, then `ss -tlnp`) and in SH-AC-29.
- SH-A-21: With host networking there is no NAT in front of Caddy, so `remote_ip` sees the client address. Home-LAN clients appear as 10.10.0.0/16, or as the router's ZT IP if the router masquerades into ZeroTier; both are allowed. Decided in step 3 by SH-AC-51.
- SH-A-22: Bridge-fallback facts are inference only (NAS spike A-05 is an unverified desk study; the VM fixture measured only host networking):
  - a published port bypasses firewalld zone rules;
  - `PublishPort=<vm-zt-ip>:443:443` limits DNAT to that destination;
  - DNAT keeps the client source address.

  SH-AC-61 measures the last two if the fallback is used.
- SH-A-23: Central's current rule set is its default (non-IPv4/ARP/IPv6 ethertypes dropped, then `accept;`). The saved "before" text records the exact rules.
- SH-A-24: OpenSSH defaults to `KbdInteractiveAuthentication yes`, and openSUSE uses PAM, so `PasswordAuthentication no` alone does not stop PAM password prompts; hence SH-FR-116. The NAS `security` role sets only two directives (checked). Whether the NAS accepts keyboard-interactive logins has not been measured; it is not changed here.
- SH-A-25: fail2ban's sshd filter in its default mode counts "not listed in AllowUsers" and "Invalid user" log lines. Verify in SH-AC-46.
- SH-A-26: `ansible.posix.authorized_key` accepts a key line with a leading `from=` option and updates the options of an existing key in place. Verify in SH-AC-44. If not, the role passes the options through the module's `key_options` parameter, which keeps SH-FR-126 a Must.
- SH-A-27: The Tumbleweed image accepts cloud-init user-data from Hetzner, or allows root login with the Hetzner-injected key, to create `erikwahlberger` before step 2. Verify in step 1.
- SH-A-28: openSUSE's `openssh` package restarts sshd on update, so OpenSSH fixes take effect without a reboot. Verify after the first `zypper-dup.service` run.
- SH-A-29: The interface name ZeroTier creates for a network is derived from the network ID and stays the same across restarts and reboots. Verify in SH-AC-09.
- SH-A-30: sshd reload (SIGHUP) keeps established sessions, including the self-run's own connection. Verify in SH-AC-26.
- SH-A-31: Semaphore v2.19's API (with a session login) returns lists of projects, templates, inventories, repositories, environments, keys, users, schedules and tasks, which give the step-4 record. Verify in step 4 before the stop.
- SH-A-32: The Semaphore image runs its process as one fixed non-root UID, and with rootful Podman that UID is the same on the host. It is read read-only on the Pi in step 3 (same pinned image tag, SH-FR-50; Renovate frozen, SH-FR-161), committed as `semaphore_uid` in pull request A3, and re-checked on the VM in SH-AC-53.
- SH-A-33: The `caddy:2` build used here supports the global options for disabling the admin endpoint and the HTTP redirect listener, and for a default bind address. Verify in SH-AC-51.
- SH-A-34: Renovate's `matchFileNames` package-rule matcher applies to files handled by the repository's regex manager. Verify in SH-AC-60.

### Risks and accepted trade-offs

- SH-R-01 (accepted by Erik, 2026-10-10): The host that holds root-equivalent access to every host exposes TCP 22 to the internet.
  - Rationale: SSH remains a repair path when ZeroTier is down, with no console password, and repair does not depend on ZeroTier.
  - Blast radius if the VM is compromised (root, or the personal key, since `erikwahlberger` has passwordless sudo, SH-D-16):
    - the automation key and with it root on the NAS and cloud;
    - every playbook's Vault password (Key Store) and therefore every Vault secret;
    - `access_key_encryption`;
    - in rendered files: the Cloudflare zone token (Zone:DNS:Edit on `wahlberger.dev`, which allows redirecting any record and issuing DNS-01 certificates for any name), the Resend API key (mail as the alert sender), the Pocket ID client secret for Semaphore, and the Semaphore admin password and cookie keys (SH-FR-45 to SH-FR-48, SH-FR-146 to SH-FR-148).
  - Preventive controls: SH-FR-04, SH-FR-06, SH-FR-15 to SH-FR-18, SH-FR-115 to SH-FR-124, SH-FR-157 to SH-FR-159, SH-FR-162 to SH-FR-164, SH-NFR-03, SH-NFR-13 to SH-NFR-15.
  - Containment: SH-FR-126 (a stolen automation key works only from the VM's addresses).
  - Detection: SH-FR-125. Limitation: the VM sends this email itself, so an attacker who gains root can suppress later emails, and a pre-authentication exploit opens no login session at all. An off-host detection channel is deferred (Out of Scope).
  - Residual risk: an OpenSSH pre-authentication vulnerability, or a stolen personal key, gives the whole blast radius above.
- SH-R-02: With the weekly `zypper dup`, a fixed OpenSSH can take up to 7 days to reach the VM. The owner can start `zypper-dup.service` by hand when an advisory appears. sshd restarts on the package update (SH-A-28).
- SH-R-03 (accepted, SH-Q7): The NAS holds the `ops` repository password, so NAS root can read the backed-up database: encrypted Key Store entries and task logs. API tokens and integrations are deleted in step 6. The NAS never holds `access_key_encryption` (SH-BR-11) or the ZeroTier identity (SH-FR-171).
- SH-R-04: In the bridge fallback, SH-FR-128 is expected to have no effect on port 443 (inference, SH-A-22). The remaining controls are the Cloud Firewall, the DNAT bound to `<vm-zt-ip>` and the `remote_ip` allowlist.
- SH-R-05 (accepted, SH-Q8): The Pi's frozen `nas` repository, the last off-host copy of NAS data, lives only on one offline USB drive until the offsite-backup feature exists.
- SH-R-06: Rotating the automation key (SH-D-03) does not re-encrypt the other Key Store secrets, because `access_key_encryption` must stay (SH-C-05). Any surviving copy of the Pi's `config.json` together with a database copy decrypts the playbook Vault passwords. Controls: SH-FR-104, SH-FR-170, SH-FR-172, SH-FR-173, SH-FR-166 to SH-FR-169. Accepted with SH-D-04.
  - Residual: the Pi's USB drive is the 2.5-inch HDD `WDC_WD50NDZW` (Pi `vars.yml`). Remapped sectors, and any drive-managed SMR band relocation, can keep old copies of `config.json` and the database after `shred -n 1`. A remnant would decrypt Key Store remnants. This is accepted, not mitigated by destroying the drive, because the drive must keep the frozen `nas` repository (SH-Q8). Mitigation: the drive stays offline in the owner's physical custody (SH-FR-106).

Security-relevant IDs, the review starting point:
- Functional: SH-FR-03, SH-FR-04, SH-FR-06 to SH-FR-09, SH-FR-15 to SH-FR-18, SH-FR-22, SH-FR-28, SH-FR-30 to SH-FR-34, SH-FR-43 to SH-FR-48, SH-FR-56 to SH-FR-62, SH-FR-71, SH-FR-80, SH-FR-104, SH-FR-106, SH-FR-107, SH-FR-110, SH-FR-115 to SH-FR-134, SH-FR-146 to SH-FR-148, SH-FR-151, SH-FR-156 to SH-FR-160, SH-FR-162 to SH-FR-174, SH-FR-177 to SH-FR-221.
- Rules and decisions: SH-BR-06, SH-BR-08 to SH-BR-11, SH-BR-17, SH-BR-18, SH-D-03, SH-D-04, SH-D-14 to SH-D-16, SH-D-18 to SH-D-22.
- Error cases: SH-E-29 to SH-E-35, SH-E-40, SH-E-41, SH-E-45 to SH-E-48.
- Non-functional and risks: SH-NFR-03, SH-NFR-13 to SH-NFR-15, SH-R-01 to SH-R-04, SH-R-06.

### Documentation updates

| ID | File(s) | Content | Holds at end of step |
|---|---|---|---|
| SH-DOC-01 | `README.md` (root) | Playbooks table row for `ops-de-wahlberger-dev` (Hetzner CX23, Tumbleweed, Semaphore, UI over ZeroTier only, key-only public SSH); "Automated runs" names it and gives the reasons; the `cd` example | 8 |
| SH-DOC-02 | `README.md` (root) | Pi row removed | 9 |
| SH-DOC-03 | `<vm-dir>/README.md` | Provisioning contract; Cloud Firewall rule table and `hcloud` commands; initial account; 60-min hardening bound; ZeroTier authorization, fixed IP and interface binding; flow-rule procedure in Central; break-glass; runbook 0 to 9 with gate scenarios, rollbacks and the PR table; self-run rules and the workstation command; update and reboot policy; backup and restore; Key Store and template setup; new-key procedure; snapshot deadline; incident note for SH-E-35; bridge fallback (if used) | 0 |
| SH-DOC-04 | `<vm-dir>/CLAUDE.md` | Conventions and deviations (SH-CC-07 to SH-CC-09, SH-CC-14, SH-CC-15); stack table; data and secrets (values copied verbatim from the Pi, and why); file modes | 0 |
| SH-DOC-05 | `<vm-dir>/roles/*/README.md` | One per role. `semaphore`: migration, `semaphore_require_existing_db`, self-run, file modes. `caddy`: host networking, bind, `remote_ip`, fallback. `security`: sshd directives, reload, fail2ban, login email. `cloudflare_dns`: both A records and the CNAME gate. `firewall`: zones and interface binding | 0 |
| SH-DOC-06 | `<vm-dir>/docs/zerotier-flow-rules.md` | "Before" rule set (pull request A) and "in force" rule set (pull request A2), dated, with a link to Central's rules-language reference | 3 |
| SH-DOC-07 | NAS `README.md` "Backups", `CLAUDE.md`, `roles/restic_server/README.md`, `vault.yml.example` | Two clients; maintenance list; restore and repair commands per repository | 5 |
| SH-DOC-08 | NAS `roles/homepage/{README.md,defaults/main.yml,meta/argument_specs.yml,templates/services.yaml.j2}` | Semaphore group named `ops.de.wahlberger.dev`; no mention of the Pi | 8 |
| SH-DOC-09 | NAS `README.md` DOC-O5 | Restore from the detached drive through a local repository path | 9 |
| SH-DOC-10 | NAS `CLAUDE.md`, `roles/security/{README.md,defaults/main.yml,tasks/main.yml}`, `roles/ssh_authorized_keys/README.md`, `vars.yml` comments | Semaphore host named as `ops-de-wahlberger-dev`; key list rule SH-BR-10; revoked-keys input | 9 |
| SH-DOC-11 | cloud `CLAUDE.md` (the `ssh_authorized_keys` row, and the `restic_backup` row, which still says Pi), `site.yml` comment at `restic_backup`, `vars.yml` comments, `vault.yml.example`, `roles/{restic_backup,zerotier,beszel_hub,uptime_kuma,cloudflare_dns,ssh_authorized_keys}/README.md` | No Pi as Semaphore host or backup target | 9 |
| SH-DOC-12 | `architecture/ai-incident-remediation-pipeline.md` | Semaphore on `ops-de-wahlberger-dev` in "Current state", the diagram and "Trade-offs". The reason "pi ruled out because it holds the master keys" now applies to the VM, which also has public SSH (SH-R-01). "Shared fate" rewritten: Semaphore depends on ZeroTier and Hetzner, not on the home site | 8 |
| SH-DOC-13 | `homelab-architecture/forgejo-runner-placement.md` | A dated update note below "Context": Semaphore moved to `ops-de-wahlberger-dev`, the Pi is retired. The verified 2026-10-01 context stays as written | 9 |
| SH-DOC-14 | `.github/workflows/ci.yml` | Comments point at `ops-de-wahlberger-dev`'s `semaphore` role; the ansible-core pin is re-confirmed with `podman exec semaphore ansible --version` on the VM | 8 |
| SH-DOC-15 | `semaphore-migration/reqs/index.md` | This file's line | 0 |

### Out of Scope

- Migrating cloud-wahlberger-dev to openSUSE Tumbleweed. Deferred to a separate feature.
- Won't: SSH reachable only over ZeroTier, and a temporary bootstrap firewall rule (SH-R-01, SH-D-21).
- Won't: a console password or any password-holding account on the VM (SH-D-14).
- Won't: an email per fail2ban ban (SH-D-18).
- Won't: a separate automation Unix account (SH-D-16).
- Won't: ICMP or UDP 9993 in the Cloud Firewall (SH-D-15).
- Won't: backing up the ZeroTier identity (SH-D-19).
- Rotating the Vault passwords of nas, cloud or the Pi. Won't in this feature (SH-D-04, SH-R-06).
- An off-host detection channel for VM logins, for example shipping sshd logs to cloud. Deferred; the SH-FR-125 limitation is recorded in SH-R-01.
- Hardening the NAS's and cloud's sshd to the VM's level (SH-A-24). Deferred; neither host's SSH changes here.
- Managing Semaphore projects, templates or schedules as code. Won't (SH-D-06).
- Managing ZeroTier Central or Hetzner resources through an API from Ansible or Terraform. Won't.
- An offsite copy of NAS data to replace the Pi's frozen `nas` repository. Deferred to the offsite-backup feature (SH-R-05).
- Closing cloud-wahlberger-dev's public SSH port, or moving cloud SSH onto ZeroTier. Deferred (SH-D-05).
- The "remediation" Semaphore template and the n8n pipeline. Deferred to that decision.
- A Semaphore database other than SQLite, and Semaphore high availability. Not needed at one runner.
- Upgrading Semaphore during the migration. Upgrades happen only after step 8 (SH-FR-50, SH-FR-161).
- Setting up the Pi for embedded work after the re-image. Not part of this repository.
- Semaphore email or chat alerts for failed tasks. Deferred.
- Running a Forgejo Actions runner on this VM. Won't; the VM holds the master keys and stays single-purpose.
- `rpi-boras` and `dns-server`. Not affected.
- Editing the NAS backup specs in `nas-de-int-wahlberger-dev/reqs/`. They are historical records (SH-D-11).

### Open Questions

None.

Questions and answers (asked in version 0.1, answered by the owner on 2026-10-10):

| ID | Question | Answer |
|---|---|---|
| SH-Q1 | VM name, playbook directory, restic user | Restic user `ops` accepted. Names set by SH-Q12: `ops.de.wahlberger.dev`, directory `ops-de-wahlberger-dev` (SH-D-13) |
| SH-Q2 | Provisioning method and image | Default accepted: by hand with `hcloud`, nbg1 or fsn1, stock Tumbleweed image or the Minimal-VM Cloud image written from rescue mode |
| SH-Q3 | Bootstrap access before ZeroTier runs | Overridden: SSH permanently public, key-only; no temporary rule (SH-D-21) |
| SH-Q4 | Break-glass access when ZeroTier is down | Overridden: public SSH; rescue mode as last resort; no console password (SH-D-14) |
| SH-Q5 | Self-run rules | Default accepted: skip `semaphore` and `zerotier`, `common_upgrade=false` |
| SH-Q6 | Update cadence and reboot policy | Default accepted: weekly `zypper dup` on Sunday at 04:00; reboots only Sunday 04:00 to 05:00 |
| SH-Q7 | Backup content and the NAS holding the repository password | Default accepted: the NAS holds it and applies 7/4/6 retention; `config.json` and env files excluded |
| SH-Q8 | Pi's frozen repositories and USB drive | Default accepted: keep both repositories; detach the drive and store it offline |
| SH-Q9 | ZeroTier controller, current rules, allow matrix | ZeroTier Central; no rules exist (Central default); allow matrix accepted, including VM → NAS 8000 and cloud reached over its public IPv4 (row M-07 drop) |
| SH-Q10 | CX23 specification and price, cost ceiling, IPv6, snapshots | Default accepted: €6.00 per month ceiling, no IPv6, Hetzner Backups off; snapshots before steps 4 and 8 are a Could (SH-FR-102) with the SH-FR-170 deadline |
| SH-Q11 | Cloud Firewall management, UDP 9993 | Default accepted: by hand; 9993 closed; rule table now TCP 22 from anywhere only |
| SH-Q12 | DNS and the service hostname | `ops.de.wahlberger.dev` with the public A record; the `semaphore` CNAME points at a separate ZeroTier-IP name (`ops.de.int.wahlberger.dev`, SH-D-13); Pocket ID unchanged |
| SH-Q13 | Stabilization window and Pi leftovers | Default accepted: 14 days; delete the Pi's A record and directory; archive the 1Password item; re-image the SD card |

Decision log:
- 2026-10-10, version 0.1: draft with 13 open questions.
- 2026-10-10, version 1.0: owner answers applied (see the question table).
- 2026-10-10, version 1.1: refactor after the requirements audit (31/40; Atomic 3, Consistent 3).
  - Runbook:
    - step 9 reordered around a point of no return (SH-D-20);
    - step-6 rollback through a kept Key Store entry (SH-D-22);
    - pull requests made safe to apply early (SH-BR-16), with B split into B and B2 and the step-3 values put into a new pull request A2;
    - Renovate frozen for the Pi and for `<vm-dir>`'s Semaphore image (SH-FR-160, SH-FR-161);
    - Pi stop preconditions, configuration freeze and full-run freshness (SH-BR-13 to SH-BR-15);
    - a gate table covering every scenario.
  - Self-run: handlers analysed; sshd reload, no firewalld reload (SH-FR-188, SH-FR-189).
  - Caddy:
    - host networking tested by a runtime zone change (SH-AC-04);
    - the client-address test moved to step 3 (SH-AC-51);
    - bridge fallback specified (SH-FR-186, SH-FR-187);
    - no port 80 and no admin endpoint;
    - interface binding by name.
  - Security:
    - bounded hardening window instead of a temporary rule (SH-D-21);
    - personal-key protection and account two-factor authentication;
    - SH-FR-125 and SH-FR-126 raised to Must, with the email limitation recorded;
    - blast radius in SH-R-01;
    - file modes, snapshot deadline, ZeroTier identity excluded from backups;
    - workstation and Pi data destruction.
  - Migration: clean stop and companion-file handling; comparison against the live Pi API; decryption of every key row; scan for Pi-specific values; API tokens and integrations deleted; Pi `config.json` checked against the Vault.
  - Atomicity: compound FRs split.
  - Wording: ambiguous terms defined or replaced.
  - Measured-versus-inferred facts separated.
- 2026-10-10, version 1.2: final refactor after the second audit (31/40; Atomic 3, Consistent 3). Smallest changes; no new open questions. Decisions taken conservatively:
  - C1: the Pi template is dropped from the step-4 decryption check; Pi-only key rows go on the deletion list (no new allow-matrix row).
  - C2/G6: the step-6 rollback deletes the `<vm-dir>` project and uses the new pull request C-R, applied from the workstation; pull request C2 carries a SH-FR-191 address addition.
  - C3: migrated schedules that start in the SH-BR-07 window stay inactive and are listed for the owner.
  - C4: the `<vm-dir>` README runbook is added to the SH-FR-111 allowlist, as the historical record.
  - C5: FR-40, FR-128, FR-130, SH-AC-03, SH-AC-04 and SH-AC-29 are conditional on the primary design; SH-AC-61 no longer repeats SH-AC-51.
  - C6: SH-AC-05 probes `<vm-public-ip>`.
  - C7: pull request E changes only the nas and cloud lists.
  - C8: the pull request D row names the NAS homepage change and its apply.
  - C9: the SH-D-20 wording now places the point of no return at the first 9.3 action.
  - G1: the migration notes live in draft pull request C, opened in step 4.
  - G2: SH-AC-50 uses a manual cloud backup run.
  - G3: SH-FR-62 is a static list rule; the SH-FR-108 and SH-FR-174 clauses in SH-AC-41 are conditional.
  - G4: the step-9.3 log, with the SD erase on another host.
  - G5: SH-E-46; the step-2 rollback is deleting the server.
  - G7: SH-FR-156 applies from the workstation.
  - G8: the SH-FR-178 exemption for the retained old-key entry.
  - Smaller items:
    - the UID is read on the Pi;
    - the empty-interface guard (SH-FR-194);
    - a wider [H] definition;
    - SH-FR-195 (rebootmgr) and SH-FR-196 (access log) added;
    - the security-ID list is extended;
    - DNS cleanup in the step-3 rollback;
    - the SH-R-06 HDD residual risk is accepted;
    - placeholders defined;
    - SH-FR-101 reads the schedules before the stop;
    - SH-FR-12 and SH-FR-165 raised to Must;
    - SH-FR-29, SH-FR-109, SH-FR-112, SH-FR-124 and SH-FR-127 raised to Must, because a Must FR or gate depends on each;
    - gate clauses for the Should/Could FRs SH-FR-87, SH-FR-92, SH-FR-108, SH-FR-113, SH-FR-119, SH-FR-120, SH-FR-157 to SH-FR-159 and SH-FR-174 made conditional.
  - Splits: SH-FR-35 (into SH-FR-197 to SH-FR-199), SH-FR-97 (SH-FR-200), SH-FR-45 (SH-FR-201, SH-FR-202), SH-FR-176 (SH-FR-203, SH-FR-204), SH-FR-28 (SH-FR-205), SH-FR-144 (SH-FR-206), SH-FR-169 (SH-FR-207, SH-FR-208), SH-FR-170 (SH-FR-209).
- 2026-10-10, version 1.3: plan task T-01 (the plan's PA-1 to PA-10), after Erik approved the plan (gate B).
  - Owner decision: the Semaphore UID is read read-only on the Pi in step 3 and committed in the new pull request A3 (UID option A). No workstation `-e` is needed for SH-FR-70 reruns.
  - Variable contract:
    - `vm_proxy_design` (`primary` or `bridge_fallback`) feeds `caddy_design` and `semaphore_design` (SH-FR-220);
    - `vm_zt_iface` feeds `firewall_zerotier_interface`;
    - `semaphore_network_subnet` is `<sem-subnet>`;
    - `semaphore_uid` is guarded while empty (SH-FR-210).
  - Pull request A3 (end of step 3: selector, UID, README observations; SH-FR-221, SH-AC-64). Rows C, C2 and C-R are applied from the workstation; retry after C-R per SH-BR-18.
  - SH-D-12 stop condition and SH-E-47; SH-AC-51 required in both designs; SH-AC-62 split into two runs; SH-AC-03 checks permanent rich rules; fail2ban ban action without rich rules (SH-FR-211).
  - SH-FR-53, SH-AC-20 and SH-AC-22 order: comparison before the first VM task. The SH-AC-48 step-6 gate adds the cloud and self-run logins and the exact `from=` list.
  - SH-FR-91 note (it checks the Pi until step 8), TCP monitor `ops.de.int.wahlberger.dev:443` from step 4 (SH-FR-212), step-0 baseline (SH-FR-213, SH-AC-65).
  - SH-FR-73 queues an overrunning update's reboot to the next window; SH-FR-214 forbids reboots by the update script.
  - Wording:
    - task history except the Pi project;
    - SH-FR-162 now refers to SH-AC-05;
    - SH-FR-166 to SH-FR-168 split into SH-FR-215 to SH-FR-219;
    - step 8 reads the schedules immediately before the stop;
    - the step-3 fallback sequence spelled out;
    - SH-AC-07's reboot is the SH-AC-09 reboot;
    - SH-FR-198 compares with the baseline;
    - SH-FR-82 and SH-FR-152 are satisfied by one invocation.
  - New IDs: SH-FR-210 to SH-FR-221, SH-BR-18, SH-E-47, SH-E-48, SH-AC-64 to SH-AC-66.
