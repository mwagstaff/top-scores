# Top Scores stadium image collector

This is a configuration-driven command-line tool for collecting reusable football-stadium photography with its provenance intact. The checked-in Premier League dataset is explicitly labelled for the 2026/27 season; another league or season can be added as a new YAML file without changing collection logic.

Wikimedia Commons, the curated Geograph football-ground collection, and
non-Wikimedia discovery through Openverse work without credentials. Unsplash and
Pexels are enabled only when their official API keys are present. Every retained image
has a known licence, source page, author field, hashes, classification evidence, and
quality-score evidence.

## Setup

From this directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[test]'
cp .env.example .env.local
```

Export any optional provider keys before collecting. `.env.local` is deliberately not read automatically or committed; source it in your shell if you use it.

```bash
set -a
source .env.local
set +a
```

Use a descriptive `STADIUM_IMAGES_USER_AGENT` value when making larger Wikimedia runs.
`WIKIMEDIA_DOWNLOAD_WIDTH` defaults to 2560 pixels, which uses Wikimedia's official
`w/thumb.php` high-resolution rendition service while retaining the canonical original URL in metadata.
This avoids repeatedly pulling exceptionally large originals and is still comfortably above
the app's largest anticipated hero-image size.

## Collect

Start with one stadium and Wikimedia:

```bash
stadium-images collect \
  --stadium "Emirates Stadium" \
  --sources wikimedia \
  --results-per-query 10
```

Collect the configured league from every available provider:

```bash
stadium-images collect --league premier-league
```

Missing Unsplash or Pexels keys produce warnings and do not prevent Wikimedia collection. Other useful examples:

```bash
stadium-images collect --stadium anfield --sources wikimedia,unsplash
stadium-images collect --league premier-league --min-score 8 --limit 20
stadium-images report --league premier-league
stadium-images classify --stadium anfield
stadium-images dedupe --league premier-league
stadium-images review-sheet --league premier-league --picks 3
stadium-images reject wikimedia_12345678 --reason "poor hero composition"
stadium-images migrate-output
stadium-images process --stadium anfield --width 1290 --height 600
stadium-images attributions
```

The default output is `output/`. Completed and rejected candidate state is stored in `output/.state.sqlite3`, so a repeated command resumes rather than downloading completed work again. Filter, query-limit, or retention changes generate a new state fingerprint so candidates can be reconsidered under the new settings.

## Output

Each league is organized by normalized team name, such as
`premier-league/newcastle-united/`. Every team directory contains immutable source
downloads under `original/`, ranked copies under `day/` and `night/`, plus
`metadata.json`. Twilight, dusk, sunset, and evening images are treated as night;
the classifier always resolves every retained image to one of those two categories.
`process` adds centre-cropped WebP files under `processed/` without changing the
original.

The output root contains:

- `manifest.json` for app/storage integration, grouped by league and stadium.
- `ATTRIBUTIONS.md` for human-readable credits.
- `attributions.json` for a future in-app image-credit screen.

Review the retained images before shipping them. V1 scoring and time-of-day classification are intentionally inexpensive metadata/luminance heuristics; they do not replace human identity, composition, or licence review.
`review-sheet` generates a labelled overview of each stadium's highest-ranked images under
`output/review/` for a fast visual pass.

## Publish artwork to the app

The checked-in `config/publishing.yaml` is the server artwork assignment file. Each asset points to an existing image, declares whether it is a generic screen backdrop, a generic match image, or a team image, and records its day/night context, team/venue assignments, and credit metadata. Team definitions can match the app by stable key, provider team ID, alias, or optional venue ID.

To replace an image or change its assignment, edit that YAML file and run:

```bash
stadium-images publish
```

Publishing converts the selected sources to bounded WebP files, names them by SHA-256 content hash, validates every assignment and credit, then atomically replaces the ignored `published/` bundle. It does not crop images or modify the source files.

The normal Top Scores API deployment runs this publish step automatically, uploads new content-addressed files to the persistent directory on `sky`, validates their hashes remotely, and activates the catalogue atomically:

```bash
/Users/mwagstaff/dev/server-tooling/deploy/node_project.zsh top-scores sky
```

Existing asset files are retained so clients with an older cached catalogue can finish downloads safely. The API serves the catalogue from `/api/v1/stadium-artwork/catalog`; the app checks it on launch and foreground activation at most once every 15 minutes. Bundled artwork remains the fallback when the catalogue or an image is unavailable. Published credits appear under Profile > About > Data sources > Image credits.

## Add a league or update a season

Copy `config/premier-league.yaml` to a new slug such as `config/championship.yaml`, then change:

- `league`, `name`, `season`, and `membership_source`.
- The stadium entries and aliases.
- Multiple stadium-specific search terms, including interior, pitch, daytime, and night variants.
- Filters and per-category retention if appropriate.

Run it with `stadium-images collect --league championship`. Club membership and sponsored stadium names must be reviewed at least once per season; aliases should preserve older venue names that remain common in Wikimedia metadata.

## Safety and provider behaviour

- Commons candidates are accepted only for CC0, Public Domain, CC BY, or CC BY-SA licence names. Unknown, NC, ND, SVG, and unsupported media are skipped before download.
- Geograph candidates come from its curated Football Grounds collection and retain the photographer credit and CC BY-SA 2.0 source-page link.
- Unsplash search and download tracking use the official API. Pexels uses its official API. Keys are environment-only.
- Resolution, orientation, obvious non-photo terms, and stadium identity evidence are checked before full download where provider metadata allows.
- Exact SHA-256 and perceptual hashes remove duplicates, preferring clearer licensing, higher resolution, and then higher score.
- Originals are never blurred, darkened, or destructively cropped.

Provider terms can change. Re-check the linked source and licence records before publishing a batch in the app.

## Tests

```bash
pytest
```

The tests use generated local images and mocked provider responses; they do not consume provider quotas.
