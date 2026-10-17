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

## Before (Central's rule set in force before the change)

Saved in step 0 (SH-FR-33), before the flow rules are changed. Filled in by the
pull-request-A packaging task (T-19) from the text you save in step 0; used to
restore the network in the step-3 rollback.

- Date: 2026-10-11
- Source: ZeroTier Central, Flow Rules editor, network `8056c2e21cc5c789`
- Rule set (paste verbatim): Per the spec, no flow rules existed on 2026-10-10 (Central default rule set).
  ```
  #
  # This is a default rule set that allows IPv4 and IPv6 traffic but otherwise
  # behaves like a standard Ethernet switch.
  #
  # Please keep in mind that ZeroTier versions prior to 1.2.0 do NOT support advanced
  # network rules.
  #
  # Since both senders and receivers enforce rules, you will get the following
  # behavior in a network with both old and new versions:
  #
  # (old: 1.1.14 and older, new: 1.2.0 and newer)
  #
  # old <--> old: No rules are honored.
  # old <--> new: Rules work but are only enforced by new side. Tags will NOT work, and
  #               capabilities will only work if assigned to the new side.
  # new <--> new: Full rules engine support including tags and capabilities.
  #
  # We recommend upgrading all your devices to 1.2.0 as soon as convenient. Version
  # 1.2.0 also includes a significantly improved software update mechanism that is
  # turned on by default on Mac and Windows. (Linux and mobile are typically kept up
  # to date using package/app management.)
  #

  #
  # Allow only IPv4, IPv4 ARP, and IPv6 Ethernet frames.
  #
  drop
      not ethertype ipv4
      and not ethertype arp
      and not ethertype ipv6
  ;

  #
  # Uncomment to drop non-ZeroTier issued and managed IP addresses.
  #
  # This prevents IP spoofing but also blocks manual IP management at the OS level and
  # bridging unless special rules to exempt certain hosts or traffic are added before
  # this rule.
  #
  #drop
  #	not chr ipauth
  #;

  # Accept anything else. This is required since default is 'drop'.
  accept;
  ```

## Network rule set in force (2026-10-17)

The ops playbook's rules were pasted and entered in Central. They cover only the
ops VM (`10.243.25.185`), and they end with a final `accept` for everything else.
The netcup host's rules below are not entered yet. Until they are, netcup traffic
is accept-all.

## Proposed netcup rules (not in force)

```
# Proposed netcup rules, to insert in Central BEFORE the final `accept` line.
# Host 10.243.73.1 (ztmjfaojmv). Not in force until entered by hand.

# C-01: runner -> NAS Forgejo, 443/tcp
accept
    ipsrc 10.243.73.1/32
    and ipdest 10.10.0.100/32
    and ipprotocol tcp
    and dport 443
;

# C-01 reply: NAS Forgejo -> runner (source port 443)
accept
    ipsrc 10.10.0.100/32
    and ipdest 10.243.73.1/32
    and ipprotocol tcp
    and sport 443
;

# C-02: ZeroTier members -> runner, 22/tcp
accept
    ipsrc 10.243.0.0/16
    and ipdest 10.243.73.1/32
    and ipprotocol tcp
    and dport 22
;

# C-02 reply: runner -> ZeroTier members (source port 22)
accept
    ipsrc 10.243.73.1/32
    and ipdest 10.243.0.0/16
    and ipprotocol tcp
    and sport 22
;

# C-03: cloud -> runner, 45876/tcp (Beszel hub)
accept
    ipsrc 10.243.203.116/32
    and ipdest 10.243.73.1/32
    and ipprotocol tcp
    and dport 45876
;

# C-03 reply: runner -> cloud (source port 45876)
accept
    ipsrc 10.243.73.1/32
    and ipdest 10.243.203.116/32
    and ipprotocol tcp
    and sport 45876
;

# C-04: echo request, ZeroTier members and home LAN -> runner
accept
    ipsrc 10.243.0.0/16
    and ipdest 10.243.73.1/32
    and ipprotocol 1
    and icmp 8 0
;

accept
    ipsrc 10.10.0.0/16
    and ipdest 10.243.73.1/32
    and ipprotocol 1
    and icmp 8 0
;

# C-04 reply: echo reply, runner -> ZeroTier members and home LAN
accept
    ipsrc 10.243.73.1/32
    and ipdest 10.243.0.0/16
    and ipprotocol 1
    and icmp 0 0
;

accept
    ipsrc 10.243.73.1/32
    and ipdest 10.10.0.0/16
    and ipprotocol 1
    and icmp 0 0
;

# C-05: runner -> any other ZeroTier or home-LAN address
drop
    ipsrc 10.243.73.1/32
    and ipdest 10.243.0.0/16
;

drop
    ipsrc 10.243.73.1/32
    and ipdest 10.10.0.0/16
;

# C-06: anything else to the runner
drop
    ipdest 10.243.73.1/32
;
```
