#!/usr/bin/env bash
# BD-AC-89..92 (btrbk key refresh). VM only; run on the stack state. The unit's
# ExecStart is overridden through a runtime drop-in (the role's variable wiring is
# checked statically by BD-AC-88); everything else is the deployed unit and script.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
U=btrbk-key-refresh.service
gs 'systemctl stop fakekeysrv 2>/dev/null; systemctl reset-failed fakekeysrv 2>/dev/null; rm -rf /srv/fakekey; mkdir -p /usr/local/sbin /srv/fakekey'
vm_ssh 'sudo tee /usr/local/sbin/serve-key.py >/dev/null' < "$SCEN_DIR/serve-key.py"
# throwaway key + cert
gs 'cd /srv/fakekey && export GNUPGHOME=$(mktemp -d) && gpg --batch --passphrase "" --quick-gen-key "Fake Fixture Key <fake@example.invalid>" default default 1y >/dev/null 2>&1 && gpg --armor --export > key.asc && gpg --with-colons --fingerprint | awk -F: "/^fpr/{print \$10; exit}" > fp.txt
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 2>/dev/null
cp c.pem /etc/pki/trust/anchors/fixture-keyserver.pem && update-ca-certificates >/dev/null 2>&1
systemd-run --unit=fakekeysrv --quiet python3 /usr/local/sbin/serve-key.py; sleep 2; curl -s -o /dev/null -w "%{http_code}\n" https://127.0.0.1:8443/key.asc'
ORIG=$(gs "systemctl cat $U | grep '^ExecStart='")
dropin() { # dropin <new url> [warn-days]
  local new=$ORIG
  new=$(sed -E "s#--url '?[^ ]+'? #--url '$1' #" <<<"$new")
  [[ -n ${2:-} ]] && new=$(sed -E "s#--warn-days [0-9]+#--warn-days $2#" <<<"$new")
  gs "mkdir -p /run/systemd/system/$U.d; printf '[Service]\nExecStart=\n%s\n' \"$new\" > /run/systemd/system/$U.d/test.conf; systemctl daemon-reload"
}
run() { gs "systemctl start $U" >/dev/null 2>&1; gs "systemctl show -p Result -p ExecMainStatus $U | tr '\n' ' '"; }
keys() { gs 'rpm -qa gpg-pubkey | sort | tr "\n" " "'; }
URL=$(sed -E "s#.*--url '?([^ ']+)'? .*#\1#" <<<"$ORIG")
echo "orig=$URL" >"$OUT/ac89.txt"

# --- BD-AC-89
T=$(now); st=$(run); sleep 3; al=$(alert_since $U "$T"); jl=$(gs "journalctl -u $U --since '$T' --no-pager -o cat")
echo "$jl" >>"$OUT/ac89.txt"
if grep -q 'Result=success' <<<"$st" && [[ $al == 0 ]] && grep -qi 'verified\|imported\|refresh' <<<"$jl" && grep -qiE '[0-9]+ days' <<<"$jl"; then record "BD-AC-89" PASS "$st; no alert; journal: $(grep -iE 'days' <<<"$jl" | head -1 | cut -c1-140)"
else record "BD-AC-89" FAIL "$st al=$al (see $OUT/ac89.txt)"; fi

# --- BD-AC-90
dropin https://127.0.0.1:8443/key.asc; K0=$(keys); T=$(now); st=$(run); sleep 3; al=$(alert_since $U "$T"); jl=$(gs "journalctl -u $U --since '$T' --no-pager -o cat"); K1=$(keys)
fpf=$(gs 'cat /srv/fakekey/fp.txt')
if grep -q 'ExecMainStatus=2' <<<"$st" && [[ $al -ge 1 && $K0 == "$K1" ]] && grep -q "$fpf" <<<"$jl" && grep -q 'B1FB53748720472205FA601998C97FE7324E6311' <<<"$jl"; then record "BD-AC-90" PASS "$st; alert ($al); journal names both fingerprints; gpg-pubkey set unchanged"
else record "BD-AC-90" FAIL "$st al=$al same=$([[ $K0 == $K1 ]] && echo y || echo n) fp_in_journal=$(grep -c "$fpf" <<<"$jl")"; fi

# --- BD-AC-91
dropin "$URL" 3650; T=$(now); st=$(run); sleep 3; al=$(alert_since $U "$T"); jl=$(gs "journalctl -u $U --since '$T' --no-pager -o cat")
if grep -q 'ExecMainStatus=1' <<<"$st" && [[ $al -ge 1 ]] && grep -qiE '[0-9]+ days' <<<"$jl" && grep -qi 'import' <<<"$jl" && grep -qi 'refresh' <<<"$jl"; then record "BD-AC-91" PASS "$st; alert ($al); journal: $(grep -iE 'days' <<<"$jl" | head -1 | cut -c1-140)"
else record "BD-AC-91" FAIL "$st al=$al ($(tr '\n' '|' <<<"$jl" | cut -c1-300))"; fi

# --- BD-AC-92
dropin https://127.0.0.1:1/key.asc; T=$(now); st=$(run); sleep 3; jl=$(gs "journalctl -u $U --since '$T' --no-pager -o cat")
if grep -q 'ExecMainStatus=3' <<<"$st" && grep -q 'https://127.0.0.1:1/key.asc' <<<"$jl"; then record "BD-AC-92" PASS "$st; journal names the URL"; else record "BD-AC-92" FAIL "$st"; fi
gs "rm -rf /run/systemd/system/$U.d; systemctl daemon-reload; systemctl stop fakekeysrv; rm -f /etc/pki/trust/anchors/fixture-keyserver.pem; update-ca-certificates >/dev/null 2>&1; true"
