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

[ -d "$LOCAL_DIR" ] || { echo "no such directory: $LOCAL_DIR" >&2; exit 1; }

hash_stdin() {
  sha256sum | cut -d' ' -f1
}

sync_file() {
  local f="$1"
  local rel="${f#$LOCAL_DIR/}"
  local remote_url="https://${SITE_DOMAIN}/${rel}"
  local local_hash
  local_hash=$(hash_stdin < "$f")

  local http_code body_file
  body_file=$(mktemp)
  http_code=$(curl -s -o "$body_file" -w '%{http_code}' "$remote_url") || http_code="000"

  if [ "$http_code" = "404" ]; then
    echo "create: $rel"
    curl -s -H "Authorization: ${NEKOWEB_API_KEY}" \
      -F "pathname=/${rel}" \
      -F "content=@${f}" \
      "${API_BASE}/files/create" > /dev/null
  elif [ "$http_code" = "200" ]; then
    local remote_hash
    remote_hash=$(hash_stdin < "$body_file")
    if [ "$local_hash" = "$remote_hash" ]; then
      echo "skip:   $rel"
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
