#!/bin/bash
# nekosync - one-way sync of a local directory to a Nekoweb site.
# Creates new files, edits changed files, skips unchanged files.
# Never deletes anything remotely, even if a local file is missing.
set -euo pipefail

usage() {
  echo "Usage: NEKOWEB_API_KEY=... $0 <site-domain> <local-dir>" >&2
  echo "  site-domain: e.g. yoursite.nekoweb.org (no scheme, no trailing slash)" >&2
  echo "  local-dir:   directory whose contents mirror the site root" >&2
  exit 1
}

[ $# -eq 2 ] || usage
: "${NEKOWEB_API_KEY:?NEKOWEB_API_KEY env var must be set}"

SITE_DOMAIN="$1"
LOCAL_DIR="${2%/}"
API_BASE="https://nekoweb.org/api"

# Nekoweb's normal /files/create and /files/edit cap out at 100MB. Anything
# at or above that has to go through the big-upload flow (create session ->
# append chunks -> move). Chunk size is kept comfortably under the 100MB
# per-chunk limit.
BIG_THRESHOLD=$((100 * 1024 * 1024))
CHUNK_SIZE=$((90 * 1024 * 1024))

[ -d "$LOCAL_DIR" ] || { echo "no such directory: $LOCAL_DIR" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (used to parse the big-upload session id)" >&2; exit 1; }

hash_stdin() {
  sha256sum | cut -d' ' -f1
}

upload_big() {
  local f="$1" rel="$2"
  local id chunk_dir
  id=$(curl -s -H "Authorization: ${NEKOWEB_API_KEY}" "${API_BASE}/files/big/create" | jq -r .id)
  [ -n "$id" ] && [ "$id" != "null" ] || { echo "warn:   $rel (failed to start big upload session)" >&2; return; }

  chunk_dir=$(mktemp -d)
  split -b "$CHUNK_SIZE" -d -a 4 "$f" "${chunk_dir}/chunk_"

  for chunk in "${chunk_dir}"/chunk_*; do
    curl -s -H "Authorization: ${NEKOWEB_API_KEY}" \
      -F "id=${id}" \
      -F "file=@${chunk}" \
      "${API_BASE}/files/big/append" > /dev/null
  done
  rm -rf "$chunk_dir"

  curl -s -H "Authorization: ${NEKOWEB_API_KEY}" \
    --data-urlencode "id=${id}" \
    --data-urlencode "pathname=/${rel}" \
    "${API_BASE}/files/big/move" > /dev/null
}

sync_file() {
  local f="$1"
  local rel="${f#$LOCAL_DIR/}"
  local remote_url="https://${SITE_DOMAIN}/${rel}"
  local local_hash filesize
  local_hash=$(hash_stdin < "$f")
  filesize=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")

  local http_code body_file
  body_file=$(mktemp)
  http_code=$(curl -s -o "$body_file" -w '%{http_code}' "$remote_url") || http_code="000"

  if [ "$http_code" = "404" ]; then
    if [ "$filesize" -ge "$BIG_THRESHOLD" ]; then
      echo "create (big): $rel"
      upload_big "$f" "$rel"
    else
      echo "create: $rel"
      curl -s -H "Authorization: ${NEKOWEB_API_KEY}" \
        -F "pathname=/${rel}" \
        -F "content=@${f}" \
        "${API_BASE}/files/create" > /dev/null
    fi
  elif [ "$http_code" = "200" ]; then
    local remote_hash
    remote_hash=$(hash_stdin < "$body_file")
    if [ "$local_hash" = "$remote_hash" ]; then
      echo "skip:   $rel"
    elif [ "$filesize" -ge "$BIG_THRESHOLD" ]; then
      echo "edit (big):   $rel"
      upload_big "$f" "$rel"
    else
      echo "edit:   $rel"
      curl -s -H "Authorization: ${NEKOWEB_API_KEY}" \
        -F "pathname=/${rel}" \
        -F "content=@${f}" \
        "${API_BASE}/files/edit" > /dev/null
    fi
  else
    echo "warn:   $rel (unexpected HTTP $http_code, skipping)" >&2
  fi

  rm -f "$body_file"
}

find "$LOCAL_DIR" -type f | while IFS= read -r f; do
  sync_file "$f"
done
