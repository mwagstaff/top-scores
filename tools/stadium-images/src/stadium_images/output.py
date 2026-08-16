from __future__ import annotations

import json
import shutil
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path

from .database import StateDatabase
from .models import ImageRecord, League, Stadium

CATEGORIES = ("day", "night", "twilight", "unknown")


def record_sort_key(record: ImageRecord) -> tuple[float, int, int, str]:
    return (
        -record.score,
        -(record.width * record.height),
        source_priority(record),
        record.id,
    )


def source_priority(record: ImageRecord) -> int:
    license_name = record.license.casefold()
    if "public domain" in license_name or "cc0" in license_name:
        return 0
    if (
        record.source == "wikimedia"
        and "by-sa" not in license_name
        and "by sa" not in license_name
    ):
        return 1
    if record.source == "wikimedia":
        return 2
    if record.source == "pexels":
        return 3
    if record.source == "unsplash":
        return 4
    return 5


def duplicate_preference(record: ImageRecord) -> tuple[int, int, float, str]:
    return (
        source_priority(record),
        -(record.width * record.height),
        -record.score,
        record.id,
    )


class OutputWriter:
    def __init__(self, output_dir: Path, database: StateDatabase) -> None:
        self.output_dir = output_dir
        self.database = database

    def write_stadium(self, league: League, stadium: Stadium) -> list[ImageRecord]:
        records = sorted(
            self.database.list_images(league.slug, stadium.slug),
            key=record_sort_key,
        )
        stadium_dir = self.output_dir / league.slug / stadium.slug
        ranked_paths: dict[str, str] = {}
        for category in CATEGORIES:
            category_dir = stadium_dir / category
            category_dir.mkdir(parents=True, exist_ok=True)
            for previous in category_dir.iterdir():
                if previous.is_file() and previous.stem.isdigit():
                    previous.unlink()
            category_records = sorted(
                (record for record in records if record.time_of_day == category),
                key=record_sort_key,
            )
            for rank, record in enumerate(category_records, start=1):
                source = self.output_dir / record.local_original_path
                extension = source.suffix.casefold() or ".jpg"
                destination = category_dir / f"{rank:03d}{extension}"
                shutil.copy2(source, destination)
                ranked_paths[record.id] = destination.relative_to(
                    self.output_dir
                ).as_posix()

        metadata = {
            "league": league.slug,
            "season": league.season,
            "stadium": stadium.name,
            "club": stadium.club,
            "generated_at": datetime.now(UTC).isoformat(),
            "images": [
                {**record.to_dict(), "ranked_path": ranked_paths.get(record.id)}
                for record in records
            ],
        }
        _write_json(stadium_dir / "metadata.json", metadata)
        return records

    def write_global_files(self) -> None:
        records = self.database.list_all_images()
        generated_at = datetime.now(UTC).isoformat()
        manifest: dict[str, object] = {"generated_at": generated_at, "leagues": {}}
        leagues = manifest["leagues"]
        assert isinstance(leagues, dict)
        grouped: dict[tuple[str, str, str], list[ImageRecord]] = defaultdict(list)
        for record in records:
            grouped[(record.league, record.stadium_slug, record.time_of_day)].append(
                record
            )
        for (league, stadium_slug, category), category_records in sorted(
            grouped.items()
        ):
            league_manifest = leagues.setdefault(league, {"stadiums": {}})
            stadiums = league_manifest["stadiums"]
            stadium_manifest = stadiums.setdefault(
                stadium_slug, {name: [] for name in CATEGORIES}
            )
            for rank, record in enumerate(
                sorted(category_records, key=record_sort_key), start=1
            ):
                original = Path(record.local_original_path)
                ranked_path = (
                    original.parent.parent
                    / category
                    / f"{rank:03d}{original.suffix.casefold()}"
                )
                stadium_manifest[category].append(
                    {
                        "id": record.id,
                        "path": ranked_path.as_posix(),
                        "score": record.score,
                        "source": record.source,
                        "license": record.license,
                    }
                )
        _write_json(self.output_dir / "manifest.json", manifest)

        attribution_values = [
            self._attribution_value(record)
            for record in sorted(records, key=_credit_key)
        ]
        _write_json(
            self.output_dir / "attributions.json",
            {"generated_at": generated_at, "images": attribution_values},
        )
        (self.output_dir / "ATTRIBUTIONS.md").write_text(
            self._attributions_markdown(records),
            encoding="utf-8",
        )

    @staticmethod
    def _attribution_value(record: ImageRecord) -> dict[str, object]:
        return {
            "id": record.id,
            "league": record.league,
            "stadium": record.stadium,
            "club": record.club,
            "author": record.author,
            "author_url": record.author_url,
            "source": record.source,
            "source_page": record.source_page,
            "license": record.license,
            "license_url": record.license_url,
            "attribution": record.attribution,
        }

    @staticmethod
    def _attributions_markdown(records: list[ImageRecord]) -> str:
        lines = ["# Stadium image attributions", ""]
        current_league = ""
        current_stadium = ""
        for record in sorted(records, key=_credit_key):
            if record.league != current_league:
                current_league = record.league
                current_stadium = ""
                lines.extend((f"## {current_league}", ""))
            if record.stadium != current_stadium:
                current_stadium = record.stadium
                lines.extend((f"### {record.stadium} — {record.club}", ""))
            lines.extend(
                (
                    f"#### {record.id}",
                    "",
                    f"- Credit: {record.attribution}",
                    f"- Source: [{record.source}]({record.source_page})",
                    f"- Licence: [{record.license}]({record.license_url or record.source_page})",
                    "",
                )
            )
        return "\n".join(lines).rstrip() + "\n"


def _credit_key(record: ImageRecord) -> tuple[str, str, str]:
    return (record.league, record.stadium, record.id)


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)
