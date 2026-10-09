#!/usr/bin/env bash
# README TODO markers + restore procedures DOC-O1/O2/O3 (also BD-AC-83's VM analogue). VM only; `stack` state.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
quiet_timers
gs 'zypper -n in --no-recommends rsync >/dev/null 2>&1; true'
# --- TODO 1: rsync with two remote operands
gs 'rsync -a pi:/mnt/data/restic-repos/cloud/ nas:/mnt/data/restic-repos/cloud/ 2>&1 | head -2' >"$OUT/rsync2.txt" 2>&1
if grep -qi 'cannot both be remote' "$OUT/rsync2.txt"; then record "README TODO rsync two remote operands" PASS "rsync refuses: $(head -1 "$OUT/rsync2.txt")"; else record "README TODO rsync two remote operands" FAIL "$(head -2 $OUT/rsync2.txt)"; fi

# --- DOC-O1 / BD-AC-83 analogue: restore one file from the newest received data snapshot
gs 'mkdir -p /mnt/data/samba; head -c 3000000 /dev/urandom > /mnt/data/samba/restore-me.bin; sync'
nextday; gs 'systemctl start btrbk.service'
newest=$(gs 'ls -1d /mnt/backup/btrbk/data/data.* | sort | tail -1')
gs "cp -a $newest/samba/restore-me.bin /tmp/r"
if [[ $(gs 'sha256sum < /tmp/r') == $(gs 'sha256sum < /mnt/data/samba/restore-me.bin') ]]; then record "DOC-O1 / BD-AC-83 (VM analogue)" PASS "cp -a from the received snapshot gives an identical file"; else record "DOC-O1 / BD-AC-83 (VM analogue)" FAIL "checksum differs"; fi

# --- DOC-O3 psql restore into an empty database; forgejo.db ownership
gs 'podman exec fixture-postgres psql -U fixture -d fixture -c "INSERT INTO t VALUES (42);" >/dev/null; systemctl start db-dump.service'
gs 'podman exec fixture-postgres createdb -U fixture restoretest; podman exec -i fixture-postgres psql -U fixture restoretest < /mnt/containers/db-dumps/fixture.sql >/dev/null 2>&1; echo rc=$?; podman exec fixture-postgres psql -U fixture restoretest -tAc "select count(*) from t where id=42"' >"$OUT/psql-restore.txt" 2>&1
if grep -q '^rc=0' "$OUT/psql-restore.txt" && [[ $(tail -1 "$OUT/psql-restore.txt") == 1 ]]; then record "README TODO psql authentication (DOC-O3)" PASS "psql -U <user> <db> inside the container needs no password (local socket trust) and the dump restores into an empty database (postgres:16 image; paperless/immich/tandoor images use the same entrypoint)"; else record "README TODO psql authentication (DOC-O3)" FAIL "$(cat $OUT/psql-restore.txt | head -3)"; fi
gs 'podman exec fixture-postgres dropdb -U fixture restoretest'
UIDG=$(gs 'stat -c "%u:%g" /mnt/containers/forgejo/volume/data 2>/dev/null || echo 0:0')
gs 'chown 1000:1000 /mnt/containers/forgejo/volume/data /mnt/containers/forgejo/volume/data/forgejo.db; chmod 750 /mnt/containers/forgejo/volume/data'   # production shape: owned by the container uid
gs 'cp -a /mnt/containers/db-dumps/forgejo.db /mnt/containers/forgejo/volume/data/forgejo.db'
own1=$(gs 'stat -c "%u:%g %a" /mnt/containers/forgejo/volume/data/forgejo.db'); r1=$(gs 'setpriv --reuid 1000 --regid 1000 --clear-groups sqlite3 /mnt/containers/forgejo/volume/data/forgejo.db "select count(*) from t" 2>&1 | head -1')
gs 'cp /mnt/containers/db-dumps/forgejo.db /mnt/containers/forgejo/volume/data/forgejo.db; chown --reference=/mnt/containers/forgejo/volume/data /mnt/containers/forgejo/volume/data/forgejo.db; chmod 600 /mnt/containers/forgejo/volume/data/forgejo.db'
own2=$(gs 'stat -c "%u:%g %a" /mnt/containers/forgejo/volume/data/forgejo.db'); r2=$(gs 'setpriv --reuid 1000 --regid 1000 --clear-groups sqlite3 /mnt/containers/forgejo/volume/data/forgejo.db "select count(*) from t" 2>&1 | head -1')
if [[ $own1 == "0:0 600" && $r1 != 1 && $own2 == "1000:1000 600" && $r2 == 1 ]]; then record "README TODO forgejo.db ownership (DOC-O3)" PASS "DEFECT CONFIRMED and fixed in README: 'cp -a' of the root:root 600 dump leaves $own1 and the container uid cannot read it ($r1); cp + chown --reference=<data dir> gives $own2 and uid 1000 reads it"; else record "README TODO forgejo.db ownership (DOC-O3)" FAIL "own1=$own1 r1=$r1 own2=$own2 r2=$r2"; fi

# --- DOC-O2: whole-source restore and the swap into place
SRC=$(gs 'ls -1d /mnt/backup/btrbk/data/data.* | sort | tail -1'); TS=$(basename "$SRC")
gs "systemctl stop restic-server.service restic-server-maintenance.timer; umount /mnt/data; mkdir -p /mnt/top; mount -o subvolid=5 UUID=00000000-0000-4000-8000-0000000000d1 /mnt/top
btrfs send $SRC | btrfs receive /mnt/top >/dev/null
mv /mnt/top/@data /mnt/top/@data.broken
btrfs subvolume snapshot /mnt/top/$TS /mnt/top/@data >/dev/null
umount /mnt/top; mount /mnt/data; systemctl start restic-server.service restic-server-maintenance.timer" >"$OUT/doc-o2.txt" 2>&1
sw=$(gs 'findmnt -no SOURCE,OPTIONS /mnt/data | cut -c1-160; sha256sum < /mnt/data/samba/restore-me.bin; test -w /mnt/data && touch /mnt/data/.w && rm /mnt/data/.w && echo writable; ls -d /mnt/data/.snapshots /mnt/data/.btrbk 2>&1 | tr "\n" " "; curl -s -o /dev/null -w "%{http_code}" -u cloud:fixture-restic-htpasswd-not-a-secret http://127.0.0.1:8000/cloud/config')
echo "$sw" >>"$OUT/doc-o2.txt"
if grep -q writable <<<"$sw" && grep -q 'subvol=/@data' <<<"$sw" && grep -q 200 <<<"$sw"; then record "README TODO DOC-O2 swap into place" PASS "send|receive onto the data filesystem top level, rename @data away, snapshot the received copy as @data, remount: writable, restic-server serves again. Learned: .snapshots/.btrbk are absent in the received copy (see README note)"; else record "README TODO DOC-O2 swap into place" FAIL "$sw (see $OUT/doc-o2.txt)"; fi
