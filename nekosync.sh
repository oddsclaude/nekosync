#!/bin/bash
# nekosync - one-way sync of a local directory to a Nekoweb site.
# Creates new files, edits changed files, skips unchanged files.
# Never deletes anything remotely, even if a local file is missing.
set -uo pipefail

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

# How many times to retry a transient (network-level, non-HTTP) failure
# before giving up on that one request. 429s are retried indefinitely since
# they're expected backpressure, not an error.
MAX_TRANSIENT_RETRIES=5

FAILURES=0

[ -d "$LOCAL_DIR" ] || { echo "no such directory: $LOCAL_DIR" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (used to parse the big-upload session id and to URL-encode paths)" >&2; exit 1; }

hash_stdin() {
  sha256sum | cut -d' ' -f1
}

# Percent-encodes a "/"-separated relative path segment by segment, leaving
# the slashes themselves alone. Needed because filenames can contain spaces,
# #, ?, unicode, etc. that would otherwise corrupt the live-fetch URL.
url_encode_path() {
  local path="$1"
  local IFS='/'
  local -a parts
  read -ra parts <<< "$path"
  local out="" seg first=1
  for seg in "${parts[@]}"; do
    [ "$first" -eq 1 ] || out+="/"
    first=0
    out+="$(jq -rn --arg s "$seg" '$s|@uri')"
  done
  echo "$out"
}

# Authenticated call to the Nekoweb API with rate-limit + transient-failure
# handling. On a 429, reads the ratelimit-reset header (either an epoch
# timestamp or a seconds-until-reset value) and sleeps until the limit
# clears, then retries indefinitely. On a curl-level failure (no HTTP
# response at all), retries a bounded number of times with a short backoff.
# Sets LAST_HTTP_CODE and LAST_BODY_FILE (caller must rm LAST_BODY_FILE).
# Returns non-zero if the call never got back a successful response.
api_call() {
  local method="$1" url="$2"
  shift 2
  local headers_file body_file transient_tries=0

  while true; do
    headers_file=$(mktemp)
    body_file=$(mktemp)

    LAST_HTTP_CODE=$(curl -s -D "$headers_file" -o "$body_file" -w '%{http_code}' \
      -X "$method" -H "Authorization: ${NEKOWEB_API_KEY}" "$@" "$url") || LAST_HTTP_CODE="000"

    if [ "$LAST_HTTP_CODE" = "000" ]; then
      transient_tries=$((transient_tries + 1))
      rm -f "$headers_file" "$body_file"
      if [ "$transient_tries" -ge "$MAX_TRANSIENT_RETRIES" ]; then
        echo "error:  ${url} unreachable after ${MAX_TRANSIENT_RETRIES} attempts, giving up" >&2
        return 1
      fi
      echo "warn:   ${url} unreachable, retrying (${transient_tries}/${MAX_TRANSIENT_RETRIES})..." >&2
      sleep 3
      continue
    fi

    if [ "$LAST_HTTP_CODE" = "429" ]; then
      local reset now wait
      reset=$(awk -F':' 'BEGIN{IGNORECASE=1} $1=="ratelimit-reset"{sub(/^[ \t]+/,"",$2); print $2}' "$headers_file" | tr -d '\r\n')
      now=$(date +%s)
      if [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -gt "$now" ]; then
        wait=$((reset - now))
      elif [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -gt 0 ]; then
        wait="$reset"
      else
        wait=5
      fi
      echo "rate limited (${url}), waiting ${wait}s for the bucket to reset..." >&2
      rm -f "$headers_file" "$body_file"
      sleep "$wait"
      continue
    fi

    break
  done

  rm -f "$headers_file"
  LAST_BODY_FILE="$body_file"

  case "$LAST_HTTP_CODE" in
    2??) return 0 ;;
    *)
      echo "error:  ${url} returned HTTP ${LAST_HTTP_CODE}: $(cat "$LAST_BODY_FILE" 2>/dev/null | head -c 300)" >&2
      return 1
      ;;
  esac
}

upload_big() {
  local f="$1" rel="$2"
  local id chunk_dir ok=1

  if ! api_call GET "${API_BASE}/files/big/create"; then
    rm -f "$LAST_BODY_FILE"
    return 1
  fi
  id=$(jq -r .id < "$LAST_BODY_FILE")
  rm -f "$LAST_BODY_FILE"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    echo "error:  $rel (big upload session had no id)" >&2
    return 1
  fi

  chunk_dir=$(mktemp -d)
  split -b "$CHUNK_SIZE" -d -a 4 "$f" "${chunk_dir}/chunk_"

  for chunk in "${chunk_dir}"/chunk_*; do
    if ! api_call POST "${API_BASE}/files/big/append" -F "id=${id}" -F "file=@${chunk}"; then
      ok=0
    fi
    rm -f "$LAST_BODY_FILE"
    [ "$ok" -eq 1 ] || break
  done
  rm -rf "$chunk_dir"

  if [ "$ok" -eq 0 ]; then
    echo "error:  $rel (a chunk failed to upload, not finalizing)" >&2
    return 1
  fi

  if ! api_call POST "${API_BASE}/files/big/move" \
    --data-urlencode "id=${id}" \
    --data-urlencode "pathname=/${rel}"; then
    rm -f "$LAST_BODY_FILE"
    return 1
  fi
  rm -f "$LAST_BODY_FILE"
  return 0
}

sync_file() {
  local f="$1"
  local rel="${f#$LOCAL_DIR/}"
  local encoded_rel remote_url
  encoded_rel=$(url_encode_path "$rel")
  remote_url="https://${SITE_DOMAIN}/${encoded_rel}"

  local local_hash filesize
  local_hash=$(hash_stdin < "$f")
  filesize=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")

  # This is a plain fetch of the live site, not an authenticated API call,
  # so it isn't subject to the /files/* rate-limit buckets.
  local http_code body_file
  body_file=$(mktemp)
  http_code=$(curl -s -o "$body_file" -w '%{http_code}' "$remote_url") || http_code="000"

  local result=0
  if [ "$http_code" = "404" ]; then
    if [ "$filesize" -ge "$BIG_THRESHOLD" ]; then
      echo "create (big): $rel"
      upload_big "$f" "$rel" || result=1
    else
      echo "create: $rel"
      api_call POST "${API_BASE}/files/create" -F "pathname=/${rel}" -F "content=@${f}" || result=1
      rm -f "${LAST_BODY_FILE:-}"
    fi
  elif [ "$http_code" = "200" ]; then
    local remote_hash
    remote_hash=$(hash_stdin < "$body_file")
    if [ "$local_hash" = "$remote_hash" ]; then
      echo "skip:   $rel"
    elif [ "$filesize" -ge "$BIG_THRESHOLD" ]; then
      echo "edit (big):   $rel"
      upload_big "$f" "$rel" || result=1
    else
      echo "edit:   $rel"
      api_call POST "${API_BASE}/files/edit" -F "pathname=/${rel}" -F "content=@${f}" || result=1
      rm -f "${LAST_BODY_FILE:-}"
    fi
  else
    echo "warn:   $rel (unexpected HTTP $http_code fetching live copy, skipping)" >&2
    result=1
  fi

  rm -f "$body_file"
  [ "$result" -eq 0 ] || FAILURES=$((FAILURES + 1))
}

# Read null-delimited to be robust against filenames with newlines/spaces.
while IFS= read -r -d '' f; do
  sync_file "$f"
done < <(find "$LOCAL_DIR" -type f -print0)

if [ "$FAILURES" -gt 0 ]; then
  echo "done with ${FAILURES} failure(s), see errors above" >&2
  exit 1
fi
echo "sync complete, no failures"
