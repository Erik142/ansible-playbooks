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

- Date: TODO: fill in with pull request A2
- Rule set (paste verbatim): TODO: fill in with pull request A2
