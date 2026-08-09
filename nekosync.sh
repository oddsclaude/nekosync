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

# Authenticated call to the Nekoweb API with rate-limit handling.
# On a 429, reads the ratelimit-reset header (either an epoch timestamp or a
# seconds-until-reset value depending on how far the bucket has been used)
# and sleeps until the limit clears, then retries the same request.
# Sets LAST_HTTP_CODE and LAST_BODY_FILE (caller is responsible for removing
# LAST_BODY_FILE when done with it).
api_call() {
  local method="$1" url="$2"
  shift 2
  local headers_file body_file
  headers_file=$(mktemp)
  body_file=$(mktemp)

  while true; do
    LAST_HTTP_CODE=$(curl -s -D "$headers_file" -o "$body_file" -w '%{http_code}' \
      -X "$method" -H "Authorization: ${NEKOWEB_API_KEY}" "$@" "$url")

    if [ "$LAST_HTTP_CODE" = "429" ]; then
      local reset now wait
      reset=$(awk -F': ' 'tolower($1)=="ratelimit-reset"{print $2}' "$headers_file" | tr -d '\r\n')
      now=$(date +%s)
      if [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -gt "$now" ]; then
        wait=$((reset - now))
      elif [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -gt 0 ]; then
        wait="$reset"
      else
        wait=5
      fi
      echo "rate limited (${url}), waiting ${wait}s for the bucket to reset..." >&2
      sleep "$wait"
      continue
    fi
    break
  done

  rm -f "$headers_file"
  LAST_BODY_FILE="$body_file"
}

upload_big() {
  local f="$1" rel="$2"
  local id chunk_dir

  api_call GET "${API_BASE}/files/big/create"
  id=$(jq -r .id < "$LAST_BODY_FILE")
  rm -f "$LAST_BODY_FILE"
  [ -n "$id" ] && [ "$id" != "null" ] || { echo "warn:   $rel (failed to start big upload session)" >&2; return; }

  chunk_dir=$(mktemp -d)
  split -b "$CHUNK_SIZE" -d -a 4 "$f" "${chunk_dir}/chunk_"

  for chunk in "${chunk_dir}"/chunk_*; do
    api_call POST "${API_BASE}/files/big/append" -F "id=${id}" -F "file=@${chunk}"
    rm -f "$LAST_BODY_FILE"
  done
  rm -rf "$chunk_dir"

  api_call POST "${API_BASE}/files/big/move" \
    --data-urlencode "id=${id}" \
    --data-urlencode "pathname=/${rel}"
  rm -f "$LAST_BODY_FILE"
}

sync_file() {
  local f="$1"
  local rel="${f#$LOCAL_DIR/}"
  local remote_url="https://${SITE_DOMAIN}/${rel}"
  local local_hash filesize
  local_hash=$(hash_stdin < "$f")
  filesize=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")

  # This is a plain fetch of the live site, not an authenticated API call,
  # so it isn't subject to the /files/* rate-limit buckets.
  local http_code body_file
  body_file=$(mktemp)
  http_code=$(curl -s -o "$body_file" -w '%{http_code}' "$remote_url") || http_code="000"

  if [ "$http_code" = "404" ]; then
    if [ "$filesize" -ge "$BIG_THRESHOLD" ]; then
      echo "create (big): $rel"
      upload_big "$f" "$rel"
    else
      echo "create: $rel"
      api_call POST "${API_BASE}/files/create" -F "pathname=/${rel}" -F "content=@${f}"
      rm -f "$LAST_BODY_FILE"
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
      api_call POST "${API_BASE}/files/edit" -F "pathname=/${rel}" -F "content=@${f}"
      rm -f "$LAST_BODY_FILE"
    fi
  else
    echo "warn:   $rel (unexpected HTTP $http_code, skipping)" >&2
  fi

  rm -f "$body_file"
}

find "$LOCAL_DIR" -type f | while IFS= read -r f; do
  sync_file "$f"
done
