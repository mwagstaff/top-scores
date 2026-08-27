#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import yaml
from find_images import (
    BITWARDEN_ITEM,
    DEFAULT_STAGING_ROOT,
    load_openai_api_key,
    research_stadium,
    stage_suitable_images,
)
from openai import OpenAI

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_PREMIER_LEAGUE_CONFIG = (
    PROJECT_ROOT / "tools/stadium-images/config/premier-league.yaml"
)
DEFAULT_MAJOR_VENUES_CONFIG = (
    PROJECT_ROOT / "tools/stadium-images/config/major-european-venues.yaml"
)
DEFAULT_TOP_TEAMS_CONFIG = PROJECT_ROOT / "api/top_teams_config.json"
DEFAULT_CLUB_ELO_DATA = PROJECT_ROOT / "api/club_elo_teams.json"


def normalized_name(value: str) -> str:
    ascii_value = (
        unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    )
    return "".join(
        character for character in ascii_value.casefold() if character.isalnum()
    )


def teams_for_venue(venue: dict) -> list[dict]:
    configured = venue.get("teams")
    if isinstance(configured, list) and configured:
        return [
            {
                "name": str(team["name"]).strip(),
                "aliases": sorted(
                    {
                        str(alias).strip()
                        for alias in team.get("aliases") or []
                        if str(alias).strip()
                    }
                ),
            }
            for team in configured
        ]

    name = str(venue["club"]).strip()
    aliases = {
        str(alias).strip()
        for alias in [
            *(venue.get("club_aliases") or []),
            *(venue.get("club_elo_names") or []),
        ]
        if str(alias).strip() and normalized_name(str(alias)) != normalized_name(name)
    }
    return [{"name": name, "aliases": sorted(aliases)}]


def load_collection_targets(
    premier_league_config: Path = DEFAULT_PREMIER_LEAGUE_CONFIG,
    major_venues_config: Path = DEFAULT_MAJOR_VENUES_CONFIG,
    top_teams_config: Path = DEFAULT_TOP_TEAMS_CONFIG,
    club_elo_data: Path = DEFAULT_CLUB_ELO_DATA,
) -> tuple[list[dict], float]:
    premier = yaml.safe_load(premier_league_config.read_text(encoding="utf-8"))
    major_venues = yaml.safe_load(major_venues_config.read_text(encoding="utf-8"))
    top_teams = json.loads(top_teams_config.read_text(encoding="utf-8"))
    club_elo_rows = json.loads(club_elo_data.read_text(encoding="utf-8"))
    threshold = float(top_teams["club_elo_threshold"])

    premier_stadiums = premier.get("stadiums") or []
    major_stadiums = major_venues.get("stadiums") or []
    targets_by_slug: dict[str, dict] = {}
    for venue in premier_stadiums:
        target = _target_from_venue(venue, source="Premier League")
        targets_by_slug[target["slug"]] = target

    venue_by_club_elo_name: dict[str, dict] = {}
    for venue in [*premier_stadiums, *major_stadiums]:
        for club_elo_name in venue.get("club_elo_names") or []:
            key = normalized_name(str(club_elo_name))
            if key in venue_by_club_elo_name:
                raise ValueError(f"Duplicate Club Elo venue mapping: {club_elo_name}")
            venue_by_club_elo_name[key] = venue

    missing = []
    for row in club_elo_rows:
        elo = float(row.get("Elo", row.get("elo", 0)) or 0)
        if elo < threshold:
            continue
        club_name = str(
            row.get("Name") or row.get("name") or row.get("Club") or ""
        ).strip()
        venue = venue_by_club_elo_name.get(normalized_name(club_name))
        if venue is None:
            missing.append(club_name)
            continue
        target = _target_from_venue(venue, source=f"Club Elo {elo:.0f}")
        targets_by_slug.setdefault(target["slug"], target)

    if missing:
        raise ValueError(
            "Major Club Elo teams have no configured venue: "
            + ", ".join(sorted(missing))
        )
    return list(targets_by_slug.values()), threshold


def _target_from_venue(venue: dict, *, source: str) -> dict:
    return {
        "club": str(venue["club"]).strip(),
        "stadium": str(venue["stadium"]).strip(),
        "slug": str(venue["slug"]).strip(),
        "teams": teams_for_venue(venue),
        "source": source,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Collect every Premier League venue plus every club meeting the "
            "Top teams Club Elo threshold."
        )
    )
    parser.add_argument("--per-query", type=int, default=10)
    parser.add_argument("--min-score", type=int, default=70)
    parser.add_argument("--max-downloads", type=int, default=10)
    parser.add_argument("--staging-root", type=Path, default=DEFAULT_STAGING_ROOT)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--yes", action="store_true", help="Skip the cost confirmation")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int, help="Development-only target limit")
    parser.add_argument("--bitwarden-item", default=BITWARDEN_ITEM)
    args = parser.parse_args()

    targets, threshold = load_collection_targets()
    if args.limit is not None:
        targets = targets[: max(args.limit, 0)]
    print(
        f"Resolved {len(targets)} unique stadiums using the Top teams "
        f"Club Elo threshold of {threshold:.0f}."
    )
    for target in targets:
        print(f"  {target['stadium']} — {target['club']} ({target['source']})")
    if args.dry_run:
        return

    if not args.yes:
        if not sys.stdin.isatty():
            raise RuntimeError(
                "Pass --yes when running without an interactive terminal."
            )
        answer = input("\nRun the OpenAI vision collection for these stadiums? [y/N] ")
        if answer.strip().casefold() not in {"y", "yes"}:
            print("Cancelled.")
            return

    api_key = load_openai_api_key(args.bitwarden_item)
    client = OpenAI(api_key=api_key)
    failures = []
    for position, target in enumerate(targets, start=1):
        destination = args.staging_root / target["slug"]
        if destination.exists() and not args.replace:
            print(f"\n[{position}/{len(targets)}] Skipping existing {destination}")
            continue
        print(f"\n[{position}/{len(targets)}] {target['stadium']}")
        try:
            result = research_stadium(
                target["stadium"],
                client,
                per_query=args.per_query,
            )
            staged = stage_suitable_images(
                result,
                staging_root=args.staging_root,
                slug=target["slug"],
                min_score=args.min_score,
                max_downloads=args.max_downloads,
                replace=args.replace,
                teams=target["teams"],
            )
            print(f"  Ready for human review: {staged}")
        except Exception as error:  # noqa: BLE001 - continue collecting other venues
            failures.append((target["stadium"], str(error)))
            print(f"  FAILED: {error}")

    if failures:
        names = ", ".join(name for name, _ in failures)
        raise RuntimeError(f"Collection failed for {len(failures)} stadium(s): {names}")


if __name__ == "__main__":
    main()
