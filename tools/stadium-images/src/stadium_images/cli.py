from __future__ import annotations

import shutil
from collections import Counter
from pathlib import Path

import typer
from rich.console import Console
from rich.table import Table

from .collector import Collector
from .config import (
    DEFAULT_CONFIG_DIR,
    DEFAULT_OUTPUT_DIR,
    ConfigError,
    find_stadium,
    load_league,
)
from .database import StateDatabase
from .http import HTTPClient
from .models import ImageCandidate, ImageRecord, League, Stadium
from .output import OutputWriter, duplicate_preference, record_sort_key
from .processing.classifier import HeuristicImageClassifier
from .processing.convert import create_hero_derivative
from .processing.dedupe import perceptual_distance
from .processing.review import create_review_sheet
from .publishing import (
    DEFAULT_PROJECT_ROOT,
    DEFAULT_PUBLISH_DIR,
    PublishError,
    build_publish_bundle,
    validate_publish_bundle,
)
from .sources import (
    GeographSource,
    OpenverseSource,
    PexelsSource,
    UnsplashSource,
    WikimediaSource,
)

app = typer.Typer(
    name="stadium-images",
    help="Collect legally reusable stadium photography with complete provenance.",
    no_args_is_help=True,
)
console = Console()


@app.command("publish")
def publish_artwork(
    config: Path = typer.Option(
        DEFAULT_CONFIG_DIR / "publishing.yaml",
        exists=True,
        dir_okay=False,
        help="Artwork assignments and credit metadata.",
    ),
    output: Path = typer.Option(DEFAULT_PUBLISH_DIR, file_okay=False),
    project_root: Path = typer.Option(
        DEFAULT_PROJECT_ROOT,
        exists=True,
        file_okay=False,
    ),
) -> None:
    """Build and validate the filesystem bundle consumed by the API."""
    try:
        catalog = build_publish_bundle(config, output, project_root)
        validate_publish_bundle(output)
    except PublishError as error:
        raise typer.BadParameter(str(error)) from error
    console.print(
        f"Published {len(catalog['assets'])} assets as {catalog['catalog_version']}"
    )


@app.command()
def collect(
    league: str = typer.Option("premier-league", help="League config slug."),
    stadium: str | None = typer.Option(
        None, help="Stadium, club, alias, or slug to collect."
    ),
    sources: str = typer.Option(
        "wikimedia,geograph,openverse,unsplash,pexels",
        help="Comma-separated providers.",
    ),
    min_score: float | None = typer.Option(
        None, min=0.0, max=10.0, help="Override minimum score."
    ),
    limit: int | None = typer.Option(
        None, min=1, help="Maximum retained images per category."
    ),
    results_per_query: int | None = typer.Option(
        None, min=1, max=80, help="Provider results per query."
    ),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Search providers, download, validate, rank, and retain stadium images."""
    try:
        league_config = load_league(league, config_dir)
        stadiums = (
            (find_stadium(league_config, stadium),)
            if stadium is not None
            else league_config.stadiums
        )
        source_names = _parse_sources(sources)
        output.mkdir(parents=True, exist_ok=True)
        with StateDatabase(output / ".state.sqlite3") as database, HTTPClient() as http:
            providers = {
                "wikimedia": WikimediaSource(http),
                "geograph": GeographSource(http),
                "openverse": OpenverseSource(http),
                "unsplash": UnsplashSource(http),
                "pexels": PexelsSource(http),
            }
            Collector(
                output_dir=output,
                database=database,
                http=http,
                sources=providers,
                console=console,
            ).collect(
                league_config,
                stadiums,
                source_names,
                min_score=min_score,
                retention_limit=limit,
                results_per_query=results_per_query,
            )
    except (ConfigError, ValueError) as error:
        raise typer.BadParameter(str(error)) from error


@app.command()
def classify(
    league: str = typer.Option("premier-league"),
    stadium: str | None = typer.Option(None, help="Restrict to one stadium."),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Re-run the local heuristic classifier against retained originals."""
    league_config, stadiums = _selection(league, stadium, config_dir)
    classifier = HeuristicImageClassifier()
    with StateDatabase(output / ".state.sqlite3") as database:
        writer = OutputWriter(output, database)
        updated = 0
        for selected in stadiums:
            for record in database.list_images(league_config.slug, selected.slug):
                path = output / record.local_original_path
                if not path.exists():
                    console.print(
                        f"[yellow]WARNING:[/] missing original for {record.id}: {path}"
                    )
                    continue
                result = classifier.classify(path, _candidate_from_record(record))
                record.time_of_day = result.time_of_day
                record.classification_confidence = result.confidence
                record.classification_reasons = result.reasons
                database.save_image(record)
                updated += 1
            writer.write_stadium(league_config, selected)
        writer.write_global_files()
    console.print(f"Classified {updated} retained images")


@app.command()
def dedupe(
    league: str = typer.Option("premier-league"),
    stadium: str | None = typer.Option(None, help="Restrict to one stadium."),
    distance: int | None = typer.Option(
        None, min=0, help="Perceptual hash distance threshold."
    ),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Re-run exact and perceptual duplicate removal against retained images."""
    league_config, stadiums = _selection(league, stadium, config_dir)
    threshold = (
        distance
        if distance is not None
        else league_config.filters.perceptual_hash_distance
    )
    removed = 0
    with StateDatabase(output / ".state.sqlite3") as database:
        writer = OutputWriter(output, database)
        for selected in stadiums:
            kept: list[ImageRecord] = []
            records = sorted(
                database.list_images(league_config.slug, selected.slug),
                key=duplicate_preference,
            )
            for record in records:
                duplicate = next(
                    (
                        existing
                        for existing in kept
                        if record.sha256 == existing.sha256
                        or perceptual_distance(
                            record.perceptual_hash, existing.perceptual_hash
                        )
                        <= threshold
                    ),
                    None,
                )
                if duplicate is None:
                    kept.append(record)
                    continue
                (output / record.local_original_path).unlink(missing_ok=True)
                database.delete_image(record)
                removed += 1
            writer.write_stadium(league_config, selected)
        writer.write_global_files()
    console.print(f"Removed {removed} duplicate images")


@app.command()
def process(
    league: str = typer.Option("premier-league"),
    stadium: str | None = typer.Option(None, help="Restrict to one stadium."),
    width: int = typer.Option(1290, min=1),
    height: int = typer.Option(600, min=1),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Create non-destructive, centre-cropped WebP hero derivatives."""
    league_config, stadiums = _selection(league, stadium, config_dir)
    generated = 0
    with StateDatabase(output / ".state.sqlite3") as database:
        for selected in stadiums:
            records = database.list_images(league_config.slug, selected.slug)
            for category in ("day", "night"):
                category_records = sorted(
                    (record for record in records if record.time_of_day == category),
                    key=record_sort_key,
                )
                for rank, record in enumerate(category_records, start=1):
                    source = output / record.local_original_path
                    destination = (
                        output
                        / league_config.slug
                        / selected.team_slug
                        / "processed"
                        / category
                        / f"{rank:03d}_hero_{width}x{height}.webp"
                    )
                    create_hero_derivative(source, destination, width, height)
                    generated += 1
    console.print(f"Generated {generated} WebP derivatives at {width}×{height}")


@app.command()
def report(
    league: str = typer.Option("premier-league"),
    stadium: str | None = typer.Option(None, help="Restrict to one stadium."),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Show retained-image counts and score ranges."""
    league_config, stadiums = _selection(league, stadium, config_dir)
    table = Table(title=f"{league_config.name} {league_config.season} stadium images")
    for column in ("Stadium", "Day", "Night", "Average", "Best"):
        table.add_column(column, justify="right" if column != "Stadium" else "left")
    with StateDatabase(output / ".state.sqlite3") as database:
        for selected in stadiums:
            records = database.list_images(league_config.slug, selected.slug)
            counts = Counter(record.time_of_day for record in records)
            average = (
                f"{sum(record.score for record in records) / len(records):.1f}"
                if records
                else "—"
            )
            best = f"{max(record.score for record in records):.1f}" if records else "—"
            table.add_row(
                selected.name,
                str(counts["day"]),
                str(counts["night"]),
                average,
                best,
            )
    console.print(table)


@app.command()
def attributions(
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Regenerate Markdown and JSON attribution files from retained metadata."""
    with StateDatabase(output / ".state.sqlite3") as database:
        records = database.list_all_images()
        for record in records:
            database.save_image(record)
        OutputWriter(output, database).write_global_files()
        count = len(records)
    console.print(f"Wrote attribution records for {count} images")


@app.command("migrate-output")
def migrate_output(
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Move existing output to team directories and normalize to day/night."""
    leagues = tuple(
        load_league(path.stem, config_dir) for path in sorted(config_dir.glob("*.yaml"))
    )
    stadiums = {
        (league.slug, stadium.slug): stadium
        for league in leagues
        for stadium in league.stadiums
    }
    classifier = HeuristicImageClassifier()
    moved = 0
    twilight_to_night = 0
    unknown_classified = 0

    with StateDatabase(output / ".state.sqlite3") as database:
        records = database.list_all_images()
        operations: list[tuple[ImageRecord, Stadium, Path, Path]] = []
        missing: list[Path] = []
        conflicts: list[Path] = []
        for record in records:
            selected = stadiums.get((record.league, record.stadium_slug))
            if selected is None:
                raise typer.BadParameter(
                    f"No config entry for {record.league}/{record.stadium_slug}"
                )
            source = output / record.local_original_path
            destination = (
                output
                / record.league
                / selected.team_slug
                / "original"
                / source.name
            )
            if not source.exists():
                missing.append(source)
            if destination != source and destination.exists():
                conflicts.append(destination)
            operations.append((record, selected, source, destination))

        if missing:
            raise typer.BadParameter(f"Missing {len(missing)} retained originals")
        if conflicts:
            raise typer.BadParameter(f"Found {len(conflicts)} destination conflicts")

        legacy_dirs: set[Path] = set()
        for record, selected, source, destination in operations:
            previous_category = str(record.time_of_day)
            if previous_category == "twilight":
                record.time_of_day = "night"
                record.classification_reasons = (
                    *record.classification_reasons,
                    "twilight normalized to night",
                )
                twilight_to_night += 1
            elif previous_category not in {"day", "night"}:
                result = classifier.classify(source, _candidate_from_record(record))
                record.time_of_day = result.time_of_day
                record.classification_confidence = result.confidence
                record.classification_reasons = result.reasons
                unknown_classified += 1

            if source != destination:
                destination.parent.mkdir(parents=True, exist_ok=True)
                source.replace(destination)
                record.local_original_path = destination.relative_to(output).as_posix()
                moved += 1
                legacy_dirs.add(output / record.league / selected.slug)
            database.save_image(record)

        for legacy_dir in sorted(legacy_dirs):
            shutil.rmtree(legacy_dir, ignore_errors=True)

        writer = OutputWriter(output, database)
        for league in leagues:
            for selected in league.stadiums:
                writer.write_stadium(league, selected)
        writer.write_global_files()

    console.print(
        f"Migrated {moved} originals; moved {twilight_to_night} twilight images "
        f"to night and classified {unknown_classified} unknown images"
    )


@app.command("review-sheet")
def review_sheet(
    league: str = typer.Option("premier-league"),
    picks: int = typer.Option(3, min=1, max=6, help="Top images per stadium."),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Generate a labelled contact sheet for fast human review."""
    league_config = load_league(league, config_dir)
    destination = output / "review" / f"{league}.jpg"
    with StateDatabase(output / ".state.sqlite3") as database:
        count = create_review_sheet(
            output,
            database,
            league_config,
            destination,
            picks_per_stadium=picks,
        )
    console.print(f"Wrote {count} review thumbnails to {destination}")


@app.command()
def reject(
    image_ids: list[str] = typer.Argument(
        ..., help="Stable retained-image IDs to reject after visual review."
    ),
    reason: str = typer.Option("human review", help="Reason stored in local state."),
    config_dir: Path = typer.Option(DEFAULT_CONFIG_DIR, exists=True, file_okay=False),
    output: Path = typer.Option(DEFAULT_OUTPUT_DIR, file_okay=False),
) -> None:
    """Persistently reject retained images selected during human review."""
    with StateDatabase(output / ".state.sqlite3") as database:
        records_by_id = {record.id: record for record in database.list_all_images()}
        missing = [image_id for image_id in image_ids if image_id not in records_by_id]
        if missing:
            raise typer.BadParameter(f"Unknown retained image IDs: {', '.join(missing)}")
        writer = OutputWriter(output, database)
        touched: set[tuple[str, str]] = set()
        for image_id in image_ids:
            record = records_by_id[image_id]
            database.set_manual_rejection(record, reason)
            (output / record.local_original_path).unlink(missing_ok=True)
            database.delete_image(record)
            touched.add((record.league, record.stadium_slug))
        for league_slug, stadium_slug in sorted(touched):
            league_config = load_league(league_slug, config_dir)
            selected = next(
                stadium
                for stadium in league_config.stadiums
                if stadium.slug == stadium_slug
            )
            writer.write_stadium(league_config, selected)
        writer.write_global_files()
    console.print(f"Persistently rejected {len(image_ids)} images: {reason}")


def _selection(
    league: str, stadium: str | None, config_dir: Path
) -> tuple[League, tuple[Stadium, ...]]:
    try:
        league_config = load_league(league, config_dir)
        return league_config, (
            (find_stadium(league_config, stadium),)
            if stadium is not None
            else league_config.stadiums
        )
    except ConfigError as error:
        raise typer.BadParameter(str(error)) from error


def _parse_sources(value: str) -> tuple[str, ...]:
    sources = tuple(
        dict.fromkeys(
            item.casefold().strip() for item in value.split(",") if item.strip()
        )
    )
    unknown = set(sources) - {
        "wikimedia",
        "geograph",
        "openverse",
        "unsplash",
        "pexels",
    }
    if unknown:
        raise ValueError(f"Unknown sources: {', '.join(sorted(unknown))}")
    if not sources:
        raise ValueError("At least one source is required")
    return sources


def _candidate_from_record(record: ImageRecord) -> ImageCandidate:
    return ImageCandidate(
        source=record.source,
        source_id=record.source_id,
        source_page=record.source_page,
        image_url=record.image_url,
        download_url=record.download_url,
        author=record.author,
        author_url=record.author_url,
        license=record.license,
        license_url=record.license_url,
        attribution=record.attribution,
        width=record.width,
        height=record.height,
        mime_type=record.mime_type,
        title=record.title,
        description=record.description,
        categories=record.categories,
        search_query=record.search_query,
    )


if __name__ == "__main__":
    app()
