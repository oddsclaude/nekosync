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

## Requirements

- `bash`, `curl`, `sha256sum` (all standard on Linux/most *nix)
