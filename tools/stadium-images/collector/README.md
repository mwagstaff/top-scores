# Stadium image review workflow

This collector finds Wikimedia Commons club photography, asks GPT-5.6 to identify the strongest app-ready images, and downloads the suitable results for human review. Nothing reaches `sky` until it has been reviewed and promoted.

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

The easiest option is the saved interactive launcher. Run it and choose Premier League, the top five Championship clubs by Club Elo, major teams, or everything:

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

`major` uses the current Club Elo threshold from `api/top_teams_config.json`, exactly like the app's **Major teams** view. `all` combines all Premier League clubs, the five highest-rated configured Championship clubs, and qualifying major teams. Shared grounds have separate club galleries, so rival tifos and flags are not mixed. Pass `--championship-limit 24` to collect the full configured Championship. Ratings come from `api/club_elo_teams.json`; `--club-elo-data PATH` accepts a refreshed snapshot. Review the snapshot date before collection.

Collection runs five club pipelines concurrently by default. OpenAI analyses can therefore run five at a time. Wikimedia traffic is controlled independently: at most two requests are in flight, request starts are at least 0.25 seconds apart, and temporary `429`/server failures are retried with backoff. Candidate thumbnails are downloaded through that limiter and sent to OpenAI as resized data rather than as Wikimedia URLs.

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

Searches include match action, supporters, flags, banners, tifos and flares as well as stadium views. Lighting is mixed freely. Previously reviewed source URLs, including deleted/rejected images, are excluded using archived manifests. The league configurations provide additional curated club-aware searches—such as `Emirates Stadium Arsenal`—while the saved manifest retains the canonical stadium name (`Emirates Stadium`). The collector stops with an explicit list if a newly qualifying major club has no configured stadium mapping.

Existing team staging directories are skipped, making interrupted runs resumable. Use `--replace` only when you intentionally want to discard and recreate existing staged results.

To collect one stadium instead:

```bash
./collector/find_images.py "Anfield" --club Liverpool --slug anfield
./collector/find_images.py "Emirates Stadium" --club Arsenal --slug emirates-stadium
```

Suitable originals and a provenance manifest are written under `collector/staging/<team-name>-<bsd-team-id>/`.

## 3. Review

Open each directory under `collector/staging/` and inspect the images. Delete every unsuitable, incorrectly identified, repetitive, or unwanted image. Leave `manifest.json` in place; it carries the source, licence, score, and team assignment metadata.

## 4. Promote the reviewed set

```bash
./collector/promote_reviewed.py
```

The promotion script copies only image files that still exist into `collector/deployment/`, merges their assignments and credits with earlier approved batches, and rebuilds the content-addressed `published/` bundle. After successful publication it moves the reviewed staging batch into `collector/reviewed/<timestamp>/`, including manifests that record deleted/rejected candidates. Staging is then empty for new searches. All three working directories are gitignored. `--no-publish` preserves staging for inspection.

Images use the same team folders throughout the workflow, for example:

- `collector/staging/tottenham-hotspur-9/` — new images awaiting review.
- `collector/deployment/assets/tottenham-hotspur-9/` — editable approved originals.
- `published/assets/tottenham-hotspur-9/` — generated WebP images for deployment.
- `published/assets/generic/` — backgrounds without a team assignment.

The number is the BSD team ID, verified in `config/team-identities.json`. Add a verified identity there for a new club. Shared-stadium clubs have separate team folders. Archived review batches retain their original paths and provenance.

To migrate an older approved collection and rebuild its published bundle:

```bash
./collector/promote_reviewed.py --organize-existing
```

Edit the approved originals, then run `stadium-images publish`; generated files in `published/` are replaced on each publish. Replacing an original in place preserves its credit record and generates a new image hash. If using a different source photograph, update its credit metadata too.

To remove an already approved asset, remove its entry from `collector/deployment/publishing.yaml` and publish again. To replace an image, update its `file` path there; publishing generates a new content hash automatically. Server assets are uploaded before the catalogue is atomically activated. Source copies and review history stay local.

The iOS hero gallery uses home-team imagery, mixes all lighting contexts, and crossfades every 20 seconds. It displays locally cached photography first, prefetches the next image, and checks the catalogue at most every 15 minutes during use. Reduce Motion keeps a static image. Removed assets are purged after a successful catalogue refresh; the disk cache is bounded to 150 MB. Legacy lighting fields remain readable for catalogue compatibility but do not affect selection.

## 5. Deploy

```bash
/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh top-scores sky
```

The team-folder layout requires the updated `api/stadium_artwork.js` on the server once before an assets-only deployment. Public image URLs remain `/api/v1/stadium-artwork/assets/<sha256>.webp`, so existing iOS builds and cached images continue to work. The deployment script checks the deployed catalogue reader before activation. Older flat files on the server are retained for clients using an older cached catalogue.

The normal API deployment validates and atomically activates the new catalog in the persistent artwork directory on `sky`. Released app versions discover it on launch or foreground refresh; no new app release is required.

## Review photographs in the actual iOS heroes

Use a Debug iOS build and open **Profile → About → Stadium artwork → Teams and stadiums → a team**. Each image appears in a full-width match hero by default, with rotation paused. Use the Match/Team switch above the gallery to compare layouts. **View original** opens that image uncropped; **Adjust framing** opens the editor in the selected hero layout.

The review screen reuses the production match and team hero components, with sample match details explicitly labelled as sample content. Use Previous/Next to inspect every image with rotation paused. Switch between Match, Team and Original; toggle predictions and larger text to check obscured details and readability. Move the horizontal/vertical focal-point sliders to keep the flag, crowd or pitch visible. Crops stop at the image edges; an axis with no overflow cannot move further.

**Copy framing settings** copies the current image and all framing changes made during this review session. Merge those entries into the existing `focal_points` mapping in `tools/stadium-images/config/publishing.yaml`, then rebuild and publish the artwork. Preview adjustments are not saved to the server or retained when leaving the screen. Copy before leaving. A setting can also be supplied as `focal_point: {x: 0.4, y: 0.6}` on an individual asset; the central `focal_points` mapping takes precedence.

Coordinates refer to the original image, with `(0, 0)` at the top left and `(1, 1)` at the bottom right. Entries without a focal point use the centre. A focal-only change updates the catalogue version without changing the photo's hash or triggering another image download. The updated iOS build is required once to understand focal points and the revised hero presentation.

## Delete images from the Debug app

Deploy the updated API and rebuild the Debug iOS app. Set a dedicated, randomly generated `STADIUM_ARTWORK_ADMIN_TOKEN` in the server's environment and restart the API through the normal deployment process. Use `.env.local` when testing locally. Never put this key in the iOS build or commit it to the repository.

In **Profile → About → Stadium artwork → Image administration**, enter the same key and tap **Save admin key**. The key is saved in this device's Keychain for the selected API address. Each gallery image has a **Delete image** button and confirmation. The API requires HTTPS from the app, authenticates each request, and checks the image hash before deletion. A changed image must be refreshed before deleting. Requests without a configured server key cannot delete anything.

Deleting removes the photograph from every assignment, hides it from the catalogue, deletes its currently published files, and immediately updates the reviewing device's catalogue/cache. Other devices remove cached copies after their next successful catalogue refresh (normally within 15 minutes of active use); offline devices retain their last catalogue until they reconnect. Compiled fallback images in existing app builds are unaffected.

The server keeps an authoritative removal record **beside** the artwork root: `/home/mwagstaff/.local/share/top-scores/stadium-artwork.deletions.json`. Include this file in server backups. Do not remove or replace it when deploying artwork. Old bundles and reprocessed copies with the same image ID, published hash or source page stay excluded, even if their files are uploaded again. A corrupt removal record stops artwork serving rather than restoring deleted images.

The Mac cannot be changed directly by the remote API. The next `stadium-images publish` uses the configured passwordless SSH connection to `sky` to sync removals **before** generating a bundle. If sync fails, publishing stops and preserves the previous bundle. It removes matching approved publishing entries and staging/review manifests, and moves originals into `tools/stadium-images/collector/removed/`, preserving their previous relative directories. This quarantine is outside all publishing inputs. Bundled iOS originals are never moved. A local copy of the removal record is retained in `collector/server-deletions.json`; deleting a remote record alone does not restore an image.

Asset-only deployments using `--skip-asset-prepare` do not run local cleanup; the server removal record still prevents restored bytes being served. Run the normal publisher first to clean local folders and rebuild the bundle. Do not roll back to an API version without removal-record support after using deletion.

If the API process is killed in the middle of a deletion, a sibling `stadium-artwork.deletions.json.lock` directory may remain. After confirming no deletion is running, remove that empty directory and retry. The deletion record remains authoritative even if physical file cleanup was interrupted.
