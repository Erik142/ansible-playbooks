# ZeroTier flow rules for network `8056c2e21cc5c789`

Record of the Flow Rules editor content in [ZeroTier Central](https://my.zerotier.com/)
for the network, written by hand by the owner (SH-FR-132). Rules are written in
Central's rules language; reference: <https://docs.zerotier.com/rules/>
(TODO: verify URL).

Nothing in this repository reads or writes Central (no API token, SH-FR-205). This
file is the dated record only. The rules affect only traffic to or from the VM's
ZeroTier IP (`vm_zt_ip`); all other members keep Central's accept-all behaviour.

## Allow matrix (SH-BR-06)

"Initiator" opens the connection; replies to an allowed connection are allowed.

**Topology note (observed 2026-10-11).** The home MikroTik is the ZeroTier gateway
(ZeroTier address `10.243.163.88`, LAN addresses `10.10.0.1`, `10.10.10.1`, `10.10.100.1`).
It masquerades LAN to ZeroTier traffic, so a LAN device or the owner's Mac reaches the VM
as `10.243.163.88`; rows M-03 and M-04 are therefore both served by the `10.243.0.0/16`
rules, and the rules cannot tell individual LAN devices apart. ZeroTier to LAN traffic is
not masqueraded: the NAS sees the VM as `10.243.25.185`. The rules also carry the
un-NATed `10.10.0.0/16` forms of M-03, in case a flow ever arrives without NAT.
The filter is stateless and ZeroTier's rules language has no parentheses, so replies are
matched by their source port and each case is its own rule. Outbound ICMP from the VM is
limited to echo replies (M-08), so the VM's own "port unreachable" rejects never reach a
client: a refused port shows up as a timeout from the ZeroTier side.

| Row | Initiator | Destination | Port | Purpose | Decision |
|---|---|---|---|---|---|
| M-01 | VM (`vm_zt_ip`) | NAS LAN IPv4 | 22/tcp | Semaphore applies the NAS playbook | allow |
| M-02 | VM | NAS LAN IPv4 | 8000/tcp | restic backup to the NAS rest-server | allow |
| M-03 | home LAN 10.10.0.0/16 | VM | 22/tcp, 443/tcp | owner SSH and UI; NAS homepage status ping | allow |
| M-04 | ZeroTier members 10.243.0.0/16 | VM | 22/tcp, 443/tcp | owner devices; cloud's Uptime Kuma | allow |
| M-05 | cloud (`cloud_zt_ip`) | VM | 45876/tcp | Beszel hub to agent | allow |
| M-06 | home LAN, ZeroTier members | VM | ICMP echo | diagnostics | allow |
| M-07 | VM | cloud (`cloud_zt_ip`) | 22/tcp | cloud is reached over its public IPv4 (SH-D-05) | drop |
| M-08 | VM | any other ZeroTier or home-LAN address or port | any | none | drop |
| M-09 | any other initiator | VM | any other port | none | drop |

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

## In force (rule set after the change)

Saved in step 3 by pull request A2 (SH-FR-34, SH-FR-192), after the rules are
written and the checks of SH-AC-11, SH-AC-12 and SH-AC-13 pass. Empty until then.

- Date: 2026-10-11
- Source: ZeroTier Central, Flow Rules editor, network `8056c2e21cc5c789`
- Verified on the real network the same day (partial; the rest runs with the step-3 tests):
  - from the owner's Mac (arrives as the MikroTik, `10.243.163.88`): SSH to the VM works, port 80 never reaches the VM, port 443 does (tcpdump on `ztmjfaojmv`);
  - from the VM: `10.10.0.100:22` open, `10.10.0.100:80` and `10.243.203.116:22` blocked.
  - Not yet checked: cloud to the VM on 45876 (the Beszel agent comes in step 5), ICMP echo, HTTPS end to end (Caddy comes in step 3).
- Rule set (paste verbatim):
  ```
  #
  # ZeroTier flow rules for network 8056c2e21cc5c789  (ops VM = 10.243.25.185)
  # Replaces Central's default rule set; the default is saved under "Before" in
  # docs/zerotier-flow-rules.md. Only traffic to or from the VM is restricted.
  #
  # Language limits (docs.zerotier.com/rules): no parentheses, conditions are
  # evaluated left to right, the filter is stateless. So: one rule per case, and
  # replies are matched by their SOURCE port (22, 443, 45876, 8000), which a
  # reply has and a new connection from the VM does not.
  # The MikroTik source-NATs the home LAN into ZeroTier, so LAN devices reach the
  # VM from its ZeroTier address (10.243.163.88, covered by the 10.243.0.0/16
  # rules). The 10.10.0.0/16 rules cover traffic that arrives un-NATed.
  #

  # Baseline from Central's default set: only IPv4, ARP and IPv6 frames.
  drop
      not ethertype ipv4
      and not ethertype arp
      and not ethertype ipv6
  ;

  # M-07: VM -> cloud 22/tcp (cloud is reached over its public IPv4)
  drop
      ipsrc 10.243.25.185/32
      and ipdest 10.243.203.116/32
      and ipprotocol tcp
      and dport 22
  ;

  # M-01: VM -> NAS 22/tcp (Semaphore applies the NAS playbook)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.10.0.100/32
      and ipprotocol tcp
      and dport 22
  ;

  # M-02: VM -> NAS 8000/tcp (restic backup to the rest-server)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.10.0.100/32
      and ipprotocol tcp
      and dport 8000
  ;

  # Replies NAS -> VM for M-01 (source port 22)
  accept
      ipsrc 10.10.0.100/32
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and sport 22
  ;

  # Replies NAS -> VM for M-02 (source port 8000)
  accept
      ipsrc 10.10.0.100/32
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and sport 8000
  ;

  # M-03/M-04: ZeroTier members, incl. the MikroTik for the home LAN -> VM 22/tcp
  accept
      ipsrc 10.243.0.0/16
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and dport 22
  ;

  # M-03/M-04: ZeroTier members, incl. the MikroTik for the home LAN -> VM 443/tcp
  accept
      ipsrc 10.243.0.0/16
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and dport 443
  ;

  # M-03/M-04: home LAN, un-NATed -> VM 22/tcp
  accept
      ipsrc 10.10.0.0/16
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and dport 22
  ;

  # M-03/M-04: home LAN, un-NATed -> VM 443/tcp
  accept
      ipsrc 10.10.0.0/16
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and dport 443
  ;

  # M-05: cloud -> VM 45876/tcp (Beszel hub to agent)
  accept
      ipsrc 10.243.203.116/32
      and ipdest 10.243.25.185/32
      and ipprotocol tcp
      and dport 45876
  ;

  # Replies VM -> ZeroTier members (source port 22)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.243.0.0/16
      and ipprotocol tcp
      and sport 22
  ;

  # Replies VM -> ZeroTier members (source port 443)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.243.0.0/16
      and ipprotocol tcp
      and sport 443
  ;

  # Replies VM -> home LAN, un-NATed (source port 22)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.10.0.0/16
      and ipprotocol tcp
      and sport 22
  ;

  # Replies VM -> home LAN, un-NATed (source port 443)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.10.0.0/16
      and ipprotocol tcp
      and sport 443
  ;

  # Replies VM -> cloud (source port 45876)
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.243.203.116/32
      and ipprotocol tcp
      and sport 45876
  ;

  # M-06: echo request ZeroTier members -> VM
  accept
      ipsrc 10.243.0.0/16
      and ipdest 10.243.25.185/32
      and ipprotocol 1
      and icmp 8 0
  ;

  # M-06: echo reply VM -> ZeroTier members
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.243.0.0/16
      and ipprotocol 1
      and icmp 0 0
  ;

  # M-06: echo request home LAN -> VM
  accept
      ipsrc 10.10.0.0/16
      and ipdest 10.243.25.185/32
      and ipprotocol 1
      and icmp 8 0
  ;

  # M-06: echo reply VM -> home LAN
  accept
      ipsrc 10.243.25.185/32
      and ipdest 10.10.0.0/16
      and ipprotocol 1
      and icmp 0 0
  ;

  # M-08: VM -> any other ZeroTier address
  drop
      ipsrc 10.243.25.185/32
      and ipdest 10.243.0.0/16
  ;

  # M-08: VM -> any other home-LAN address
  drop
      ipsrc 10.243.25.185/32
      and ipdest 10.10.0.0/16
  ;

  # M-09: anything else to the VM
  drop
      ipdest 10.243.25.185/32
  ;

  # Everything not involving the VM keeps Central's accept-all behaviour.
  accept
  ;
  ```
