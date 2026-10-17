# ZeroTier flow rules for network `8056c2e21cc5c789`, netcup CI host

**Status: PROPOSED, facts verified 2026-10-17. Not in force.** Entering the rules in
ZeroTier Central is a manual step, and nothing in this repository reads or writes
Central. Update the "Before" and "In force" sections when the rules are entered.

## Scope

The rules affect only traffic to or from this host's ZeroTier IP, `10.243.73.1`
(`vm_zt_ip`). Other members keep Central's current behaviour. The network's default
rule set is accept-all, so this host gets an explicit allow-list and a final drop.

## Allow matrix (this host as initiator or responder)

| Row | Initiator | Destination | Port | Purpose | Decision |
|---|---|---|---|---|---|
| C-01 | this host (`10.243.73.1`) | NAS LAN `10.10.0.100` (`git.de.int.wahlberger.dev`) | 443/tcp | runner polls and reports jobs, outbound | allow |
| C-01r | NAS LAN `10.10.0.100` | this host (`10.243.73.1`) | 443/tcp (source port) | replies to C-01 | allow |
| C-02 | ZeroTier members `10.243.0.0/16` | this host | 22/tcp | SSH over ZeroTier | allow |
| C-03 | cloud (`10.243.203.116`) | this host | 45876/tcp | Beszel hub to agent | allow |
| C-04 | home LAN `10.10.0.0/16`, members | this host | ICMP echo | diagnostics | allow |
| C-05 | this host | any other address or port | any | none | drop |
| C-06 | any other initiator | this host | any other port | none | drop |

Explicitly denied, so the rules document it even though C-05 covers it:

- the home LAN as a whole (`10.10.0.0/16`), except ICMP echo (C-04)
- the NAS's Samba shares, including the guest-RW share
- the NAS's other services and SSH (22/tcp), and any other host

## Verified facts (2026-10-17, from the host)

- `git.de.int.wahlberger.dev` resolves to `10.10.0.100`, the NAS LAN address.
- The route to `10.10.0.100` goes via the home gateway ZeroTier address
  `10.243.163.88` on `ztmjfaojmv`. ZeroTier to LAN traffic is not masqueraded
  (see `ops-de-wahlberger-dev/docs/zerotier-flow-rules.md`), so the NAS sees the
  source as `10.243.73.1`.
- Forgejo answers `https://10.10.0.100` with a certificate that the system trust
  store accepts, so the runner needs no extra CA.
- Only traffic to `10.10.0.0/16` uses ZeroTier. Image pulls and the rest of the
  runner's outbound traffic use the public default route (`ens3`), so these rules
  do not affect them.

## Notes

- The filter is stateless. Replies are matched by their source port, so each
  direction needs its own rule (C-01 and C-01r).
- Entries carry the same dated before/after record as the ops file. The "before"
  section is filled from Central's rule set at the time of the change.

## Before

Not yet recorded. Save Central's current Flow Rules text verbatim before any
change (default rule set expected, as on the ops network on 2026-10-10).

## In force

Not in force.
