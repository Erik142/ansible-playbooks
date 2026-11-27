#!/usr/bin/env bash
# Deployed by Ansible (roles/forgejo_runner). Runs as the forgejo-runner user from
# the user timer. Operates on that user's rootless Podman store only.
#
# Removes:
#   1. dangling layers older than PRUNE_UNTIL (as before);
#   2. tagged images that are not in use, not on the keep list, and whose image
#      was created more than PRUNE_MAX_AGE_DAYS ago.
# Kept: any image used by a container (running or stopped) and every image in
# PRUNE_KEEP_REFS. ci-podman-node is built on the host and cannot be re-pulled,
# so it must be on the keep list.
#
# Age is the image creation time, not the last use. Podman does not record last use.
set -euo pipefail

: "${PRUNE_MAX_AGE_DAYS:=14}"
: "${PRUNE_UNTIL:=168h}"
: "${PRUNE_KEEP_REFS:=}"
: "${PRUNE_DRY_RUN:=0}"
PODMAN="${PODMAN:-podman}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
run() {
  if [ "$PRUNE_DRY_RUN" = 1 ]; then
    log "dry-run: $*"
  else
    "$@"
  fi
}

# 1. Dangling layers.
run "$PODMAN" image prune --force --filter "until=${PRUNE_UNTIL}"

# 2. Build the set of images to keep, keyed by the first 12 hex chars of the ID.
declare -A keep=()

ps_ids=$("$PODMAN" ps -a --format '{{.ImageID}}')
while read -r id; do
  [ -n "$id" ] && keep["${id:0:12}"]=1
done <<< "$ps_ids"

for ref in $PRUNE_KEEP_REFS; do
  if id=$("$PODMAN" image inspect --format '{{.Id}}' "$ref" 2>/dev/null); then
    keep["${id:0:12}"]=1
  else
    log "keep ref not present locally: $ref"
  fi
done

# 3. Candidates. One line per image: "<id> <created-unix> <tag> [<tag>...]".
all_ids=$("$PODMAN" images --no-trunc -q)
[ -z "$all_ids" ] && { log "no images"; exit 0; }

# shellcheck disable=SC2086  # word-splitting of the ID list is intended
inspect=$("$PODMAN" image inspect \
  --format '{{.Id}} {{.Created.Unix}} {{range .RepoTags}}{{.}} {{end}}' $all_ids)

cutoff=$(( $(date +%s) - PRUNE_MAX_AGE_DAYS * 86400 ))

while read -r id created tags; do
  [ -z "$id" ] && continue
  if [ -z "${tags// /}" ]; then
    continue  # dangling: handled in step 1
  fi
  if [ -n "${keep[${id:0:12}]:-}" ]; then
    log "keep (in use or pinned): $tags"
    continue
  fi
  if [ "$created" -gt "$cutoff" ]; then
    continue
  fi
  log "remove unused image ${id:0:12} ($tags), created $(date -d "@$created" -I 2>/dev/null || echo "$created")"
  run "$PODMAN" rmi "$id" || log "rmi failed, left in place: ${id:0:12}"
done <<< "$inspect"

log "done"
