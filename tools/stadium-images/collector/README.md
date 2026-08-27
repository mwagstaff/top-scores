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

The collector uses `OPENAI_API_KEY` immediately when it is already present in the environment. Otherwise, it reads the key from the `Value` custom field of the Bitwarden item `OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR`. If the vault is locked, the script prompts for `bw unlock` and syncs the vault before reading the item; the key is never written to a repository file.

To avoid Bitwarden prompts across separate collector commands, export the key once in the current terminal session. A Python process cannot export a variable back into its parent shell:

```bash
export BW_SESSION="$(bw unlock --raw)"
export OPENAI_API_KEY="$(bw get item OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR | python3 -c 'import json, sys; item = json.load(sys.stdin); print(next(field["value"] for field in item.get("fields", []) if field.get("name", "").casefold() == "value"))')"
unset BW_SESSION
```

After that, `find_images.py` and `collect_all.py` reuse the in-memory environment value without invoking Bitwarden. Closing the terminal discards it.

The scripts automatically use this `.venv`, so both `python collector/find_images.py ...` and `./collector/find_images.py ...` work after setup.

## 2. Collect images

Collect every configured 2026/27 Premier League stadium plus every club at or above the same Club Elo threshold used by the app's **Major teams** list:

```bash
./collector/collect_all.py --dry-run
./collector/collect_all.py
```

The wrapper reads the threshold from `api/top_teams_config.json` and the matching scores from `api/club_elo_teams.json`. It stops with an explicit list if a newly qualifying major club has no configured stadium mapping.

Existing stadium staging directories are skipped, making interrupted runs resumable. Use `--replace` only when you intentionally want to discard and recreate existing staged results.

To collect one stadium instead:

```bash
./collector/find_images.py "Anfield" --club Liverpool
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
