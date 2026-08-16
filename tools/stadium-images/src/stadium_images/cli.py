from __future__ import annotations

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
from .sources import PexelsSource, UnsplashSource, WikimediaSource

app = typer.Typer(
    name="stadium-images",
    help="Collect legally reusable stadium photography with complete provenance.",
    no_args_is_help=True,
)
console = Console()


@app.command()
def collect(
    league: str = typer.Option("premier-league", help="League config slug."),
    stadium: str | None = typer.Option(
        None, help="Stadium, club, alias, or slug to collect."
    ),
    sources: str = typer.Option(
        "wikimedia,unsplash,pexels", help="Comma-separated providers."
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
            for category in ("day", "night", "twilight", "unknown"):
                category_records = sorted(
                    (record for record in records if record.time_of_day == category),
                    key=record_sort_key,
                )
                for rank, record in enumerate(category_records, start=1):
                    source = output / record.local_original_path
                    destination = (
                        output
                        / league_config.slug
                        / selected.slug
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
    for column in ("Stadium", "Day", "Night", "Twilight", "Unknown", "Average", "Best"):
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
                str(counts["twilight"]),
                str(counts["unknown"]),
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
        OutputWriter(output, database).write_global_files()
        count = len(database.list_all_images())
    console.print(f"Wrote attribution records for {count} images")


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
    unknown = set(sources) - {"wikimedia", "unsplash", "pexels"}
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
