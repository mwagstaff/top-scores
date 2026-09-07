"""Shared team directory names for collection, review and publication."""

from functools import lru_cache
import json
from pathlib import Path
import re
import unicodedata


def slugify(value: str) -> str:
    value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


@lru_cache(maxsize=1)
def identities() -> dict:
    path = Path(__file__).resolve().parents[2] / "config/team-identities.json"
    return json.loads(path.read_text())["teams"]


def identify_team(team: dict) -> dict:
    result = dict(team)
    known = identities().get(slugify(str(team["name"])))
    if known is None:
        name = slugify(str(team["name"]))
        matches = [row for row in identities().values()
                   if name in {slugify(alias) for alias in row.get("aliases", [])}]
        if len(matches) == 1:
            known = matches[0]
    bsd_id = str(team.get("bsd_team_id") or (known or {}).get("bsd_team_id") or "")
    if not bsd_id:
        source_ids = team.get("source_team_ids") or []
        if len(source_ids) == 1:
            bsd_id = str(source_ids[0])
    if not re.fullmatch(r"[1-9][0-9]*", bsd_id):
        raise ValueError(f"A verified BSD team ID is required for {team['name']}")
    result["bsd_team_id"] = bsd_id
    return result


def team_folder(team: dict) -> str:
    team = identify_team(team)
    return f"{slugify(team['name'])}-{team['bsd_team_id']}"
