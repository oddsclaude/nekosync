#!/bin/bash
# nekosync - sync a local directory with a Nekoweb site.
#   push: creates new files, edits changed files, skips unchanged files.
#         never deletes anything remotely, even if a local file is missing.
#   pull: downloads the entire live site into a local directory, to start
#         editing locally.
set -uo pipefail

usage() {
  echo "Usage: NEKOWEB_API_KEY=... $0 <push|pull> <site-domain|auto> <local-dir>" >&2
  echo "  push|pull:   push local changes up, or pull the live site down" >&2
  echo "  site-domain: e.g. yoursite.nekoweb.org (no scheme, no trailing slash)," >&2
  echo "               or 'auto' to detect it via /site/info_all" >&2
  echo "  local-dir:   directory whose contents mirror the site root" >&2
  exit 1
}

[ $# -eq 3 ] || usage
: "${NEKOWEB_API_KEY:?NEKOWEB_API_KEY env var must be set}"

MODE="$1"
SITE_DOMAIN="$2"
LOCAL_DIR="${3%/}"
API_BASE="https://nekoweb.org/api"

case "$MODE" in
  push|pull) ;;
  *) usage ;;
esac

# Nekoweb's normal /files/create and /files/edit cap out at 100MB. Anything
# at or above that has to go through the big-upload flow (create session ->
# append chunks -> move). Chunk size is kept comfortably under the 100MB
# per-chunk limit. Only relevant to push.
BIG_THRESHOLD=$((100 * 1024 * 1024))
CHUNK_SIZE=$((90 * 1024 * 1024))

# How many times to retry a transient (network-level, non-HTTP) failure
# before giving up on that one request. 429s are retried indefinitely since
# they're expected backpressure, not an error.
MAX_TRANSIENT_RETRIES=5

# Any directory (at any depth) with this exact name is skipped entirely,
# recursively - nothing under it is ever synced, checked, created, edited,
# or (on pull) downloaded.
EXCLUDE_DIR_NAME=".___nekosync___not_synced___"

FAILURES=0

# Some accounts' file API is rooted above the actual site content - a
# GET /files/readfolder?pathname=/ returns a folder literally named after
# the site domain, and *that* folder's contents are what's actually served
# publicly. Detected once at startup and prepended to every API pathname
# below; the public live-fetch/download URLs never include this prefix.
ROOT_PREFIX=""

if [ "$MODE" = "push" ]; then
  [ -d "$LOCAL_DIR" ] || { echo "no such directory: $LOCAL_DIR" >&2; exit 1; }
else
  mkdir -p "$LOCAL_DIR"
fi
command -v jq >/dev/null || { echo "jq is required (used to parse API responses and to URL-encode paths)" >&2; exit 1; }

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

# Checks whether GET /files/readfolder?pathname=/ contains a directory
# entry named exactly $SITE_DOMAIN, and if so sets ROOT_PREFIX to it. Run
# once before push or pull touches any real files.
detect_root_prefix() {
  if ! api_call GET "${API_BASE}/files/readfolder" -G --data-urlencode "pathname=/"; then
    rm -f "${LAST_BODY_FILE:-}"
    echo "warn:   could not list account root to check for a site-domain wrapper folder, assuming none" >&2
    return
  fi
  if jq -e --arg d "$SITE_DOMAIN" '.[] | select(.dir == true and .name == $d)' "$LAST_BODY_FILE" > /dev/null 2>&1; then
    ROOT_PREFIX="/${SITE_DOMAIN}"
    echo "note:   account root has a /${SITE_DOMAIN} folder, treating that as the actual site root" >&2
  fi
  rm -f "$LAST_BODY_FILE"
}

# Resolves SITE_DOMAIN via GET /site/info_all when the domain arg is "auto".
# Uses the single site if the account only has one, otherwise the one
# flagged "main"; if neither applies, fails and lists the available domains
# so the caller can pass one explicitly instead of "auto".
detect_site_domain() {
  if ! api_call GET "${API_BASE}/site/info_all"; then
    rm -f "${LAST_BODY_FILE:-}"
    echo "error:  could not auto-detect site domain via /site/info_all" >&2
    exit 1
  fi

  local count main_domain
  count=$(jq 'length' "$LAST_BODY_FILE")

  if [ "$count" -eq 1 ]; then
    SITE_DOMAIN=$(jq -r '.[0].domain' "$LAST_BODY_FILE")
  else
    main_domain=$(jq -r '[.[] | select(.main == true)][0].domain // empty' "$LAST_BODY_FILE")
    if [ -n "$main_domain" ]; then
      SITE_DOMAIN="$main_domain"
    else
      echo "error:  account has multiple sites and none is marked main - pass the domain explicitly instead of 'auto'. available:" >&2
      jq -r '.[].domain' "$LAST_BODY_FILE" | sed 's/^/  /' >&2
      rm -f "$LAST_BODY_FILE"
      exit 1
    fi
  fi

  rm -f "$LAST_BODY_FILE"
  echo "note:   auto-detected site domain: ${SITE_DOMAIN}" >&2
}

# ---- push ----

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
    --data-urlencode "pathname=${ROOT_PREFIX}/${rel}"; then
    rm -f "$LAST_BODY_FILE"
    return 1
  fi
  rm -f "$LAST_BODY_FILE"
  return 0
}

# Creates a brand-new remote file and populates it. /files/create only
# stakes out the path (it needs isFolder and doesn't accept a body), so the
# actual content always has to go through a follow-up /files/edit.
create_and_fill() {
  local f="$1" rel="$2"

  if ! api_call POST "${API_BASE}/files/create" -F "isFolder=false" -F "pathname=${ROOT_PREFIX}/${rel}"; then
    rm -f "${LAST_BODY_FILE:-}"
    return 1
  fi
  rm -f "$LAST_BODY_FILE"

  api_call POST "${API_BASE}/files/edit" -F "pathname=${ROOT_PREFIX}/${rel}" -F "content=<${f}" || { rm -f "${LAST_BODY_FILE:-}"; return 1; }
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
  # so it isn't subject to the /files/* rate-limit buckets. -L follows
  # redirects since Nekoweb 302s .html requests to their extensionless
  # pretty-URL form (e.g. whyipirate.html -> /whyipirate).
  local http_code body_file
  body_file=$(mktemp)
  http_code=$(curl -sL -o "$body_file" -w '%{http_code}' "$remote_url") || http_code="000"

  local result=0
  if [ "$http_code" = "404" ]; then
    if [ "$filesize" -ge "$BIG_THRESHOLD" ]; then
      echo "create (big): $rel"
      upload_big "$f" "$rel" || result=1
    else
      echo "create: $rel"
      create_and_fill "$f" "$rel" || result=1
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
      api_call POST "${API_BASE}/files/edit" -F "pathname=${ROOT_PREFIX}/${rel}" -F "content=<${f}" || result=1
      rm -f "${LAST_BODY_FILE:-}"
    fi
  else
    echo "warn:   $rel (unexpected HTTP $http_code fetching live copy, skipping)" >&2
    result=1
  fi

  rm -f "$body_file"
  [ "$result" -eq 0 ] || FAILURES=$((FAILURES + 1))
}

run_push() {
  # Read null-delimited to be robust against filenames with newlines/spaces.
  # -prune keeps find from ever descending into an excluded directory, so
  # nothing under it is touched, hashed, or fetched at all.
  while IFS= read -r -d '' f; do
    sync_file "$f"
  done < <(find "$LOCAL_DIR" -type d -name "$EXCLUDE_DIR_NAME" -prune -o -type f -print0)
}

# ---- pull ----

# Strips ROOT_PREFIX off an API-space path to get the path as it actually
# appears in public URLs (which never include the wrapper folder).
to_public_path() {
  local p="$1"
  if [ -n "$ROOT_PREFIX" ] && [ "${p#"$ROOT_PREFIX"}" != "$p" ]; then
    p="${p#"$ROOT_PREFIX"}"
    [ -n "$p" ] || p="/"
  fi
  echo "$p"
}

download_file() {
  local remote_path="$1" local_path="$2"
  local public_path encoded remote_url http_code

  public_path=$(to_public_path "$remote_path")
  encoded=$(url_encode_path "${public_path#/}")
  remote_url="https://${SITE_DOMAIN}/${encoded}"
  mkdir -p "$(dirname "$local_path")"

  # -L follows redirects since Nekoweb 302s .html requests to their
  # extensionless pretty-URL form (e.g. whyipirate.html -> /whyipirate).
  http_code=$(curl -sL -o "$local_path" -w '%{http_code}' "$remote_url") || http_code="000"
  if [ "$http_code" = "200" ]; then
    echo "pull:   ${public_path#/}"
  else
    echo "error:  ${public_path#/} (HTTP ${http_code} fetching live copy)" >&2
    rm -f "$local_path"
    FAILURES=$((FAILURES + 1))
  fi
}

pull_site() {
  local remote_pathname="$1" local_base="$2"

  if ! api_call GET "${API_BASE}/files/readfolder" -G --data-urlencode "pathname=${remote_pathname}"; then
    rm -f "${LAST_BODY_FILE:-}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  local entries="$LAST_BODY_FILE"

  local name is_dir
  while IFS=$'\t' read -r name is_dir; do
    [ -n "$name" ] || continue
    if [ "$is_dir" = "true" ] && [ "$name" = "$EXCLUDE_DIR_NAME" ]; then
      continue
    fi

    local child_remote="${remote_pathname%/}/${name}"
    local child_local="${local_base}/${name}"

    if [ "$is_dir" = "true" ]; then
      mkdir -p "$child_local"
      pull_site "$child_remote" "$child_local"
    else
      download_file "$child_remote" "$child_local"
    fi
  done < <(jq -r '.[] | [.name, (.dir|tostring)] | @tsv' "$entries")

  rm -f "$entries"
}

run_pull() {
  pull_site "${ROOT_PREFIX:-/}" "$LOCAL_DIR"
}

[ "$SITE_DOMAIN" = "auto" ] && detect_site_domain
detect_root_prefix

if [ "$MODE" = "push" ]; then
  run_push
else
  run_pull
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "done with ${FAILURES} failure(s), see errors above" >&2
  exit 1
fi
echo "${MODE} complete, no failures"
