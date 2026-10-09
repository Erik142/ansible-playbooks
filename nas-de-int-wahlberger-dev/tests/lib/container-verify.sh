#!/bin/sh
# Runs INSIDE the disposable openSUSE Tumbleweed container (see ../render-check.sh).
# Input (mounted at /work, read-write):
#   /work/out/<dest>        rendered files
#   /work/manifest.tsv      one "<kind><TAB><dest>" line per file; kind is
#                           btrbk-conf | systemd-unit | python-script | text
# Output: /work/out/<dest>.print holds `btrbk config print` for btrbk-conf files.
# Exit 1 if any file fails; every failing file is named on stdout as "FAIL: <dest>".
set -eu

# Pinned fingerprint of the OBS "filesystems" project signing key (expires
# 2027-05-07, BD-A-17). A key change makes this script fail loudly instead of
# silently trusting a new key.
OBS_REPO_URL="https://download.opensuse.org/repositories/filesystems/openSUSE_Tumbleweed"
OBS_KEY_FPR="B1FB53748720472205FA601998C97FE7324E6311"

fail=0
log() { printf '%s\n' "$*"; }

# --- Setup: btrbk from OBS (first check of BD-A-01) and systemd-analyze -------
curl -fsS "${OBS_REPO_URL}/repodata/repomd.xml.key" -o /tmp/obs.key
actual_fpr=$(gpg --show-keys --with-colons --fingerprint /tmp/obs.key 2>/dev/null | grep -m1 '^fpr:' | cut -d: -f10)
if [ "$actual_fpr" != "$OBS_KEY_FPR" ]; then
    log "FAIL: OBS key fingerprint mismatch (expected ${OBS_KEY_FPR}, got ${actual_fpr:-none})"
    exit 1
fi
rpmkeys --import /tmp/obs.key
zypper -n -q ar -f "${OBS_REPO_URL}/filesystems.repo" >/dev/null
zypper -n -q install --no-recommends btrbk systemd python3 >/dev/null
command -v btrbk >/dev/null && command -v systemd-analyze >/dev/null
log "container: $(btrbk --version | head -1), $(systemd-analyze --version | head -1)"

# --- Unit verification prep: stub what rendered units reference ---------------
unit_dir=/work/units
rm -rf "$unit_dir"
mkdir -p "$unit_dir"
units=$(grep "^systemd-unit$(printf '\t')" /work/manifest.tsv | cut -f2)
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
while IFS="$(printf '\t')" read -r kind dest; do
    [ -n "$kind" ] || continue
    case "$kind" in
    btrbk-conf)
        if btrbk -c "/work/out/$dest" config print >"/work/out/$dest.print" 2>"/work/out/$dest.print.err"; then
            log "ok: btrbk config print $dest"
        else
            log "FAIL: $dest (btrbk config print)"; sed 's/^/    /' "/work/out/$dest.print.err"; fail=1
        fi ;;
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
    text) log "ok: text $dest (rendered)" ;;
    *) log "FAIL: $dest (unknown kind '$kind')"; fail=1 ;;
    esac
done </work/manifest.tsv

exit "$fail"
