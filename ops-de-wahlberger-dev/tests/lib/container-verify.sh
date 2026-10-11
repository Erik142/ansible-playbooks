#!/bin/sh
# Runs INSIDE the disposable openSUSE Tumbleweed container (see ../render-check.sh).
# Input (mounted at /work, read-write):
#   /work/out/<dest>        rendered files
#   /work/manifest.tsv      one "<kind><TAB><dest>" line per file; kind is
#                           systemd-unit | python-script | quadlet | text
# Exit 1 if any file fails; every failing file is named on stdout as "FAIL: <dest>".
set -eu

log() { printf '%s\n' "$*"; }
fail=0

# --- Setup: systemd-analyze ---------------------------------------------------
tab=$(printf '\t')
zypper -n -q install --no-recommends systemd python3 >/dev/null
command -v systemd-analyze >/dev/null
log "container: $(systemd-analyze --version | head -1)"

# --- Quadlets: generate the service units podman would generate ------------------
# A Quadlet (.container) is not a unit file; podman's generator turns it into a
# .service, and that service is what systemd-analyze can verify.
quadlets=$(grep "^quadlet${tab}" /work/manifest.tsv | cut -f2 || true)
: >/work/generated.tsv
if [ -n "$quadlets" ]; then
    zypper -n -q install --no-recommends podman >/dev/null
    quadlet_bin=/usr/libexec/podman/quadlet
    [ -x "$quadlet_bin" ] || { log "FAIL: podman quadlet generator not found"; exit 1; }
    rm -rf /work/quadlet-in /work/quadlet-out
    mkdir -p /work/quadlet-in /work/quadlet-out
    for q in $quadlets; do cp "/work/out/$q" "/work/quadlet-in/$q"; done
    if ! QUADLET_UNIT_DIRS=/work/quadlet-in "$quadlet_bin" /work/quadlet-out >/work/quadlet.log 2>&1; then
        log "FAIL: quadlet generator"; sed 's/^/    /' /work/quadlet.log; exit 1
    fi
    for q in $quadlets; do
        # Generator naming: foo.container -> foo.service, foo.network -> foo-network.service.
        case "$q" in
        *.network) svc="${q%.network}-network.service" ;;
        *) svc="${q%.*}.service" ;;
        esac
        if [ -s "/work/quadlet-out/$svc" ]; then
            cp "/work/quadlet-out/$svc" "/work/out/$svc"
            printf 'systemd-unit\t%s\n' "$svc" >>/work/generated.tsv
            log "ok: quadlet generated $svc from $q"
        else
            log "FAIL: $q (quadlet produced no $svc)"; sed 's/^/    /' /work/quadlet.log; fail=1
        fi
    done
fi

# --- Unit verification prep: stub what rendered units reference ---------------
unit_dir=/work/units
rm -rf "$unit_dir"
mkdir -p "$unit_dir"
units=$(cat /work/manifest.tsv /work/generated.tsv | grep "^systemd-unit${tab}" | cut -f2)
for u in $units; do cp "/work/out/$u" "$unit_dir/$u"; done

# Referenced units that are not rendered here (e.g. notify-failure-immediate@,
# db-dump.service) become empty stub units, so verify checks the file under
# test and not the rest of the host. Instance names collapse to the template.
for u in $units; do
    sed -nE 's/^(Requires|Wants|After|Before|OnFailure|BindsTo|PartOf|Upholds|Conflicts)=//p' "/work/out/$u" |
        tr ' ' '\n' | sed -E 's/%[a-zA-Z]//g; s/@[^.]+\./@./' |
        grep -E '^[A-Za-z0-9:_.@-]+\.(service|timer|target|socket|path)$' || true
done | sort -u | while read -r ref; do
    [ -e "$unit_dir/$ref" ] || [ -e "/usr/lib/systemd/system/$ref" ] || printf '[Service]\nExecStart=/bin/true\n' >"$unit_dir/$ref"
done

# Missing Exec* binaries (e.g. /usr/local/bin/notify-failure.sh) get no-op stubs.
for u in $units; do
    sed -nE 's/^Exec[A-Za-z]*=[-@:+!]*([^ ]+).*/\1/p' "/work/out/$u" | grep '^/' || true
done | sort -u | while read -r bin; do
    [ -e "$bin" ] || { mkdir -p "$(dirname "$bin")"; printf '#!/bin/sh\n' >"$bin"; chmod 0755 "$bin"; }
done

# --- Per-file checks -----------------------------------------------------------
cat /work/manifest.tsv /work/generated.tsv >/work/all.tsv
while IFS="$(printf '\t')" read -r kind dest; do
    [ -n "$kind" ] || continue
    case "$kind" in
    systemd-unit)
        if out=$(SYSTEMD_UNIT_PATH="$unit_dir:" systemd-analyze verify "$unit_dir/$dest" 2>&1); then
            if [ -n "$out" ]; then log "FAIL: $dest (systemd-analyze verify warnings)"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1
            else log "ok: systemd-analyze verify $dest"; fi
        else
            log "FAIL: $dest (systemd-analyze verify)"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1
        fi ;;
    python-script)
        # compile() only: py_compile would write a __pycache__ into /work/out.
        if out=$(python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "/work/out/$dest" 2>&1); then
            log "ok: python compile $dest"
        else
            log "FAIL: $dest (python compile)"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1
        fi ;;
    quadlet) : ;; # verified above through its generated service
    text) log "ok: text $dest (rendered)" ;;
    *) log "FAIL: $dest (unknown kind '$kind')"; fail=1 ;;
    esac
done </work/all.tsv

exit "$fail"
