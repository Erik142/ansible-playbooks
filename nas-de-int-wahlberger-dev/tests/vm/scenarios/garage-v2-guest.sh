#!/usr/bin/env bash
# Guest half of VM run V2 (T-17). Runs as root in the VM; started by garage-v2-run.sh.
# Prints one line per check: "R <id> PASS|FAIL <evidence>". Never prints key secrets.
# Uses the route test Caddy (caddy-route-test) on garage.network (systemd-garage).
set -uo pipefail
N=systemd-garage
AWS_IMAGE=docker.io/amazon/aws-cli:2.38.1
CURL_IMAGE=docker.io/curlimages/curl:8.11.1
CADDY_IMAGE=docker.io/library/caddy:2
RT=http://caddy-route-test:8080
K='ab/cd/sstate:pn-foo:x86_64:1.0+git-r0:0123abcd_populate_sysroot.tar.zst'
KENC='ab/cd/sstate%3Apn-foo%3Ax86_64%3A1.0%2Bgit-r0%3A0123abcd_populate_sysroot.tar.zst'
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
G() { podman exec garage /garage "$@" 2>/dev/null; }
r() { printf 'R %s %s %s\n' "$1" "$2" "$3"; }
ok() { if eval "$3"; then r "$1" PASS "$2"; else r "$1" FAIL "$2"; fi; }

w=$(mktemp -d); trap 'rm -rf "$w"; podman rm -f caddy-route-test >/dev/null 2>&1' EXIT
info=$(G key info --show-secret test-rw)
akid=$(awk -F': *' '/^Key ID/{print $2; exit}' <<<"$info")
sec=$(awk -F': *' '/^Secret key/{print $2; exit}' <<<"$info")
cat >"$w/awsconfig" <<C
[default]
region = garage
s3 =
  addressing_style = path
  signature_version = s3v4
C
S=$(awk '$2=="up"{print $1}' /var/tmp/garage-test-setup.sha256)
R=$(awk '$2=="k"{print $1}' /var/tmp/garage-test-setup.sha256)
Z=1048576
aws() { podman run --rm --network $N -v "$w":/w:Z -e AWS_CONFIG_FILE=/w/awsconfig \
  -e AWS_ACCESS_KEY_ID="$akid" -e AWS_SECRET_ACCESS_KEY="$sec" -e AWS_EC2_METADATA_DISABLED=true \
  "$AWS_IMAGE" --endpoint-url "$EP" "$@"; }
cu() { podman run --rm --user root --network $N -v "$w":/w:Z "$CURL_IMAGE" "$@"; }
# scode <curl args> : status code only
scode() { cu -s -o /dev/null -w '%{http_code}' -m 20 "$@"; }
# gsha <curl args> : "<code> <sha256 of body>"
gsha() { local c; c=$(cu -s -o /w/body -w '%{http_code}' -m 20 "$@"); echo "$c $(sha256sum "$w/body" | cut -c1-64)"; }
signed() { cu -s -m 20 --user "$akid:$sec" --aws-sigv4 aws:amz:garage:s3 -H "x-amz-content-sha256: $EMPTY" "$@"; }

# ---- route test Caddy: Caddyfile = http://:8080 { <S3 host body from production vars> } ----
podman rm -f caddy-route-test >/dev/null 2>&1
podman run -d --name caddy-route-test --network $N -v /var/tmp/garage-v2-Caddyfile:/etc/caddy/Caddyfile:ro,Z "$CADDY_IMAGE" >/dev/null
for i in $(seq 1 20); do [ "$(scode $RT/nope/x)" != 000 ] && break; sleep 1; done

# ---- GS-AC-70 (guest part) ----
bl=$(G bucket list); bi=$(G bucket info sstate); ki=$(G key info test-rw)
ok GS-AC-70/cli "bucket list has sstate+private-test; sstate website access; test-rw read+write on both" \
  "grep -q sstate <<<\"\$bl\" && grep -q private-test <<<\"\$bl\" && grep -qi 'website access: *true' <<<\"\$bi\" && [ \$(grep -c '^RW' <<<\"\$ki\") -ge 2 ]"
echo "--- bucket info sstate (website lines): $(grep -i website <<<"$bi" | tr -s ' ' | tr '\n' '|')"
echo "--- key info test-rw: $(grep -E 'sstate|private-test' <<<"$ki" | tr -s ' ' | tr '\n' '|')"

# ---- store the user-made object in private-test (stand-in for the user; garage-test-setup.sh does not) ----
EP=http://garage:3900
head -c 2048 /dev/urandom >"$w/obj"
aws s3api put-object --bucket private-test --key obj --body /w/obj >/dev/null 2>&1; echo "--- put private-test/obj rc=$?"

# ---- GS-AC-07 ----
ok GS-AC-07/role "garage status shows a role" "! G status | grep -q 'NO ROLE ASSIGNED' && G status | grep -q dc1"
head -c $Z /dev/urandom >"$w/up"; S2=$(sha256sum "$w/up" | cut -c1-64)
c=$(cu -s -o /dev/null -w '%{http_code}' -m 60 --user "$akid:$sec" --aws-sigv4 aws:amz:garage:s3 -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" -T /w/up http://garage:3900/sstate/selftest/up)
ok GS-AC-07/put "signed 1 MiB PUT selftest/up from garage.network -> $c" "[ '$c' = 200 ]"
[ "$c" = 200 ] && { sed -i "s/^[0-9a-f]\{64\}  up\$/$S2  up/" /var/tmp/garage-test-setup.sha256; S=$S2; }
h=$(cu -sI -m 20 --user "$akid:$sec" --aws-sigv4 aws:amz:garage:s3 -H "x-amz-content-sha256: $EMPTY" http://garage:3900/sstate/selftest/up | tr -d '\r')
ok GS-AC-07/head "signed HEAD: $(grep -i '^content-length' <<<"$h") (expected $Z)" "grep -qi '^content-length: $Z' <<<\"\$h\""
g=$(cu -s -o /w/got -w '%{http_code}' -m 60 --user "$akid:$sec" --aws-sigv4 aws:amz:garage:s3 -H "x-amz-content-sha256: $EMPTY" http://garage:3900/sstate/selftest/up); gs=$(sha256sum "$w/got" | cut -c1-64)
ok GS-AC-07/get "signed GET $g sha equals uploaded" "[ '$g' = 200 -a '$gs' = '$S2' ]"

# ---- GS-AC-10 ----
x=$(gsha -H 'Host: sstate' http://garage:3902/selftest/up); ok GS-AC-10/web-up "Host: sstate :3902 -> ${x%% *}" "[ '$x' = '200 $S' ]"
x=$(gsha -H 'Host: sstate' "http://garage:3902/$K"); ok GS-AC-10/web-K "Host: sstate :3902 /K -> ${x%% *}" "[ '$x' = '200 $R' ]"
x=$(scode -H 'Host: sstate' http://garage:3902/selftest/missing); ok GS-AC-10/web-missing "-> $x" "[ '$x' = 404 ]"
x=$(gsha "$RT/sstate/$K"); ok GS-AC-10/caddy-K-literal "unsigned GET /sstate/K (literal : +) -> ${x%% *}" "[ '$x' = '200 $R' ]"
x=$(gsha "$RT/sstate/$KENC"); ok GS-AC-10/caddy-K-encoded "unsigned GET /sstate/K (%3A %2B) -> ${x%% *}" "[ '$x' = '200 $R' ]"
r GS-AC-10/lan-H SKIPPED "[H] needs a LAN host and the real certificate"

# ---- GS-AC-30 ----
for m in PUT POST DELETE; do
  c=$(scode -X $m -d x "$RT/sstate/selftest/up"); ok GS-AC-30/$m "unsigned $m -> $c" "[ '$c' -ge 300 -o '$c' -lt 200 ] && [ '$c' != 000 ]"
done
x=$(gsha -H 'Host: sstate' http://garage:3902/selftest/up); ok GS-AC-30/intact "selftest/up sha unchanged -> $x" "[ '$x' = '200 $S' ]"

# ---- GS-AC-31 ----
b=$(cu -s -m 20 -w '\n%{http_code}' "$RT/sstate/"); c1=${b##*$'\n'}; b1=${b%$'\n'*}
b=$(cu -s -m 20 -w '\n%{http_code}' "$RT/sstate"); c2=${b##*$'\n'}; b2=${b%$'\n'*}
ok GS-AC-31 "GET /sstate/ -> $c1, GET /sstate -> $c2, bodies without selftest/" \
  "[ '$c1' = 404 ] && [ '$c2' -ge 300 -o '$c2' -lt 200 ] && ! grep -q 'selftest/' <<<\"\$b1\$b2\""

# ---- GS-AC-52 ----
x=$(gsha "$RT/sstate/selftest/up"); ok GS-AC-52/1 "GET up -> ${x%% *}" "[ '$x' = '200 $S' ]"
h=$(cu -sI -m 20 "$RT/sstate/selftest/up" | tr -d '\r'); ok GS-AC-52/2 "HEAD up -> $(head -1 <<<"$h"), $(grep -i '^content-length' <<<"$h")" "head -1 <<<\"\$h\" | grep -q ' 200' && grep -qi '^content-length: $Z' <<<\"\$h\""
x=$(scode "$RT/sstate/selftest/missing"); ok GS-AC-52/3 "-> $x" "[ '$x' = 404 ]"
x=$(scode "$RT/nope/x"); ok GS-AC-52/4 "-> $x" "[ '$x' = 404 ]"
x=$(scode "$RT/private-test/obj"); ok GS-AC-52/5 "-> $x" "[ '$x' = 404 ]"
lst=$(signed "$RT/sstate?list-type=2"); ok GS-AC-52/6 "signed list (API route): ListBucketResult + selftest/up" "grep -q '<ListBucketResult' <<<\"\$lst\" && grep -q 'selftest/up' <<<\"\$lst\""
EP=$RT
head -c 512 /dev/urandom >"$w/route"
aws s3api put-object --bucket sstate --key selftest/route --body /w/route >/dev/null 2>"$w/err"; rc=$?; ok GS-AC-52/7 "signed PUT selftest/route rc=$rc $(head -c 150 "$w/err")" "[ $rc = 0 ]"
aws s3api get-object --bucket sstate --key "$K" /w/k0 >/dev/null 2>&1   # keep the existing K content (R)
aws s3api put-object --bucket sstate --key "$K" --body /w/k0 >/dev/null 2>"$w/err"; rc=$?; ok GS-AC-52/8 "signed PUT K rc=$rc $(head -c 150 "$w/err")" "[ $rc = 0 ]"
rm -f "$w/k1"; aws s3api get-object --bucket sstate --key "$K" /w/k1 >/dev/null 2>"$w/err"; rc=$?
ok GS-AC-52/9 "signed GET K rc=$rc sha=$(sha256sum "$w/k1" 2>/dev/null | cut -c1-16)" "[ $rc = 0 ] && [ \$(sha256sum '$w/k1' | cut -c1-64) = '$R' ]"
pu=$(aws s3 presign s3://private-test/obj --expires-in 300 2>/dev/null | tr -d '\r'); x=$(scode "$pu")
ok GS-AC-52/10 "presigned GET private-test/obj -> $x" "[ '$x' = 200 ] && grep -q X-Amz-Signature <<<\"\$pu\""
x=$(scode "$RT/"); ok GS-AC-52/11 "unsigned GET / -> $x" "[ '$x' -ge 300 -o '$x' -lt 200 ] && [ '$x' != 000 ]"
