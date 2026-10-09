# db_dump

Writes a consistent dump of every database before each btrbk run: one
`pg_dump` per `db_dump_postgres` entry (Paperless-ngx, Immich, Tandoor) and an
`sqlite3 .backup` copy of Forgejo's SQLite file. The dumps land in
`db_dump_dir` (default `/mnt/containers/db-dumps`), which btrbk snapshots as
part of `/mnt/containers`. Raw Postgres data directories are copied
crash-consistent by btrbk like everything else; the dumps are the additional,
restorable copy (BD-BR-11).

## How it runs

`db-dump.service` is a `Type=oneshot` unit with no timer and no `[Install]`
section. Only `btrbk.service` pulls it in (`Wants=`/`After=`), so the dumps are
fresh when btrbk snapshots `/mnt/containers`. Run it by hand with
`systemctl start db-dump.service`.

- Each dump is written to `<name>.sql.tmp` (or `forgejo.db.tmp`) and renamed
  over the previous file only when its command exited 0. A failed or stopped
  dump leaves the previous file untouched.
- Each dump is limited by `db_dump_timeout` (default `30min`) using
  `timeout(1)`. A stopped dump counts as failed. Note that stopping the
  `podman exec` client does not always stop `pg_dump` inside the container; it
  ends when its connection closes.
- Every remaining dump still runs after a failure. The script then exits 1, so
  `db-dump.service` ends `failed` and `OnFailure=notify-failure-immediate@%n.service`
  sends the alert. btrbk still runs and snapshots what exists (BD-FR-75).
- `RequiresMountsFor=` is the `storage_mounts` path containing `db_dump_dir`
  (`/mnt/containers`).

## Files and modes

| Path | Mode | Content |
|---|---|---|
| `db_dump_dir` (`/mnt/containers/db-dumps`) | `0700 root:root` | directory |
| `db_dump_dir/{paperless,immich,tandoor}.sql`, `forgejo.db` | `0600 root:root` | dumps |
| `db_dump_credentials_dir` (`/var/lib/db-dump`) | `0700 root:root` | directory, not below a `btrbk_sources` path |
| `db_dump_credentials_dir/<name>-pgpass.env` | `0600 root:root` | `PGPASSWORD=` for `podman exec --env-file` |
| `/usr/local/bin/db-dump.sh` | `0700 root:root` | dump script, no secrets |
| `/etc/systemd/system/db-dump.service` | `0644 root:root` | unit, no secrets |

The role fails before any change when:

- `db_dump_dir` is not below a `btrbk_sources` path (the message names `db_dump_dir`),
- `db_dump_credentials_dir` is below one (the passwords would enter the backups),
- the `storage_mounts` path containing `db_dump_dir` is not mounted in the live mount table,
- `db_dump_timeout` is not `<integer><s|sec|m|min|h>`, or a `db_dump_postgres` entry has an empty password.

## Rotating the Tandoor database password

The Tandoor password lives in the credentials file too, so rotate both together:

```sh
ansible-playbook site.yml --tags tandoor,db_dump
```

## Role variables

See `defaults/main.yml`; every variable is declared in `meta/argument_specs.yml`.
The role reads `btrbk_sources`, `storage_mounts`, `forgejo_volume_dir` and the
services' `*_db_password` variables from the other roles' defaults, so
`ansible.cfg` must not set `DEFAULT_PRIVATE_ROLE_VARS`. Two variables
(`db_dump_mount_path`, `db_dump_timeout_seconds`) are derived and normally not set.

## What this role does NOT do

- It does not schedule itself: no timer, and it is not enabled. `btrbk.service` triggers it.
- It does not run btrbk, create snapshots or touch the backup disk.
- It does not stop btrbk when a dump fails (BD-FR-75).
- It does not encrypt dumps or copy them off the host; btrbk replicates them with `/mnt/containers`.
- It does not remove credentials files of `db_dump_postgres` entries you delete later.
- It does not dump the services' media or data files; btrbk covers those.

## Inspect on the host

```sh
systemctl status db-dump.service
journalctl -u db-dump.service -n 50
stat -c '%a %U:%G %n' /mnt/containers/db-dumps /mnt/containers/db-dumps/*
```
