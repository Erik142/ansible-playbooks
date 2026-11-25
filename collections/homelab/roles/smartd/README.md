# smartd

Enables `smartd` and monitors the disks in `smartd_devices`. When smartd logs a
warning, a hook emails the owner through Resend (credentials from
`notify_failure`, so that role must run first). Not gated by
`backup_disk_enabled`: the main data HDD is watched from day one. Spec:
[reqs/smartd-main-disk.md](../../reqs/smartd-main-disk.md).

## What it does

- Installs `smartmontools`, `jq`, `curl`.
- Installs the hook `smartd_hook_path` (`/usr/local/bin/smartd-notify.sh`, mode 0750). Subject and body contain the device path and smartd's message.
- Writes one line per `smartd_devices` entry to `/etc/smartd.conf`, **before** `DEVICESCAN` (smartd ignores everything after it):

  ```
  <by-id path> -a -s (S/../../7/01|L/../01/./10) -m root -M exec /usr/local/bin/smartd-notify.sh
  ```

  Other lines (device lines, `DEVICESCAN`) are never removed. A hand-edited line for a listed device is replaced on the next run.
- Enables `smartd.service`; restarts it only when a line changed.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `smartd_devices` | the main HDD `ata-TOSHIBA_MG04ACA600EY_57I9K068FTTB` | List of `{device, schedule?, standby?}`. `device` is a `/dev/disk/by-id/` path; `schedule` overrides `smartd_default_schedule`; `standby: true` adds `-n standby` |
| `smartd_default_schedule` | `(S/../../7/01\|L/../01/./10)` | Short test Sundays 01:00, long test on the 1st at 10:00 |
| `smartd_hook_path` | `/usr/local/bin/smartd-notify.sh` | Hook path; `backup_disk` reuses it |
| `smartd_conf` | `/etc/smartd.conf` | Config file |

## Adding more disks

The root SSD `ata-INTEL_SSDSC2BW240A4_CVDA4471015P2403GN` and the NVMe
`nvme-Samsung_SSD_970_EVO_Plus_2TB_S4J4NM0R808398K` are one list entry each away
(not enabled). Override the whole list, since lists are not merged:

```yaml
smartd_devices:
  - device: /dev/disk/by-id/ata-TOSHIBA_MG04ACA600EY_57I9K068FTTB
  - device: /dev/disk/by-id/ata-INTEL_SSDSC2BW240A4_CVDA4471015P2403GN
  - device: /dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_2TB_S4J4NM0R808398K
```

The `backup_disk` role adds its own line (with `-n standby` when spindown is on); it is not listed here.

## What it does NOT do

- Does not monitor the root SSD or the NVMe unless you add them to `smartd_devices`.
- Does not send mail itself; the hook uses the Resend credentials from `notify_failure`.
- Does not touch other lines in `/etc/smartd.conf`, nor the `backup_disk` line.

Defaults are in `defaults/main.yml`.

## Verify on the host

`systemctl is-active smartd`, `grep -n . /etc/smartd.conf` (device lines above `DEVICESCAN`), `journalctl -u smartd -b`. To test the mail, add `-M test` to the line by hand and `systemctl restart smartd`; the next role run restores the line.
