# hush_maintenance

Holds Hush alerts while an ansible apply restarts services on this host.

- `tasks/open.yml` (pre_tasks in `site.yml`) opens a Hush maintenance window scoped to
  `hush_maintenance_host_names`, for `hush_maintenance_duration_seconds` (1800 s).
- `tasks/close.yml` (post_tasks) ends it early.

Behaviour:

- Skipped in check mode, when disabled, when the host name list is empty, or when
  `hush_maintenance_ansible` (vault_hush_maintenance_ansible) is empty.
- A failed open does not stop the apply. A message says the alerts are not held.
- A failed close leaves the window to expire on its own. Real failures in that
  time are held, so the window is bounded by the duration.
- If the apply fails midway, post_tasks do not run and the window expires.
- Requests carry the token and run with `no_log`.
