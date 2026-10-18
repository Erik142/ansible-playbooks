# Spike T-02: Garage v2.4.1 configuration keys, CLI syntax, lifecycle API, image tags

Date: 2026-10-17/18. Spec: `reqs/garage-sstate.md` v0.7. Environment: Docker Desktop on macOS arm64, single throwaway node
`docker.io/dxflrs/garage:v2.4.1` (arm64 image available, reports `v2.4.1`), data in a temp dir outside the repo,
docker network with the node aliased `garage`. No NAS, no vault. All keys and secrets below were generated for the spike.
Label per item: VERIFIED (observed) or UNVERIFIED (reason).

## Summary

| Item | Result | Spec impact |
|---|---|---|
| GS-A-01 `[s3_web]` without `root_domain` | VERIFIED: **fails to parse** | CONTRADICTS GS-FR-38, O-1, GS-AC-38 |
| GS-A-01 `[s3_api] advertise_path_style` | VERIFIED: key does not exist in v2.4.1 (omit) | confirms the spec fallback |
| GS-A-21 owner-only key and lifecycle | VERIFIED: **403** for Get/Put/Delete | CONTRADICTS GS-A-21, GS-FR-105, GS-AC-62 |
| GS-A-02 CLI syntax | VERIFIED, with deviations below | minor wording |
| GS-A-10 rpc 127.0.0.1:3901 + exec CLI | VERIFIED | none |
| GS-A-03 secret file mode | VERIFIED | none |
| GS-A-09 capacity semantics | UNVERIFIED empirically (config/doc level only) | none |
| GS-A-22 quota | VERIFIED | none |
| GS-A-26 / GS-FR-84 image tag and user | VERIFIED | `garage_s3_client_image` tag decided |

## Amendment list for requirements-engineer (contradictions, not worked around)

1. **GS-A-01 / GS-FR-38 / O-1 / GS-AC-38**: `[s3_web]` without `root_domain` is a config error; Garage refuses to start.
   Evidence:
   ```
   Error: TOML decode error: TOML parse error at line 11, column 1
   11 | [s3_web]
   missing field `root_domain`
   ```
   The empty string `root_domain = ""` and `".s3.test"` and `"s3.test"` all parse. Behaviour with `".s3.test"` on the web port 3902
   (bucket `sstate`, website enabled, object `selftest/up`): `Host: sstate` -> 200, `Host: sstate.s3.test` -> 200, `Host: s3.test` -> 404.
   So a bare `Host: <bucket>` maps to the bucket with a root_domain set (feeds GS-A-15, to be confirmed in T-03 through Caddy).
   Needed decision: which value `[s3_web] root_domain` takes (spec fallback says `<garage_s3_domain>` without a leading dot; GS-CC-16 text used a leading dot).
   Whether `""` is functionally acceptable was not tested beyond parsing.
2. **GS-A-21 / GS-FR-105 / GS-FR-103 / GS-AC-60 / GS-AC-62**: Lifecycle authorization in Garage does NOT follow the `owner` flag.
   Observed matrix for a key on bucket `sstate` (put = PutBucketLifecycleConfiguration, get = GetBucketLifecycleConfiguration, del = DeleteBucketLifecycle):

   | grants | put | get | del |
   |---|---|---|---|
   | owner | 403 AccessDenied | 403 | 403 |
   | owner + read | 403 | ok (NoSuchLifecycleConfiguration when unset) | 403 |
   | owner + write | ok | 403 | ok |
   | read + write | ok | ok | ok |
   | owner + read + write | ok | ok | ok |
   | read | 403 | ok | 403 |
   | write | ok | 403 | ok |

   Put/Delete need `write`, Get needs `read`; `owner` is irrelevant. Consequences: (a) `bucket-admin` needs `read: true, write: true` to run
   GS-FR-102 (Get then Put/Delete), so it also has full object read/write/delete; "owner-only, 403 on object GET" cannot hold.
   (b) `ci-upload` (read+write, no owner) can Get/Put/Delete the lifecycle too (verified `get` ok), so the credential separation of GS-FR-103
   is by convention only, not enforced by Garage. Owner-only key: object GET, PUT, DELETE and list all give 403 (curl sigv4: GET object 403, GET `?lifecycle` 403).
   Needed decision: new grants for `bucket-admin` (read+write, drop or keep `owner`), and rewrite of GS-AC-62 and the security rationale.

## GS-A-01 configuration keys

- `[s3_api] advertise_path_style`: VERIFIED absent. The binary contains no such string (`grep -a -c advertise_path_style garage` = 0) and the
  parser silently ignores unknown keys (a deliberate `bogus_key_xyz = true` parsed without error), so omit it. Do not rely on "parses fine" as proof for any key.
- Minimal working config used (O-1 otherwise as specified): `replication_factor=1`, `rpc_bind_addr`/`rpc_public_addr="127.0.0.1:3901"`,
  `rpc_secret_file`, `[s3_api] api_bind_addr="0.0.0.0:3900" s3_region="garage"`, `[s3_web] bind_addr="0.0.0.0:3902" root_domain=".s3.test"`,
  `[admin] api_bind_addr="127.0.0.1:3903" admin_token_file=...`. Log: `S3 API server listening on http://0.0.0.0:3900`, `Admin API ... 127.0.0.1:3903`.
- `[s3_api] root_domain` unset: path-style works (aws-cli against `http://garage:3900` with no extra config).
- CLI config path: the image entrypoint is `/garage server`, default config `/etc/garage.toml`; no `id`, `sh`, `timeout` in the image (scratch-style, only `/garage`).

## GS-A-10 RPC on loopback

VERIFIED. `rpc_bind_addr = rpc_public_addr = "127.0.0.1:3901"`; `docker exec <c> /garage status` works:
```
==== HEALTHY NODES ====
8a83af58c1187de4  acf2a79f8361  127.0.0.1:3901  NO ROLE ASSIGNED  v2.4.1      (rc=0)
```
Every CLI call prints two `INFO garage_net::netapp` lines (connect, handshake) on stderr; parse stdout only (or discard stderr).
Node ID for scripting: first column of `garage status` (16 hex chars, prefix accepted by `layout assign`).

## GS-A-02 / GS-A-22 CLI syntax (exit codes)

- `layout show`: with no roles prints `No nodes currently have a role in the cluster.` and `Current cluster layout version: 0` (rc 0).
  Staged changes show `==== STAGED ROLE CHANGES ====` and the line `To enact ... garage layout apply --version N`.
- `layout assign -z <zone> -c <cap> <node-id>...` (also `-g`, `-t`, `--replace`). rc 0, prints "Role changes are staged but not yet committed."
  Unknown node: `Error: 0 nodes match 'deadbeef'` rc 1. Bad capacity: `couldn't parse "abc" into a ByteSize` rc 1.
  Re-assigning the same role to an applied node stages nothing visible and rc 0.
- `layout apply --version <n>`: rc 0 on success; a wrong version gives `Internal error: Invalid new layout version`, rc 1. Pitfall:
  `layout apply --version <current+1>` with NOTHING staged still succeeds (rc 0) and bumps the version (1 -> 2 observed). The role must therefore
  guard on "this node has a role / nothing staged" as GS-FR-14 says, never apply blindly.
- `layout revert --yes` drops staged changes (rc 0).
- `bucket create <name>`: rc 0 prints bucket info; repeat gives `BucketAlreadyExists (409)` rc 1. `bucket_name` with `_` rejected (rc 1, 400);
  a dotted name (`ab.c`) is ACCEPTED by Garage, so the spec's no-dot rule (GS-FR input regex) is the role's own check, not Garage's.
- `bucket list` columns: `ID  Created  Global aliases  Local aliases` (ID truncated to 16 hex). `bucket info <name>` rc 1 `NoSuchBucket (404)` when missing.
  `bucket info` shows `Website access: true|false`, `Quotas: enabled`, `maximum size: 536.9 GB (500.0 GiB)`, and the key table (`RW`, `O`, `R O`, ... letters then key ID and name).
- `bucket website --allow <bucket>` / `--deny <bucket>` (also `-i`, `-e`): rc 0, idempotent (repeat is rc 0, prints info). Default index document `index.html`.
- `bucket allow <bucket> --key <id|name> [--read] [--write] [--owner]`, `bucket deny` same flags: rc 0; unknown key rc 1 `NoSuchAccessKey`; unknown bucket rc 1.
  `deny --write` removes only that flag (RW -> R). With no flag, rc 0 and nothing changes. `--owner` exists on both (spec GS-A-02 wording "bucket create --owner" does not exist; `--owner` is on allow/deny).
- `bucket set-quotas <bucket> --max-size <size> [--max-objects]`: rc 0, always prints bucket info (not change-detecting; compare via `bucket info`).
  Size accepts `500GiB`, `1.5GiB`; `none` removes; `bogus` rc 1. `bucket info` renders the stored size as `536.9 GB (500.0 GiB)`, so compare on the GiB figure in parentheses.
- `key import --yes -n <name> <GK id> <secret>`: positional order key-id then secret. Without `--yes` rc 1 ("Add the --yes flag if you really want to re-import a key").
  Existing ID: rc 1 `KeyAlreadyExists (409)`. Output hides the secret (`(redacted)`). Note the secret appears on the command line (process list inside the container); keep `no_log`.
- `key info <id|name>` rc 0 (secret `(redacted)`); `key info --show-secret <id>` prints `Secret key:` with the 64-hex value; unknown rc 1 `NoSuchAccessKey (404)`.
  `key info <name>` also resolves by name. `key create <name>` generates a key.
- Formats: key ID `GK` + 24 hex (26 chars) VERIFIED for both generated and imported (import accepted a `GK`+24 hex ID); secret 64 hex VERIFIED (generated key and imported key).
- `block list-errors`: rc 0, prints header `Hash  RC  Errors  Last error  Next try` and no rows on a healthy node.

## GS-A-09 layout capacity

UNVERIFIED as a behaviour claim (cannot fill a 500 GiB store here). Observed only that capacity is a declared weight: `-c 500GB` is decimal and
shows as `465.7 GiB`, `-c 500GiB` shows `500.0 GiB`, `-c 1TB` = 931.3 GiB. Suffixes accepted: `B KB MB GB TB PB` and also `GiB`, `G`, `T`; both `500GiB` and `500GB` rc 0.
Caution: `500GB` != `500GiB`; choose the unit explicitly in `garage_layout_capacity`. Quotas (not capacity) are the limit; no layout test of overcommit was run.

## GS-A-03 secret file modes

VERIFIED. Mode `0400` starts. Modes `0640`, `0440`, `0644` (rpc_secret and admin_token each) refuse to start:
```
Error: File /sec/rpc_secret is world-readable! (mode: 0100640, expected 0600)
Refusing to start until this is fixed, or environment variable GARAGE_ALLOW_WORLD_READABLE_SECRETS is set to true.
```
So any group or other bit is refused (the message says "world-readable" even for a group-only bit), `root:<gid> 0440` would fail as the spec already assumes.
Not tested: a non-root `--user` reading an owner-only file (the image default user is root; macOS bind mounts do not give reliable ownership). Confirm on the VM.

## GS-A-21 lifecycle with aws-cli (see matrix above)

Working environment and commands (aws-cli `2.38.1`, container on the same network as the node):
```
docker run --rm --network <net> \
  -e AWS_ACCESS_KEY_ID=<GK..> -e AWS_SECRET_ACCESS_KEY=<64hex> -e AWS_DEFAULT_REGION=garage \
  amazon/aws-cli:2.38.1 --endpoint-url http://garage:3900 s3api <op> --bucket sstate ...
```
- Path-style needs no config: with a hostname endpoint, aws-cli 2.38.1 addresses `http://garage:3900/sstate?lifecycle` and it works. `AWS_EC2_METADATA_DISABLED=true` avoided IMDS probing (not required).
- `s3api put-bucket-lifecycle-configuration --bucket sstate --lifecycle-configuration file:///w/lc.json` with
  `{"Rules":[{"ID":"expire-90d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":90}}]}` -> rc 0, empty stdout.
- `s3api get-bucket-lifecycle-configuration` returns (keys sorted by Garage, `ID` echoed):
  `{"Rules":[{"Expiration":{"Days":90},"ID":"expire-90d","Filter":{"Prefix":""},"Status":"Enabled"}]}`. Re-put of the same document is rc 0.
- Unset lifecycle: Get gives `NoSuchLifecycleConfiguration` rc 254 (aws-cli error exit), so the role must treat that error as "absent", not as failure. Denied calls: `AccessDenied ... Forbidden: Operation is not allowed for this key.` rc 254.
- `delete-bucket-lifecycle` rc 0, silent; works when nothing is configured (idempotent). `bucket info` does not display lifecycle.
- Entrypoint of the aws-cli image is `/usr/local/bin/aws`; image User is empty (root). Garage returns HTTP 403 for denied calls.
- Object round trip used for the checks: ci key (read+write) `put-object --bucket sstate --key selftest/up --body ...` rc 0.

## GS-A-26 / GS-FR-84 images

- `garage_s3_client_image`: newest stable tag on Docker Hub at the spike date is `2.38.1` (pushed 2026-10-14; `latest` points to the same push). Pin
  `docker.io/amazon/aws-cli:2.38.1` (run and tested, arch arm64 here; the repo also publishes amd64). Digest not recorded.
- Garage image built-in user: `docker run --rm docker.io/dxflrs/garage:v2.4.1 id` fails (`exec: "id": executable file not found`);
  `docker image inspect --format '{{.Config.User}}'` is empty, i.e. the image runs as root (uid 0) by default; Entrypoint is empty and Cmd is `[/garage server]`.
  A `user:` setting in the compose service is therefore needed for GS-FR-84's non-root intent.

## Not verified (needs the VM or T-03)

- Non-root `user:` with `0400` secrets and bind-mounted dirs (GS-A-03 second half, GS-FR-84 behaviour).
- Layout capacity as a pure placement weight (GS-A-09), real `block list-errors` under load.
- Caddy routing of the S3 and web hosts and bare-Host mapping through Caddy (GS-A-15/16, T-03).
- Whether `[s3_web] root_domain = ""` is functionally acceptable (parses only).
- Behaviour of lifecycle Expiration actually deleting objects after 90 days (Garage executes lifecycle workers daily; not waited for).
