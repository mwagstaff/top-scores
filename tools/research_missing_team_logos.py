#!/usr/bin/env python3
"""Research and stage missing team crests from public football/Wikipedia indexes."""

from __future__ import annotations

import argparse
import concurrent.futures
import difflib
import json
import re
import shutil
import subprocess
import tempfile
import time
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path


AUDIT_URL = "https://api.skynolimit.dev/top-scores/api/v1/audit/missing-team-logos"
WIKIPEDIA_API = "https://en.wikipedia.org/w/api.php"
SPORTS_DB_API = "https://www.thesportsdb.com/api/v1/json/123/searchteams.php"
USER_AGENT = "TopScores/1.0 (team crest research; https://skynolimit.dev)"
MANUAL_OVERRIDES = {
    "AFC Wolverhampton City": {
        "provider": "official_club",
        "page_url": "https://www.wolverhampton-city-football.com/blog/blog-2025-26",
        "image_url": "https://www.wolverhampton-city-football.com/Content/uploads/images/Wolverhampton_City_Football_Club_Logo.webp",
    },
    "Berkhamsted Town": {
        "provider": "wikipedia",
        "page_url": "https://en.wikipedia.org/wiki/Berkhamsted_F.C.",
        "image_url": "https://en.wikipedia.org/wiki/Special:Redirect/file/Berkhamsted%20F.C.%20logo.png",
    },
    "DAC 1904": {
        "provider": "wikipedia",
        "page_url": "https://en.wikipedia.org/wiki/FC_DAC_1904_Dunajsk%C3%A1_Streda",
        "image_url": "https://en.wikipedia.org/wiki/Special:Redirect/file/FC%20DAC%201904%20Dunajsk%C3%A1%20Streda%20svg%20logo.svg",
    },
    "Shepshed Dynamo": {
        "provider": "wikimedia_commons",
        "page_url": "https://commons.wikimedia.org/wiki/File:Dynamo_Badge_pdf.jpg",
        "image_url": "https://upload.wikimedia.org/wikipedia/commons/f/fd/Dynamo_Badge_pdf.jpg",
    },
    "St Blazey AFC": {
        "provider": "wikipedia",
        "page_url": "https://en.wikipedia.org/wiki/St_Blazey_A.F.C.",
        "image_url": "https://en.wikipedia.org/wiki/Special:Redirect/file/StBlazey.png",
    },
    "Valur Reykjavík": {
        "provider": "official_club",
        "page_url": "https://www.valur.is/um-val/dreifing-gagna/merki-vals.aspx",
        "image_url": "https://www.valur.is/media/433169/valur_merki_.png",
    },
}
AFFIXES = {
    "afc", "cf", "fc", "fk", "ifk", "nk", "pfk", "sc", "se", "sk",
    "town", "city", "united", "rovers", "club", "football", "f", "c",
}
IMAGE_NOISE = {
    "commons", "flag", "kit", "map", "stadium", "ground", "shirt", "sock",
    "shorts", "arm", "ball", "match", "squad", "player", "season", "photo",
}


def fetch_json(url: str, *, attempts: int = 4) -> dict | list:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except Exception:
            if attempt + 1 >= attempts:
                raise
            time.sleep(1.5 * (2**attempt))
    raise RuntimeError("unreachable")


def api_url(base: str, params: dict[str, str | int]) -> str:
    return f"{base}?{urllib.parse.urlencode(params)}"


def normalized(value: str, *, strip_affixes: bool = False) -> str:
    folded = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    tokens = re.findall(r"[a-z0-9]+", folded.lower().replace("&", " and "))
    if strip_affixes:
        tokens = [token for token in tokens if token not in AFFIXES]
    return " ".join(tokens)


def similarity(left: str, right: str) -> float:
    exact = difflib.SequenceMatcher(None, normalized(left), normalized(right)).ratio()
    core = difflib.SequenceMatcher(
        None, normalized(left, strip_affixes=True), normalized(right, strip_affixes=True)
    ).ratio()
    compact = difflib.SequenceMatcher(
        None, normalized(left).replace(" ", ""), normalized(right).replace(" ", "")
    ).ratio()
    compact_core = difflib.SequenceMatcher(
        None,
        normalized(left, strip_affixes=True).replace(" ", ""),
        normalized(right, strip_affixes=True).replace(" ", ""),
    ).ratio()
    return max(exact, core, compact, compact_core)


def best_wikipedia_page(team_name: str) -> dict | None:
    payload = fetch_json(
        api_url(
            WIKIPEDIA_API,
            {
                "action": "query",
                "generator": "search",
                "gsrsearch": f'"{team_name}" football club',
                "gsrnamespace": 0,
                "gsrlimit": 8,
                "prop": "info",
                "inprop": "url",
                "format": "json",
                "formatversion": 2,
            },
        )
    )
    pages = payload.get("query", {}).get("pages", [])
    scored = []
    for page in pages:
        title = page.get("title", "")
        page_score = similarity(team_name, title)
        title_lower = title.lower()
        if "footballer" in title_lower or "season" in title_lower or "qualifying" in title_lower:
            page_score -= 0.35
        if "f.c" in title_lower or "football club" in title_lower:
            page_score += 0.25
        scored.append((page_score, page))
    if not scored:
        return None
    score, page = max(scored, key=lambda item: item[0])
    if score < 0.72:
        return None
    return {**page, "match_score": round(score, 4)}


def image_score(team_name: str, image_title: str) -> float:
    filename = image_title.removeprefix("File:")
    stem = re.sub(r"\.[^.]+$", "", filename)
    tokens = set(normalized(stem).split())
    team_tokens = set(normalized(team_name, strip_affixes=True).split())
    score = similarity(team_name, stem) * 60
    if team_tokens and team_tokens.issubset(tokens):
        score += 40
    if tokens & {"logo", "badge", "crest", "emblem"}:
        score += 35
    if tokens & IMAGE_NOISE:
        score -= 100
    if filename.lower().endswith((".png", ".svg", ".webp")):
        score += 5
    if filename.lower().endswith((".jpg", ".jpeg")):
        score -= 80
    return score


def wikipedia_candidate(team_name: str) -> dict | None:
    page = best_wikipedia_page(team_name)
    if not page:
        return None
    images_payload = fetch_json(
        api_url(
            WIKIPEDIA_API,
            {
                "action": "query",
                "prop": "images",
                "pageids": page["pageid"],
                "imlimit": "max",
                "format": "json",
                "formatversion": 2,
            },
        )
    )
    images = images_payload.get("query", {}).get("pages", [{}])[0].get("images", [])
    ranked = sorted(
        ((image_score(team_name, image.get("title", "")), image.get("title", "")) for image in images),
        reverse=True,
    )
    if not ranked or ranked[0][0] < 72:
        return None
    score, image_title = ranked[0]
    info_payload = fetch_json(
        api_url(
            WIKIPEDIA_API,
            {
                "action": "query",
                "prop": "imageinfo",
                "titles": image_title,
                "iiprop": "url|mime|size",
                "iiurlwidth": 512,
                "format": "json",
                "formatversion": 2,
            },
        )
    )
    image_page = info_payload.get("query", {}).get("pages", [{}])[0]
    image_info = (image_page.get("imageinfo") or [{}])[0]
    image_url = image_info.get("thumburl") or image_info.get("url")
    if not image_url:
        return None
    return {
        "provider": "wikipedia",
        "page_title": page["title"],
        "page_url": page.get("fullurl"),
        "page_match_score": page["match_score"],
        "image_title": image_title,
        "image_score": round(score, 2),
        "image_url": image_url,
        "original_url": image_info.get("url"),
        "mime": image_info.get("mime"),
    }


def sports_db_candidate(team_name: str) -> dict | None:
    payload = fetch_json(api_url(SPORTS_DB_API, {"t": team_name}))
    teams = [team for team in (payload.get("teams") or []) if team.get("strSport") == "Soccer"]
    ranked = []
    for team in teams:
        names = [team.get("strTeam") or "", team.get("strTeamAlternate") or ""]
        score = max(similarity(team_name, candidate) for candidate in names)
        ranked.append((score, team))
    if not ranked:
        return None
    score, team = max(ranked, key=lambda item: item[0])
    if score < 0.78 or not team.get("strBadge"):
        return None
    return {
        "provider": "thesportsdb",
        "matched_name": team.get("strTeam"),
        "alternate_name": team.get("strTeamAlternate"),
        "match_score": round(score, 4),
        "team_id": team.get("idTeam"),
        "country": team.get("strCountry"),
        "league": team.get("strLeague"),
        "page_url": team.get("strWebsite"),
        "image_url": team.get("strBadge"),
    }


def research_wikipedia(team_name: str) -> tuple[str, dict | None, str | None]:
    try:
        result = wikipedia_candidate(team_name)
        time.sleep(0.2)
        return team_name, result, None
    except Exception as exc:
        return team_name, None, str(exc)


def download_and_convert(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    data = None
    content_type = ""
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                data = response.read()
                content_type = response.headers.get_content_type()
            break
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2 * (2**attempt))
    assert data is not None
    with tempfile.TemporaryDirectory(prefix="top-scores-team-logo-") as temp_dir:
        suffix = {
            "image/jpeg": ".jpg",
            "image/png": ".png",
            "image/svg+xml": ".svg",
            "image/webp": ".webp",
        }.get(content_type, ".img")
        source = Path(temp_dir) / f"source{suffix}"
        source.write_bytes(data)
        subprocess.run(
            [
                "magick", str(source), "-background", "none", "-resize", "512x512>",
                "-strip", f"PNG32:{destination}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )


def install_candidates(
    research_path: Path,
    asset_catalog: Path,
    manifests: list[Path],
    sources_output: Path,
) -> int:
    records = json.loads(research_path.read_text(encoding="utf-8"))
    installed_names = []
    source_records = []
    contents = {
        "images": [
            {"filename": "logo.png", "idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }

    missing_candidates = [
        record["team_name"]
        for record in records
        if not Path(record.get("candidate_path", "")).is_file()
    ]
    existing_assets = [
        record["team_name"]
        for record in records
        if (asset_catalog / f'{record["team_name"]}.imageset').exists()
    ]
    if missing_candidates:
        raise RuntimeError(f"Missing reviewed candidates: {missing_candidates}")
    if existing_assets:
        raise RuntimeError(f"Refusing to overwrite existing assets: {existing_assets}")

    for record in records:
        team_name = record["team_name"]
        candidate_path = Path(record.get("candidate_path", ""))
        if not candidate_path.is_file():
            raise RuntimeError(f"Missing reviewed candidate for {team_name}: {candidate_path}")
        destination = asset_catalog / f"{team_name}.imageset"
        destination.mkdir(parents=True)
        shutil.copyfile(candidate_path, destination / "logo.png")
        (destination / "Contents.json").write_text(
            json.dumps(contents, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        installed_names.append(team_name)

        selected = record.get("manual")
        if not selected:
            provider_key = record.get("selected_provider")
            selected = record.get(provider_key) if provider_key else None
        selected = selected or record.get("wikipedia") or record.get("thesportsdb") or {}
        source_records.append(
            {
                "asset_name": team_name,
                "provider": selected.get("provider", record.get("selected_provider")),
                "page_url": selected.get("page_url"),
                "image_url": selected.get("image_url"),
            }
        )

    merged_names = []
    for manifest in manifests:
        for name in json.loads(manifest.read_text(encoding="utf-8")):
            if name not in merged_names:
                merged_names.append(name)
    for name in sorted(installed_names, key=lambda value: value.casefold()):
        if name not in merged_names:
            merged_names.append(name)
    manifest_payload = json.dumps(merged_names, ensure_ascii=False, indent=2) + "\n"
    for manifest in manifests:
        manifest.write_text(manifest_payload, encoding="utf-8")

    sources_output.write_text(
        json.dumps(source_records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({"installed": len(installed_names), "manifest_total": len(merged_names)}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--candidates-dir", type=Path)
    parser.add_argument("--skip-sportsdb", action="store_true")
    parser.add_argument("--install-from", type=Path)
    parser.add_argument("--asset-catalog", type=Path)
    parser.add_argument("--manifest", action="append", type=Path, default=[])
    parser.add_argument("--sources-output", type=Path)
    args = parser.parse_args()

    if args.install_from:
        if not args.asset_catalog or not args.manifest or not args.sources_output:
            parser.error("--install-from requires --asset-catalog, --manifest, and --sources-output")
        return install_candidates(
            args.install_from,
            args.asset_catalog,
            args.manifest,
            args.sources_output,
        )
    if not args.output or not args.candidates_dir:
        parser.error("research mode requires --output and --candidates-dir")

    team_names = fetch_json(AUDIT_URL)
    args.candidates_dir.mkdir(parents=True, exist_ok=True)
    records: dict[str, dict] = {name: {"team_name": name} for name in team_names}

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        for team_name, candidate, error in executor.map(research_wikipedia, team_names):
            records[team_name]["wikipedia"] = candidate
            if error:
                records[team_name]["wikipedia_error"] = error

    if not args.skip_sportsdb:
        unresolved = [
            name
            for name in team_names
            if not records[name].get("wikipedia") and name not in MANUAL_OVERRIDES
        ]
        for index, team_name in enumerate(unresolved):
            try:
                records[team_name]["thesportsdb"] = sports_db_candidate(team_name)
            except Exception as exc:
                records[team_name]["thesportsdb_error"] = str(exc)
            if index + 1 < len(unresolved):
                time.sleep(2.1)

    for index, team_name in enumerate(team_names, start=1):
        record = records[team_name]
        if team_name in MANUAL_OVERRIDES:
            record["manual"] = MANUAL_OVERRIDES[team_name]
        candidate = record.get("manual") or record.get("wikipedia") or record.get("thesportsdb")
        if not candidate:
            continue
        destination = args.candidates_dir / f"{index:03d}.png"
        try:
            download_and_convert(candidate["image_url"], destination)
            record["candidate_path"] = str(destination)
            record["selected_provider"] = candidate["provider"]
        except Exception as exc:
            record["download_error"] = str(exc)
        if candidate["provider"] == "wikipedia":
            time.sleep(0.6)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(list(records.values()), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    resolved = sum(1 for record in records.values() if record.get("candidate_path"))
    print(json.dumps({"total": len(records), "candidates": resolved, "unresolved": len(records) - resolved}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
