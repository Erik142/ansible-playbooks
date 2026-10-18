# Garage V2 results (T-17)

Run on the qemu fixture (`reset.sh clean`, then `tests/vm/scenarios/garage-v2-run.sh`), 2026-10-18.
Spec v1.3. Route test Caddy: `docker.io/library/caddy:2` with `http://:8080 { <garage_s3_caddy_body from production vars> }` on `caddy.network`.

| Scenario | Result | Evidence |
|---|---|---|
| GS-AC-22/role-run | PASS | role run on a fresh host rc=0 changed=16 |
| GS-AC-70/static | PASS | no bucket, key or grant in inventories/vm or role variables |
| GS-AC-70/cli | PASS | bucket list has sstate+private-test; sstate website access; test-rw read+write on both |
| GS-AC-07/role | PASS | garage status shows a role |
| GS-AC-07/put | PASS | signed 1 MiB PUT selftest/up from caddy.network -> 200 |
| GS-AC-07/head | PASS | signed HEAD: content-length: 1048576 (expected 1048576) |
| GS-AC-07/get | PASS | signed GET 200 sha equals uploaded |
| GS-AC-10/web-up | PASS | Host: sstate :3902 -> 200 |
| GS-AC-10/web-K | PASS | Host: sstate :3902 /K -> 200 |
| GS-AC-10/web-missing | PASS | -> 404 |
| GS-AC-10/caddy-K-literal | PASS | unsigned GET /sstate/K (literal : +) -> 200 |
| GS-AC-10/caddy-K-encoded | PASS | unsigned GET /sstate/K (%3A %2B) -> 200 |
| GS-AC-10/lan-H | SKIPPED | [H] needs a LAN host and the real certificate |
| GS-AC-30/PUT | PASS | unsigned PUT -> 403 |
| GS-AC-30/POST | PASS | unsigned POST -> 400 |
| GS-AC-30/DELETE | PASS | unsigned DELETE -> 403 |
| GS-AC-30/intact | PASS | selftest/up sha unchanged -> 200 d2647014a332e5181506f89c5865e8d5e604a7d4c9fe092cb0f78fe81152c1fd |
| GS-AC-31 | PASS | GET /sstate/ -> 404, GET /sstate -> 404, bodies without selftest/ |
| GS-AC-52/1 | PASS | GET up -> 200 |
| GS-AC-52/2 | PASS | HEAD up -> HTTP/1.1 200 OK, Content-Length: 1048576 |
| GS-AC-52/3 | PASS | -> 404 |
| GS-AC-52/4 | PASS | -> 404 |
| GS-AC-52/5 | PASS | -> 404 |
| GS-AC-52/6 | PASS | signed list (API route): ListBucketResult + selftest/up |
| GS-AC-52/7 | PASS | signed PUT selftest/route rc=0 |
| GS-AC-52/8 | PASS | signed PUT K rc=0 |
| GS-AC-52/9 | PASS | signed GET K rc=0 sha=ffbe07f8729e6b9a |
| GS-AC-52/10 | PASS | presigned GET private-test/obj -> 200 |
| GS-AC-52/11 | PASS | unsigned GET / -> 403 |
| GS-AC-58/1 | PASS | rc=2, names a.example.test, Caddyfile hash unchanged |
| GS-AC-58/2 | PASS | rc=2, names a.example.test, Caddyfile hash unchanged |
| GS-AC-58/3 | PASS | rc=2, names a.example.test, Caddyfile hash unchanged |
| GS-AC-73/changed | PASS | second role run rc=0 changed=0 |
| GS-AC-73/layout | PASS | output identical before/after the role run |
| GS-AC-73/sstate | PASS | output identical before/after the role run |
| GS-AC-73/private-test | PASS | output identical before/after the role run |
| GS-AC-73/key | PASS | output identical before/after the role run |
| GS-AC-73/lifecycle | PASS | output identical before/after the role run |
| GS-AC-73/rule-present | PASS | lifecycle rule and quota still the user's |

Notes:
- Fixture fix (committed): `inventories/vm/group_vars/all/vars.yml` still had `garage_s3_domain: s3.example.test`, which GS-FR-135 refuses (spec 1.3, GS-FR-65 says `s3.de.int.wahlberger.dev`). The role now runs without `-e garage_s3_domain=...`.
- Deviation: the route test Caddy uses the official `caddy:2` image, not `caddy_image` (`localhost/caddy-cloudflare:2`, built from xcaddy and not present on the VM); the fragment uses only core directives.
- GS-AC-58: the caddy role is not deployed on the VM (needs the Cloudflare token and the xcaddy image build), so the script plants a marker Caddyfile at `/mnt/containers/caddy/Caddyfile`, runs the real role with each invalid entry, and compares its hash before/after; marker removed afterwards.
- GS-AC-73: `garage key info test-rw` lists the key's buckets in varying order between two calls even with no role run in between (seen in the first V2 run: private-test and sstate rows swapped). The key output is compared as a set of lines; the other four outputs byte for byte. Spec wording "identical" should say "same content, any row order" (report to requirements-engineer).
- GS-AC-07 re-uploads `selftest/up` (new random 1 MiB) and updates `/var/tmp/garage-test-setup.sha256`; V3 reads S from that file or re-hashes.
- The role README is still a stub (T-21): the "README steps" are exercised through `garage-test-setup.sh`, which T-21 must diff against the README.
- Not run: GS-AC-10 [H] (LAN host, real certificate). User state (layout, buckets, keys, quota on private-test, lifecycle rule on sstate) is left on the VM for T-18/T-19; do not reset.
