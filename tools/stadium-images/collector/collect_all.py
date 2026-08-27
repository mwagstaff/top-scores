#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import yaml
from find_images import (
    BITWARDEN_ITEM,
    DEFAULT_STAGING_ROOT,
    DEFAULT_WIKIMEDIA_CONCURRENCY,
    DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS,
    OPENAI_MAX_RETRIES,
    configure_wikimedia_requests,
    load_openai_api_key,
    research_stadium,
    stage_suitable_images,
)
from openai import OpenAI

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_PREMIER_LEAGUE_CONFIG = (
    PROJECT_ROOT / "tools/stadium-images/config/premier-league.yaml"
)
DEFAULT_CHAMPIONSHIP_CONFIG = (
    PROJECT_ROOT / "tools/stadium-images/config/championship.yaml"
)
DEFAULT_MAJOR_VENUES_CONFIG = (
    PROJECT_ROOT / "tools/stadium-images/config/major-european-venues.yaml"
)
DEFAULT_TOP_TEAMS_CONFIG = PROJECT_ROOT / "api/top_teams_config.json"
DEFAULT_CLUB_ELO_DATA = PROJECT_ROOT / "api/club_elo_teams.json"
ALL_SCOPES = {"premier-league", "championship", "major"}
DEFAULT_WORKERS = 5


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
    championship_config: Path = DEFAULT_CHAMPIONSHIP_CONFIG,
    major_venues_config: Path = DEFAULT_MAJOR_VENUES_CONFIG,
    top_teams_config: Path = DEFAULT_TOP_TEAMS_CONFIG,
    club_elo_data: Path = DEFAULT_CLUB_ELO_DATA,
    scopes: set[str] | None = None,
) -> tuple[list[dict], float]:
    selected_scopes = scopes or ALL_SCOPES
    unknown_scopes = selected_scopes - ALL_SCOPES
    if unknown_scopes:
        raise ValueError(
            f"Unknown collection scope: {', '.join(sorted(unknown_scopes))}"
        )

    premier = yaml.safe_load(premier_league_config.read_text(encoding="utf-8"))
    championship = yaml.safe_load(championship_config.read_text(encoding="utf-8"))
    major_venues = yaml.safe_load(major_venues_config.read_text(encoding="utf-8"))
    top_teams = json.loads(top_teams_config.read_text(encoding="utf-8"))
    club_elo_rows = json.loads(club_elo_data.read_text(encoding="utf-8"))
    threshold = float(top_teams["club_elo_threshold"])

    premier_stadiums = premier.get("stadiums") or []
    championship_stadiums = championship.get("stadiums") or []
    major_stadiums = major_venues.get("stadiums") or []
    targets_by_slug: dict[str, dict] = {}
    if "premier-league" in selected_scopes:
        for venue in premier_stadiums:
            target = _target_from_venue(venue, source="Premier League")
            targets_by_slug[target["slug"]] = target
    if "championship" in selected_scopes:
        for venue in championship_stadiums:
            target = _target_from_venue(venue, source="Championship")
            targets_by_slug[target["slug"]] = target

    venue_by_club_elo_name: dict[str, dict] = {}
    all_configured_stadiums = [
        *premier_stadiums,
        *championship_stadiums,
        *major_stadiums,
    ]
    for venue in all_configured_stadiums:
        club_elo_names = [venue.get("club"), *(venue.get("club_elo_names") or [])]
        for club_elo_name in club_elo_names:
            if not club_elo_name:
                continue
            key = normalized_name(str(club_elo_name))
            existing = venue_by_club_elo_name.get(key)
            if existing is not None and existing is not venue:
                raise ValueError(f"Duplicate Club Elo venue mapping: {club_elo_name}")
            venue_by_club_elo_name[key] = venue

    missing = []
    if "major" in selected_scopes:
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
        "search_terms": [
            str(term).strip()
            for term in venue.get("search_terms") or []
            if str(term).strip()
        ],
        "source": source,
    }


def collect_targets(
    targets: list[dict],
    *,
    api_key: str,
    staging_root: Path,
    per_query: int,
    min_score: int,
    max_downloads: int,
    replace: bool,
    workers: int = DEFAULT_WORKERS,
    wikimedia_concurrency: int = DEFAULT_WIKIMEDIA_CONCURRENCY,
    wikimedia_min_interval: float = DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS,
    client_factory: Callable[..., OpenAI] = OpenAI,
) -> list[tuple[str, str]]:
    if workers < 1:
        raise ValueError("workers must be at least 1")
    configure_wikimedia_requests(wikimedia_concurrency, wikimedia_min_interval)

    pending = []
    for position, target in enumerate(targets, start=1):
        destination = staging_root / target["slug"]
        if destination.exists() and not replace:
            print(f"\n[{position}/{len(targets)}] Skipping existing {destination}")
            continue
        pending.append((position, target))

    failures = []
    if not pending:
        return failures

    worker_count = min(workers, len(pending))
    print(
        f"\nRunning {worker_count} stadium pipelines in parallel. "
        f"Wikimedia: {wikimedia_concurrency} concurrent, "
        f"{wikimedia_min_interval:g}s minimum interval; "
        f"OpenAI: up to {worker_count} concurrent analyses."
    )
    with ThreadPoolExecutor(
        max_workers=worker_count,
        thread_name_prefix="stadium-collector",
    ) as executor:
        future_targets = {
            executor.submit(
                _collect_target,
                position=position,
                total=len(targets),
                target=target,
                api_key=api_key,
                staging_root=staging_root,
                per_query=per_query,
                min_score=min_score,
                max_downloads=max_downloads,
                replace=replace,
                client_factory=client_factory,
            ): target
            for position, target in pending
        }
        for future in as_completed(future_targets):
            target = future_targets[future]
            try:
                staged = future.result()
                print(f"  READY: {target['stadium']} → {staged}")
            except Exception as error:  # noqa: BLE001 - report every failed venue
                failures.append((target["stadium"], str(error)))
                print(f"  FAILED: {target['stadium']}: {error}")
    return failures


def _collect_target(
    *,
    position: int,
    total: int,
    target: dict,
    api_key: str,
    staging_root: Path,
    per_query: int,
    min_score: int,
    max_downloads: int,
    replace: bool,
    client_factory: Callable[..., OpenAI],
) -> Path:
    label = f"[{position}/{total} {target['stadium']}]"
    print(f"\n{label} Starting")
    result = research_stadium(
        target["stadium"],
        client_factory(api_key=api_key, max_retries=OPENAI_MAX_RETRIES),
        per_query=per_query,
        queries=target["search_terms"] or None,
        log_prefix=label,
    )
    return stage_suitable_images(
        result,
        staging_root=staging_root,
        slug=target["slug"],
        min_score=min_score,
        max_downloads=max_downloads,
        replace=replace,
        teams=target["teams"],
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Collect Premier League, Championship, and major Club Elo stadium images."
        )
    )
    parser.add_argument(
        "--scope",
        choices=["all", "premier-league", "championship", "major"],
        default="all",
        help="Target group to collect (default: all)",
    )
    parser.add_argument("--per-query", type=int, default=10)
    parser.add_argument("--min-score", type=int, default=70)
    parser.add_argument("--max-downloads", type=int, default=10)
    parser.add_argument("--staging-root", type=Path, default=DEFAULT_STAGING_ROOT)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--yes", action="store_true", help="Skip the cost confirmation")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int, help="Development-only target limit")
    parser.add_argument(
        "--workers",
        type=int,
        default=DEFAULT_WORKERS,
        help=f"Concurrent stadium pipelines (default: {DEFAULT_WORKERS})",
    )
    parser.add_argument(
        "--wikimedia-concurrency",
        type=int,
        default=DEFAULT_WIKIMEDIA_CONCURRENCY,
        help=(
            "Maximum simultaneous Wikimedia requests "
            f"(default: {DEFAULT_WIKIMEDIA_CONCURRENCY})"
        ),
    )
    parser.add_argument(
        "--wikimedia-min-interval",
        type=float,
        default=DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS,
        help=(
            "Minimum seconds between Wikimedia request starts "
            f"(default: {DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS})"
        ),
    )
    parser.add_argument("--bitwarden-item", default=BITWARDEN_ITEM)
    parser.add_argument(
        "--refresh-api-key",
        action="store_true",
        help="Ignore the cached Keychain value and reload it from Bitwarden",
    )
    args = parser.parse_args()

    scopes = ALL_SCOPES if args.scope == "all" else {args.scope}
    targets, threshold = load_collection_targets(scopes=scopes)
    if args.limit is not None:
        targets = targets[: max(args.limit, 0)]
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    if args.wikimedia_concurrency < 1:
        parser.error("--wikimedia-concurrency must be at least 1")
    if args.wikimedia_min_interval < 0:
        parser.error("--wikimedia-min-interval cannot be negative")
    print(
        f"Resolved {len(targets)} unique stadiums for scope '{args.scope}' "
        f"(Major teams Club Elo threshold: {threshold:.0f})."
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

    api_key = load_openai_api_key(
        args.bitwarden_item,
        use_cached=not args.refresh_api_key,
    )
    failures = collect_targets(
        targets,
        api_key=api_key,
        staging_root=args.staging_root,
        per_query=args.per_query,
        min_score=args.min_score,
        max_downloads=args.max_downloads,
        replace=args.replace,
        workers=args.workers,
        wikimedia_concurrency=args.wikimedia_concurrency,
        wikimedia_min_interval=args.wikimedia_min_interval,
    )

    if failures:
        names = ", ".join(name for name, _ in failures)
        raise RuntimeError(f"Collection failed for {len(failures)} stadium(s): {names}")


if __name__ == "__main__":
    main()
