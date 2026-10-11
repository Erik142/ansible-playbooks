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

- Date: TODO: fill in (date of the step-0 reading)
- Source: ZeroTier Central, Flow Rules editor, network `8056c2e21cc5c789`
- Rule set (paste verbatim): TODO: fill in from the step-0 input. Per the spec, no flow rules existed on 2026-10-10 (Central default rule set).

## In force (rule set after the change)

Saved in step 3 by pull request A2 (SH-FR-34, SH-FR-192), after the rules are
written and the checks of SH-AC-11, SH-AC-12 and SH-AC-13 pass. Empty until then.

- Date: TODO: fill in with pull request A2
- Rule set (paste verbatim): TODO: fill in with pull request A2
