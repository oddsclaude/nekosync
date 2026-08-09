# nekosync

One-way sync from a local directory to a [Nekoweb](https://nekoweb.org) site.

- New local files -> `POST /files/create`
- Changed local files -> `POST /files/edit`
- Unchanged local files -> skipped
- Files that exist remotely but not locally -> left alone, **never deleted**

Nekoweb's `readfolder` endpoint only returns filenames, no hashes or
timestamps, so this script determines "changed" by fetching the live file
straight from your site domain and comparing its sha256 against the local
copy. A 404 on the live fetch means the file doesn't exist yet (create); a
200 with a differing hash means it needs updating (edit); a matching hash
means skip.

## Usage

```sh
export NEKOWEB_API_KEY=your_api_key_here
./nekosync.sh yoursite.nekoweb.org ./path/to/site
```

- `site-domain` — your Nekoweb domain, no scheme, no trailing slash.
- `local-dir` — local directory whose contents mirror the site root.

## Why no delete

This is deliberately a strict subset of the Nekoweb API: `create` and `edit`
only. It's meant to be safe to run against a local checkout that doesn't
include every file the live site has (drafts kept elsewhere, generated
assets, whatever) without wiping anything out. If you want deletions synced
too, do that manually through the Nekoweb dashboard or the raw API.

## Big files

Nekoweb's normal `/files/create` and `/files/edit` cap out at 100MB. Files at
or above that size automatically go through the big-upload flow instead
(`/files/big/create` -> `/files/big/append` in ~90MB chunks ->
`/files/big/move`), no extra flags needed.

## Excluding a folder

Any directory named exactly `.___nekosync___not_synced___`, at any depth in
your local dir, is skipped entirely and recursively - nothing under it gets
hashed, checked, created, or edited. Useful for keeping drafts or
work-in-progress files alongside your site source without them going live.

## Rate limits

Every authenticated call reads the `ratelimit-remaining`/`ratelimit-reset`
response headers. On a `429`, the script sleeps until the bucket resets
(general, big_uploads, and zip buckets are limited separately per Nekoweb's
docs) and then retries automatically, so a big directory sync just pauses
and continues instead of dying partway through.

## Error handling

Every create/edit/big-upload call checks its HTTP status. A non-2xx response
is logged and counted as a failure instead of being silently treated as
success; the script keeps going and syncs the rest of the files, then exits
`1` at the end if anything failed (exits `0` if everything succeeded), so
it's safe to use as a CI/deploy gate. Network-level failures (no response at
all) get a bounded number of retries with backoff before being counted as a
failure; 429s are retried indefinitely since that's expected backpressure,
not an error.

Filenames are percent-encoded before being used in the live-fetch URL, so
filenames with spaces or other special characters don't break the
change-detection check.

## Requirements

- `bash`, `curl`, `sha256sum` (all standard on Linux/most *nix)
- `jq` (used to parse the big-upload session id and to URL-encode paths)
