# T-16 fixture results (simulator, aarch64)

Every result below is **simulator, aarch64**: openSUSE Tumbleweed (kernel 7.2.9, built 2026-10-11) in qemu/HVF on an
arm64 Mac, qemu user-mode NAT, a veth pair `zt0` (stand-in ZeroTier address 198.51.100.10, client namespace
198.51.100.20, second client source 203.0.113.5), SELinux **permissive**. Nothing here was measured on x86_64,
on the Hetzner VM, or with ZeroTier. Run date 2026-10-11. Raw lines: `$FIXTURE_VM_DIR/results/results.tsv`
(ids in brackets). Roles applied: `security, firewall, podman, caddy, semaphore` via `tests/vm/ans.sh`.
No `op`, no `.vault_pass.sh`, no production vault; Caddy used `tls internal` (see "Outbound contact").

## Scenarios (acceptance criteria of T-16)

| Criterion | Result (simulator, aarch64) |
|---|---|
| Apply via `ans.sh`, second run idempotent | PASS. First real run ok=90 changed=7 (after fixing two fixture values, see below), second run ok=87 **changed=0**; `--check --diff` of the fallback switch on the applied host: changed=0 for the same state [APPLY-1, APPLY-2, FALLBACK-CHECK] |
| Zone binding exists in `--permanent`, survives `firewall-cmd --reload` and reboot | PASS. Permanent zone `zerotier` has `interfaces: zt0`, services `https ssh`, rich rule for 198.51.100.99:45876. After the creating run and **before** any reload the running firewalld did not know the zone (`no zone` for zt0) and the client's https was refused (rc=7); after `--reload` zt0 was in zone `zerotier` and https answered 200; after a guest reboot (zt0 service started after firewalld) zt0 was again in `zerotier` [FW-PERM-BIND, FW-RUNTIME-PRE-RELOAD, FW-RELOAD, FW-REBOOT] |
| Primary: `--remove-service=https` (runtime) blocks, re-adding restores | PASS. Client request from namespace `ztpeer`: 200 -> `000 rc=7` (refused) -> 200 [HTTPS-BASE, HTTPS-REMOVED, HTTPS-READDED]. Note: a request from the host to its own ZT address uses `lo` and never meets zone rules, so the test must come from another namespace/host |
| `ss -tlnp`: Caddy only on stand-in IP:443, no :80, no :2019 | PASS. Only `198.51.100.10:443` (caddy). Other listeners: sshd :22 and aardvark-dns on 172.29.30.1:53 (the semaphore network) [CADDY-LISTENERS, `results/ss-primary.txt`] |
| Caddy restarts by itself after the address appears (A-20) | PASS. Interface removed + `systemctl restart caddy`: unit stays `activating`, `Result=exit-code`, NRestarts=2 after 25 s. After `systemctl start fixture-zt0` Caddy listened on 198.51.100.10:443 again within 8 s (RestartSec=10), NRestarts=3. The re-created zt0 was in zone `zerotier` immediately, without any reload (firewalld matches the interface by name) [A20-WITHOUT-ADDR, A20-RECOVERY, A20-ZONE-LATE] |
| Primary: client address and `remote_ip` allow list (AC-51 analogue) | PASS. Host-networked Caddy logged `remote_ip` 198.51.100.20 (allowed) and 203.0.113.5; the latter, outside `caddy_allowed_sources`, got 403 [REMOTE-IP-DENY, CLIENT-ADDR-PRIMARY] |
| Bridge fallback (A-22): published port vs zone rules | **Bypassed.** With `vm_proxy_design=bridge_fallback`: no host listener on :443 (DNAT by netavark to 10.89.0.3:443, `table inet netavark`); with `https` removed from zone `zerotier` the client still got **200** (primary design: refused). Only firewalld's `filter_IN_zerotier_allow` carries a `tcp dport 443 accept` line, it was not needed [FB-LISTENERS, FB-DNAT, FB-HTTPS-REMOVED] |
| Bridge fallback: client source address survives | PASS (survives). Caddy's log showed 198.51.100.20 and 203.0.113.5, not the bridge gateway; the 403 for 203.0.113.5 was enforced [FB-CLIENT-ADDR, FB-REMOTE-IP] |
| `sshd` reload keeps an established session (A-30) | PASS. A session opened before `systemctl reload sshd` printed its final line after the reload; sshd MainPID 635 unchanged, journal `Received SIGHUP; restarting`. New connections right after the reload: 1 attempt refused (`kex_exchange_identification: Connection reset`) before one succeeded at 0.25 s spacing [SSHD-RELOAD, SSHD-RELOAD-NEW-CONN] |
| fail2ban bans after 5 failures; public-zone rich rules empty | PASS. `banaction = nftables-multiport`, maxretry 5. 6 failed logins as `baduser` from 198.51.100.20, 7 s apart -> 5 counted failures, 198.51.100.20 banned (`table inet f2b-table`); `firewall-cmd --permanent --zone=public --list-rich-rules` and the runtime list stayed **empty** before and after; the fixture's own ssh stayed usable. Reproduced in a second run. (The first run's `F2B-RICH-RULES FAIL` / `SSHD-RELOAD FAIL` in the tsv were errors in the scenario script's string compare / reload probe, fixed in `s40`; the second run is the result) [F2B-BAN, F2B-NFT, F2B-RICH-RULES, F2B-OWN-SESSION] |
| `ls -Z` of the DB shows `container_file_t` after first start (FR-208) | PASS (permissive SELinux). `database.sqlite`, `data/` and `config.json`: `system_u:object_r:container_file_t:s0:c115,c465`. Owner/mode: data 1001:0 0700, database.sqlite 1001:0 0600, config.json 1001:0 0600, semaphore.env 0:0 0600. Semaphore container up, admin user created [DB-LABEL, DB-MODE-NUMERIC, SEMAPHORE-UP] |
| `dhcpv6-client` removal | PASS. Stock public zone `dhcpv6-client ssh` before any role; after the firewall role runtime and permanent lists are exactly `ssh`; permanent public rich rules empty. Zone `zerotier` services: `https ssh` [FW-BASELINE, FW-PUBLIC-SERVICES, FW-ZT-SERVICES] |
| zypper exit 103 handling | MEASURED, not reproduced for real. `zypper-dup.service` has only `SuccessExitStatus=102`. A stand-in unit with the same setting: exit 102 -> "Finished with result: success"; exit **103 -> "Finished with result: exit-code"** (the real unit would fail and fire `OnFailure=notify-failure-immediate`). A real `zypper dup --dry-run` on the fresh image returned 0, so no natural 103 occurred [ZYPPER-UNIT, ZYPPER-103-SYSTEMD, ZYPPER-DUP-DRYRUN] |
| rebootmgr | `rebootmgrctl`: active, strategy maint-window, window `Sun *-*-* 04:00:00` lasting 01:00, "Reboot not requested" [REBOOTMGR]. Overrun behaviour and a real reboot were not exercised |

Also measured: `sshd -T` shows `Subsystem sftp /usr/libexec/ssh/sftp-server`, `AllowUsers fixture`, `MaxAuthTries 3`,
`PasswordAuthentication no`, `AuthenticationMethods publickey` (vendor file was seeded; T-05 F-1 holds on this image) [SSHD-T].
After a reboot netavark places the semaphore bridge subnet in zone `trusted` at runtime (`trusted: sources 172.29.30.0/24`, in the
fallback `10.89.0.0/24`), not in the permanent configuration.

## Defects for the owning role task (not fixed here)

1. **T-07 `firewall` (blocker for the OP-02 first `--check --diff`): FIXED 2026-10-11.** On a fresh host `--check --diff`
   failed in `roles/firewall/tasks/zerotier.yml` "Allow services in the ZeroTier zone" (`INVALID_ZONE: zerotier`) because the
   zone creation is only simulated in check mode, which stopped the play. Fix: `firewall_zerotier_zone_ready` (true in a real
   run; in check mode only if the permanent configuration already holds the zone) gates the three zone-dependent tasks, so on a
   fresh host check mode **skips** them and cannot validate them (`roles/firewall/README.md`). The same fresh-host problem was
   then found and fixed in `podman` (image-prune timer), `caddy` and `beszel_agent` (handlers and units, group, dir, binary,
   sefcontext) and `restic_backup` (timer), each tolerating only the exact "created by an earlier simulated task" miss in
   check mode; real runs are unchanged. Guard: `tests/guards.d/firewall.yml`. Fixture proof (snapshot `clean`,
   `--skip-tags cloudflare_dns`, the DB stand-in as s00): fresh `--check --diff` rc=0 failed=0; real apply ok=165 failed=0;
   second apply changed=1 (the zerotier container re-modes its data dir on first start, third apply changed=0); `--check` on
   the applied host changed=0; s10 and s20 pass. Not run on the fixture: `cloudflare_dns` (needs the real Cloudflare API; the
   fixture blackholes it), and the real apply used a dummy `zerotier_network_id`.
2. **T-06 `security` (decision)**: `zypper-dup.service` treats exit 103 (zypper updated itself, re-run needed) as a
   failure: the unit fails and sends the immediate failure mail although nothing is wrong. Measured with a stand-in unit
   (above). Decide: add 103 to `SuccessExitStatus` (and re-run zypper), or accept the mail.
3. **Doc/T-17 note, not a defect**: Caddy with the Cloudflare module refuses to start when the token does not look like a
   token, even with `tls internal` (a 31-character fake failed, a 40-character fake loaded). A wrong-shaped token in
   production fails Caddy at load, not at certificate time.
4. **Design input for step 3 (SH-D-12)**: in the bridge fallback the zone rules do **not** gate port 443; the remaining
   controls are the `remote_ip` allowlist and the DNAT bound to the ZT address (as SH-R-04 expects). The primary design
   is gated by the zone.

## Outbound contact

Sites used `tls internal`; `/etc/hosts` in the guest points the ACME, Cloudflare and Resend hosts at 127.0.0.1;
`notify_failure` was not applied (nothing can send mail, `OnFailure=` points at a missing unit). Caddy's logs contained 0
lines mentioning acme/letsencrypt/cloudflare/obtain [NO-OUTBOUND]. This is a log check, not a packet capture. The guest
did reach the network for zypper, Docker Hub (caddy builder, semaphore) and GitHub/Go modules (xcaddy build).

## Fixture problems met (not role defects)

- Fake secret values must be well-formed: Semaphore panics on an `access_key_encryption` that is not 16/24/32 base64-decoded
  bytes; Caddy's Cloudflare module rejects a short token. First apply failed on both; fixed in `inventories/vm`.
- `snapper create-config /` failed because `build-root.sh` (copied from the NAS fixture) mounted a `/.snapshots`
  subvolume; `provision-guest.sh` now removes it. I applied that step to the running guest from the script and re-snapshotted
  `clean`; a from-scratch `up.sh` with the final script was **not** re-run.

## Not verified

x86_64, the real Hetzner image (vendor sshd layout, SELinux enforcing, zypper dup 102/103 for real, rebootmgr window overrun),
ZeroTier (interface timing, client addresses, Central flow rules), real Cloudflare/ACME, the Pi database copy, enforcing SELinux,
`cloudflare_dns`, `notify_failure`, `reboot_notify`, `zerotier`, `common`, `ssh_authorized_keys` roles (not applied).
