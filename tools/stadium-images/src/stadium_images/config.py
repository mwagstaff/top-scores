from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from .models import FilterConfig, League, RetentionConfig, Stadium

PACKAGE_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG_DIR = PACKAGE_ROOT / "config"
DEFAULT_OUTPUT_DIR = PACKAGE_ROOT / "output"


class ConfigError(ValueError):
    pass


def _required(mapping: dict[str, Any], key: str, context: str) -> Any:
    value = mapping.get(key)
    if value is None or value == "":
        raise ConfigError(f"Missing {key!r} in {context}")
    return value


def load_league(slug: str, config_dir: Path = DEFAULT_CONFIG_DIR) -> League:
    path = config_dir / f"{slug}.yaml"
    if not path.exists():
        available = ", ".join(sorted(item.stem for item in config_dir.glob("*.yaml")))
        raise ConfigError(
            f"Unknown league {slug!r}. Available leagues: {available or 'none'}"
        )

    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ConfigError(f"Expected a mapping in {path}")

    stadiums: list[Stadium] = []
    seen_slugs: set[str] = set()
    for index, item in enumerate(raw.get("stadiums", []), start=1):
        context = f"stadium #{index} in {path.name}"
        if not isinstance(item, dict):
            raise ConfigError(f"Expected a mapping for {context}")
        stadium_slug = str(_required(item, "slug", context))
        if stadium_slug in seen_slugs:
            raise ConfigError(f"Duplicate stadium slug {stadium_slug!r} in {path.name}")
        seen_slugs.add(stadium_slug)
        search_terms = tuple(
            str(term).strip()
            for term in item.get("search_terms", [])
            if str(term).strip()
        )
        if not search_terms:
            raise ConfigError(f"At least one search term is required for {context}")
        coordinates = item.get("coordinates") or {}
        stadiums.append(
            Stadium(
                club=str(_required(item, "club", context)),
                name=str(_required(item, "stadium", context)),
                slug=stadium_slug,
                aliases=tuple(str(alias) for alias in item.get("aliases", [])),
                search_terms=search_terms,
                latitude=_optional_float(coordinates.get("latitude")),
                longitude=_optional_float(coordinates.get("longitude")),
            )
        )

    if not stadiums:
        raise ConfigError(f"No stadiums configured in {path.name}")

    filters = raw.get("filters") or {}
    preferred = filters.get("preferred_aspect_ratio") or {}
    retention = raw.get("retention") or {}
    return League(
        slug=str(_required(raw, "league", path.name)),
        name=str(_required(raw, "name", path.name)),
        season=str(_required(raw, "season", path.name)),
        membership_source=str(_required(raw, "membership_source", path.name)),
        stadiums=tuple(stadiums),
        filters=FilterConfig(
            min_width=int(filters.get("min_width", 1600)),
            min_height=int(filters.get("min_height", 900)),
            min_aspect_ratio=float(filters.get("min_aspect_ratio", 1.3)),
            preferred_aspect_ratio_min=float(preferred.get("min", 1.5)),
            preferred_aspect_ratio_max=float(preferred.get("max", 2.4)),
            min_score=float(filters.get("min_score", 7.0)),
            perceptual_hash_distance=int(filters.get("perceptual_hash_distance", 6)),
        ),
        retention=RetentionConfig(
            day=int(retention.get("day", 30)),
            night=int(retention.get("night", 30)),
            twilight=int(retention.get("twilight", 15)),
            unknown=int(retention.get("unknown", 10)),
        ),
        results_per_query=int(raw.get("results_per_query", 30)),
    )


def find_stadium(league: League, value: str) -> Stadium:
    normalized = value.casefold().strip()
    matches = [
        stadium
        for stadium in league.stadiums
        if normalized
        in {
            stadium.name.casefold(),
            stadium.slug.casefold(),
            stadium.club.casefold(),
            *(alias.casefold() for alias in stadium.aliases),
        }
    ]
    if not matches:
        raise ConfigError(f"No stadium or club matching {value!r} in {league.name}")
    if len(matches) > 1:
        names = ", ".join(stadium.name for stadium in matches)
        raise ConfigError(f"Ambiguous stadium {value!r}: {names}")
    return matches[0]


def _optional_float(value: Any) -> float | None:
    return None if value is None else float(value)
