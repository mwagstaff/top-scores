# Stadium image review workflow

This collector finds Wikimedia Commons stadium photography, asks GPT-5.6 to identify the strongest app-ready images, and downloads the suitable results for human review. Nothing reaches `sky` until it has been reviewed and promoted.

## 1. One-time setup

```bash
cd /Users/mwagstaff/dev/top-scores/tools/stadium-images
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
bw login
```

The collector checks `OPENAI_API_KEY`, then the macOS Keychain, then the `Value` custom field of the Bitwarden item `OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR`. The first successful Bitwarden lookup is saved in the Keychain under the service `dev.skynolimit.top-scores.image-collector`, so later runs do not prompt for the Bitwarden password. The key is never written to a repository file.

Use `--refresh-api-key` on either collection command to ignore and replace the Keychain value from Bitwarden.

To avoid Bitwarden prompts across separate collector commands, export the key once in the current terminal session. A Python process cannot export a variable back into its parent shell:

```bash
export BW_SESSION="$(bw unlock --raw)"
export OPENAI_API_KEY="$(bw get item OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR | python3 -c 'import json, sys; item = json.load(sys.stdin); print(next(field["value"] for field in item.get("fields", []) if field.get("name", "").casefold() == "value"))')"
unset BW_SESSION
```

After that, `find_images.py` and `collect_all.py` reuse the in-memory environment value without invoking either the Keychain or Bitwarden. Closing the terminal discards the environment value, but the Keychain cache remains available.

The scripts automatically use this `.venv`, so both `python collector/find_images.py ...` and `./collector/find_images.py ...` work after setup.

## 2. Collect images

The easiest option is the saved interactive launcher. Run it and choose Premier League, Championship, major teams, or everything:

```bash
./collector/collect_images.zsh
```

The same launcher also accepts a scope directly, plus any normal collector options:

```bash
./collector/collect_images.zsh premier-league
./collector/collect_images.zsh championship
./collector/collect_images.zsh major
./collector/collect_images.zsh all
./collector/collect_images.zsh all --dry-run
```

`major` uses the current Club Elo threshold from `api/top_teams_config.json`, exactly like the app's **Major teams** view. `all` combines all Premier League and Championship clubs with the qualifying major teams, then removes duplicate stadiums.

Collection runs five stadium pipelines concurrently by default. OpenAI analyses can therefore run five at a time. Wikimedia traffic is controlled independently: at most two requests are in flight, request starts are at least 0.25 seconds apart, and temporary `429`/server failures are retried with backoff. Candidate thumbnails are downloaded through that limiter and sent to OpenAI as resized data rather than as Wikimedia URLs.

Change the OpenAI/pipeline concurrency without increasing Wikimedia traffic:

```bash
./collector/collect_images.zsh all --workers 3
./collector/collect_images.zsh all --workers 8
```

The Wikimedia defaults should normally be left alone. For an especially sensitive or faster connection, they can be adjusted separately:

```bash
./collector/collect_images.zsh championship --wikimedia-concurrency 1 --wikimedia-min-interval 0.5
./collector/collect_images.zsh championship --wikimedia-concurrency 3 --wikimedia-min-interval 0.2
```

The league configurations provide curated club-aware searches—such as `Emirates Stadium Arsenal`—while the saved manifest retains the canonical stadium name (`Emirates Stadium`). The collector stops with an explicit list if a newly qualifying major club has no configured stadium mapping.

Existing stadium staging directories are skipped, making interrupted runs resumable. Use `--replace` only when you intentionally want to discard and recreate existing staged results.

To collect one stadium instead:

```bash
./collector/find_images.py "Anfield" --club Liverpool --slug anfield
./collector/find_images.py "Emirates Stadium" --club Arsenal --slug emirates-stadium
```

Suitable originals and a provenance manifest are written under `collector/staging/<stadium>/`.

## 3. Review

Open each directory under `collector/staging/` and inspect the images. Delete every unsuitable, incorrectly identified, repetitive, or unwanted image. Leave `manifest.json` in place; it carries the source, licence, score, lighting, and team assignment metadata.

## 4. Promote the reviewed set

```bash
./collector/promote_reviewed.py
```

The promotion script copies only image files that still exist into `collector/deployment/`, generates their deployment assignments and credits, and rebuilds the content-addressed `published/` bundle. Both working directories are intentionally gitignored.

## 5. Deploy

```bash
/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh top-scores sky
```

The normal API deployment validates and atomically activates the new catalog in the persistent artwork directory on `sky`. Released app versions discover it on launch or foreground refresh; no new app release is required.
