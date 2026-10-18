# Spike T-03: Caddy O-6 route fragment against a real Garage

Date 2026-10-17. Confidence: **verified** locally (Docker Desktop, arm64) on a throwaway docker
network, throwaway temp dirs and a throwaway key. Images: `dxflrs/garage:v2.4.1` (single node,
sqlite, replication_factor 1), `caddy:2` (reports v2.11.7; upstream image, not
`localhost/caddy-cloudflare:2`), `amazon/aws-cli` (signing), `curlimages/curl`.
Caddyfile = O-6 with `http://:8080` as site address plus `auto_https off` / `admin off`; body byte-for-byte
the O-6 body. Not verified: the real `caddy-cloudflare` image and the VM (T-17 repeats the key rows).

## Result

**The O-6 body ships unchanged.** All GS-AC-52 rows, GS-AC-30, GS-AC-31, GS-AC-10 (K both forms),
GS-A-16 (a) to (f) and GS-A-23 pass.

**One spec amendment is needed, in the Garage config, not in the Caddy fragment (GS-A-01 / GS-FR-38 /
GS-AC-38):** Garage v2.4.1 refuses to start without `[s3_web] root_domain`:

```
Error: TOML decode error: TOML parse error at line 11, column 1
11 | [s3_web]
missing field `root_domain`
```

With `root_domain = "s3.de.int.wahlberger.dev"` (no leading dot, the A-01 fallback) a bare `Host: sstate`
still maps to bucket `sstate` (GS-A-15 passes: it is resolved as a global alias because it does not end in
the root domain). Flag GS-FR-38 / GS-AC-38 for amendment by `requirements-engineer`: template must render
`root_domain = "{{ garage_s3_domain }}"` in `[s3_web]`.

## Setup (commands, secrets omitted)

```
docker network create t03net
docker run -d --name garage --network t03net --network-alias garage -v garage.toml:/etc/garage.toml -v meta:/meta -v data:/data dxflrs/garage:v2.4.1
garage layout assign -z dc1 -c 1G <node>; garage layout apply --version 1
garage bucket create sstate; garage bucket create private-test
garage key create ci-upload
garage bucket allow --read --write --owner {sstate,private-test} --key ci-upload
garage bucket website --allow sstate          # private-test stays website=false
docker run -d --name caddy-route-test --network t03net -v Caddyfile:/etc/caddy/Caddyfile:ro caddy:2
```
Objects (put through the API route with aws-cli, path-style, `AWS_DEFAULT_REGION=garage`,
`--endpoint-url http://caddy-route-test:8080`): `sstate/selftest/up` (S=d69a93b5...),
K = `ab/cd/sstate:pn-foo:x86_64:1.0+git-r0:0123abcd_populate_sysroot.tar.zst` (R=5f17bd83...),
`private-test/obj`. Unsigned rows: `curl -s -g -o /tmp/o -w '%{http_code}' http://caddy-route-test:8080/<path>`.

## GS-AC-52 (all 11 rows)

| # | request | observed | pass |
|---|---|---|---|
| 1 | unsigned GET /sstate/selftest/up | 200, sha256 = S | yes |
| 2 | unsigned HEAD /sstate/selftest/up | 200, Content-Length 12 (= Z) | yes |
| 3 | unsigned GET /sstate/selftest/missing | 404 | yes |
| 4 | unsigned GET /nope/x | 404 | yes |
| 5 | unsigned GET /private-test/obj | 404 | yes |
| 6 | signed GET /sstate?list-type=2 | 200, list contains `selftest/up` (aws-cli `list-objects-v2`) | yes |
| 7 | signed PUT /sstate/selftest/route | 200 (ETag returned) | yes |
| 8 | signed PUT /sstate/K | 200 | yes |
| 9 | signed GET /sstate/K | 200, sha256 = R | yes |
| 10 | presigned GET /private-test/obj (`aws s3 presign`) | 200, body `priv` | yes |
| 11 | unsigned GET / | 403 AccessDenied (API route) | yes (non-2xx) |

## GS-AC-30 and GS-AC-31

- Unsigned `PUT /sstate/selftest/up`: 403; `POST`: 400 (`Invalid endpoint`); `DELETE`: 403. After: sha256 still S. Pass.
- `GET /sstate/`: 404 NoSuchKey, no `selftest/` in body. `GET /sstate`: 404, no `selftest/` in body. Pass
  (`/sstate` is also 404, which satisfies "non-2xx"; GS-A-16 (f) pass).

## GS-AC-10 / GS-A-23 (key K)

- Unsigned `GET /sstate/K` with literal `:` `+`: 200, sha256 R. With `%3A` `%2B`: 200, sha256 R.
- Signed PUT and GET of K through the API route (aws-cli, which signs the percent-encoded form): 200 each;
  presigned GET of K: 200.
- Upstream view (python echo upstreams behind the same Caddyfile): the **API route passes the request
  path byte-identical in both forms** (literal stays literal, `%3A` stays `%3A`), so SigV4 stays valid.
  The **web route decodes** `%3A`/`%2B` to `:`/`+` in the rewritten path (Garage resolves it either way).
  Caveat for later: a key containing an encoded `%2F` or `%25` would be decoded on the web route only;
  sstate keys contain neither.
- Client artifact (not a Caddy issue): `curl --aws-sigv4` with literal `:`/`+` in the path gets 403 from
  Garage directly as well (`garage:3900`), because curl does not canonical-encode them. Use aws-cli/botocore.

## GS-A-16 (a) to (f), GS-A-15

- (a) pass: unsigned GET goes to garage:3902 (web) and never also to 3900; with `Authorization` the request goes to the API route only (echo upstreams: each request hit exactly one upstream).
- (b) pass: the web upstream saw the path with the bucket segment removed (`/selftest/up`, `/ab/cd/...`) and `Host: sstate`, i.e. `rewrite` ran before `reverse_proxy`.
- (c) pass: any `Authorization` header (even `x`) takes the API route (Garage answers 400 for the malformed header, no web content).
- (d) pass: `?X-Amz-Signature=junk` and empty `?X-Amz-Signature=` take the API route (403 from Garage); presigned requests work (row 10). Other query params (`?list-type=2`) stay on the web route (404, no listing).
- (e) pass: `{re.bucket.1}`/`{re.bucket.2}` still hold the captures after `rewrite` (Host = bucket, path = remainder).
- (f) pass: `GET /<bucket>` and `GET /<bucket>/` both rewrite to `/` (upstream saw `GET /`, Host sstate); Garage answers 404 (no index.html); 
  no 2xx.
- GS-A-15: pass, but only with `root_domain` set (see Result).
- Side observation: `GET /sstate//selftest/up` returns 200 (double slash tolerated); harmless, read-only.

## Cleanup

All containers and `t03net` removed; the throwaway key file was deleted. `git status` shows only this note as new from T-03.
