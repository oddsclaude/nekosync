# nekosync

Sync a local directory with a [Nekoweb](https://nekoweb.org) site.

- `push` — New local files -> `POST /files/create`. Changed local files ->
  `POST /files/edit`. Unchanged local files -> skipped. Files that exist
  remotely but not locally -> left alone, **never deleted**.
- `pull` — downloads the entire live site into a local directory
  recursively, to start editing locally.

Nekoweb's `readfolder` endpoint only returns filenames, no hashes or
timestamps, so `push` determines "changed" by fetching the live file
straight from your site domain and comparing its sha256 against the local
copy. A 404 on the live fetch means the file doesn't exist yet (create); a
200 with a differing hash means it needs updating (edit); a matching hash
means skip.

## Usage

```sh
export NEKOWEB_API_KEY=your_api_key_here

# push local changes up
./nekosync.sh push yoursite.nekoweb.org ./path/to/site

# pull the whole live site down into a local dir (creates it if missing)
./nekosync.sh pull yoursite.nekoweb.org ./path/to/site

# or let it figure out the domain for you
./nekosync.sh pull auto ./path/to/site
```

- `site-domain` — your Nekoweb domain, no scheme, no trailing slash, or the
  literal word `auto` to look it up via `/site/info_all`. Auto-detection
  uses your only site if you have just one, or the one flagged `main` if you
  have several; with multiple sites and no `main`, it fails and lists your
  domains so you can pass one explicitly.
- `local-dir` — local directory whose contents mirror the site root.

### A note on multi-site accounts

Some accounts' file API is rooted one level above the actual site content:
`GET /files/readfolder?pathname=/` returns a folder literally named after
your site's domain, and that folder's contents are what's actually served
publicly. nekosync detects this automatically at startup (by checking for a
folder matching your site domain at the account root) and adjusts every
internal API path accordingly - the public URLs it fetches for
change-detection and downloads are never affected, only the internal
`pathname` sent to `create`/`edit`/`big/move`/`readfolder`.

## Why no delete

`push` is deliberately a strict subset of the Nekoweb API: `create` and
`edit` only. It's meant to be safe to run against a local checkout that
doesn't include every file the live site has (drafts kept elsewhere,
generated assets, whatever) without wiping anything out. If you want
deletions synced too, do that manually through the Nekoweb dashboard or the
raw API.

## Big files

Nekoweb's normal `/files/create` and `/files/edit` cap out at 100MB. On
`push`, files at or above that size automatically go through the big-upload
flow instead (`/files/big/create` -> `/files/big/append` in ~90MB chunks ->
`/files/big/move`), no extra flags needed.

## Excluding a folder

Any directory named exactly `.___nekosync___not_synced___`, at any depth in
your local dir, is skipped entirely and recursively on `push` - nothing
under it gets hashed, checked, created, or edited. On `pull`, a remote
folder with that exact name is likewise skipped rather than downloaded.
Useful for keeping drafts or work-in-progress files alongside your site
source without them going live (or being clobbered by a pull).

## Rate limits

Every authenticated call reads the `ratelimit-remaining`/`ratelimit-reset`
response headers. On a `429`, the script sleeps until the bucket resets
(general, big_uploads, and zip buckets are limited separately per Nekoweb's
docs) and then retries automatically, so a big sync just pauses and
continues instead of dying partway through.

## Error handling

Every API call checks its HTTP status. A non-2xx response is logged and
counted as a failure instead of being silently treated as success; the
script keeps going and processes the rest of the files, then exits `1` at
the end if anything failed (exits `0` if everything succeeded), so it's safe
to use as a CI/deploy gate. Network-level failures (no response at all) get
a bounded number of retries with backoff before being counted as a failure;
429s are retried indefinitely since that's expected backpressure, not an
error.

Filenames are percent-encoded before being used in any live-fetch URL, so
filenames with spaces or other special characters don't break things.

## Requirements

- `bash`, `curl`, `sha256sum` (all standard on Linux/most *nix)
- `jq` (used to parse API responses and to URL-encode paths)
