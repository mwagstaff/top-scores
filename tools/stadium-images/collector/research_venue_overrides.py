#!/usr/bin/env python3

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import requests

from stadium_images.sources.wikimedia import license_allowed

WIKIDATA_API = "https://www.wikidata.org/w/api.php"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "TopScoresVenueImageResearch/1.0 (contact: mike.wagstaff@gmail.com)"
REQUEST_INTERVAL_SECONDS = 0.12

# BSD often stores a current sponsored name while Commons metadata retains the
# long-lived or municipal name. These aliases are only search evidence; every
# selected file still has to pass the identity and licence checks below.
SEARCH_ALIASES = {
    "117": ["Pafiako Stadium"],
    "132": ["Şükrü Saracoğlu Stadium", "Fenerbahçe Stadium"],
    "142": ["Doosan Arena", "Stadion města Plzně"],
    "186": ["Gürsel Aksel Stadyumu"],
    "192": ["Şenol Güneş Sports Complex", "Medical Park Arena"],
    "193": ["Kocaeli Stadium"],
    "239": ["Kybunpark", "Espenmoos"],
    "309": ["Panthessaliko Stadium"],
    "314": ["OPAP Arena", "Agia Sophia Stadium"],
    "354": ["Tehelné pole", "National Football Stadium Bratislava"],
    "355": ["Stadion Poznań", "Municipal Stadium Poznan"],
    "379": ["Camp d'Esports d'Aixovall"],
    "397": ["Turner Stadium"],
    "401": ["Białystok City Stadium", "Stadion Miejski Białystok"],
    "431": ["Ergilio Hato Stadium"],
    "513": ["Darius and Girėnas Stadium"],
    "534": ["NSC Olimpiyskiy", "Olympic Stadium Kyiv"],
    "782": ["ADO Den Haag Stadium", "Cars Jeans Stadion"],
    "791": ["Farum Park"],
    "799": ["Stadion Letná", "Generali Arena Prague"],
    "828": ["Randers Stadium", "AutoC Park Randers"],
    "863": ["Abbey Stadium Cambridge"],
    "884": ["Proact Stadium", "Technique Stadium Chesterfield"],
    "892": ["Sixfields Stadium"],
    "910": ["Estadi Nacional d'Andorra"],
    "1069": ["Mechatronik Arena"],
    "1168": ["Pankritio Stadium"],
    "1288": ["Viking Stadion"],
    "1499": ["Adjarabet Arena"],
    "1551": ["Víkingsvöllur"],
    "1553": ["LFF Training Centre Kaunas"],
    "1574": ["Erzgebirgsstadion"],
    "1580": ["Grünwalder Stadion"],
    "1745": ["Turkistan Arena Kazakhstan"],
    "1753": ["Stadio di Cornaredo"],
    "2657": ["Red Star Stadium Belgrade"],
    "2993": ["Brisbane Road", "Gaughan Group Stadium"],
}

# Files found during the second, manual source-page pass. They are used only
# for the exact BSD venue ID shown here and still go through Commons metadata,
# raster, dimension, and reusable-licence validation.
MANUAL_FILES = {
    "20": "England v Australia, Hill Dickinson Stadium, Liverpool (1st November 2025) 001.jpg",
    "117": "Pafos FC - Aris Limassol FC 25.02.2022.jpg",
    "125": "MCH Arena Herning.JPG",
    "141": "Groupama Arena Budapest.jpg",
    "147": "Leoforos stadium.jpg",
    "205": "TheDen2019.jpg",
    "239": "CH-SG-St. Gallen-Kybunpark - Borussia Dortmund vs Athletic Bilbao 001.jpg",
    "314": "AEK fans during the first match played in Agia Sophia Stadium.jpg",
    "376": "LocomotiveStadium.jpg",
    "379": "Estadi Comunal Vella.jpg",
    "431": "Stadion Ergilio Hato.jpg",
    "420": "Strandvallen entre.JPG",
    "442": "StadeFranceNationsLeague2018.jpg",
    "515": "National Football Stadium Minsk.jpg",
    "787": "Kooistadion2024.jpg",
    "861": "Vienna allianz stadion.jpg",
    "868": "Blundell Park, Grimsby Town Football Club, Cleethorpes, aerial 2024 - geograph.org.uk - 7839081.jpg",
    "869": "Prenton Park Panorama 1.jpg",
    "1067": "20210728 Ludwigsparkstadion.jpg",
    "1073": "Kaiserstuhlstadion Bahlingen 2.JPG",
    "1202": "S. Darius and S. Girėnas Stadium, Kaunas, May 2026.jpg",
    "1276": "Willem II Stadion - tribunes.jpg",
    "1237": "StadeFranceNationsLeague2018.jpg",
    "1551": "Vikingur vs Valur aug07.jpg",
    "1553": "NFA stade 2022a.jpg",
    "1557": "Inver Park, Larne (2) - geograph.org.uk - 2314266.jpg",
    "1569": "LNER Community Stadium (cropped).jpg",
    "1579": "Blick ins Stadion des SSV Jeddeloh (Edewecht, 2024).jpg",
    "1584": "Carl-benz-stadion.png",
    "1745": "Туркестан Арена.jpg",
    "2994": "Rapid Stadium opening, March 2022 (1).jpg",
}


@dataclass(frozen=True)
class Venue:
    id: str
    name: str
    city: str
    country: str


def normalized(value: str) -> str:
    ascii_value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    return " ".join(re.findall(r"[a-z0-9]+", ascii_value.casefold()))


def text_value(value: Any) -> str:
    if isinstance(value, dict):
        value = value.get("value")
    return html.unescape(re.sub(r"<[^>]+>", " ", str(value or ""))).strip()


class WikimediaClient:
    def __init__(self) -> None:
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": USER_AGENT})
        self._last_request = 0.0

    def get_json(self, url: str, params: dict[str, Any]) -> dict[str, Any]:
        delay = REQUEST_INTERVAL_SECONDS - (time.monotonic() - self._last_request)
        if delay > 0:
            time.sleep(delay)
        response = self.session.get(url, params=params, timeout=30)
        self._last_request = time.monotonic()
        response.raise_for_status()
        return response.json()

    def search_entities(self, query: str, limit: int = 10) -> list[dict[str, Any]]:
        payload = self.get_json(
            WIKIDATA_API,
            {
                "action": "wbsearchentities",
                "search": query,
                "language": "en",
                "uselang": "en",
                "type": "item",
                "limit": limit,
                "format": "json",
            },
        )
        return payload.get("search") or []

    def entities(self, ids: list[str]) -> list[dict[str, Any]]:
        if not ids:
            return []
        payload = self.get_json(
            WIKIDATA_API,
            {
                "action": "wbgetentities",
                "ids": "|".join(ids),
                "props": "claims|labels|descriptions|aliases",
                "languages": "en",
                "format": "json",
            },
        )
        entities = payload.get("entities") or {}
        return [entities[entity_id] for entity_id in ids if entity_id in entities]

    def commons_file(self, filename: str) -> dict[str, Any] | None:
        title = filename if filename.startswith("File:") else f"File:{filename}"
        payload = self.get_json(
            COMMONS_API,
            {
                "action": "query",
                "titles": title,
                "prop": "imageinfo",
                "iiprop": "url|extmetadata|size|mime",
                "iiurlwidth": 1600,
                "format": "json",
            },
        )
        for page in (payload.get("query", {}).get("pages") or {}).values():
            image_info = page.get("imageinfo") or []
            if image_info:
                return image_record(page.get("title") or title, image_info[0])
        return None

    def search_commons(self, query: str, limit: int = 20) -> list[dict[str, Any]]:
        payload = self.get_json(
            COMMONS_API,
            {
                "action": "query",
                "generator": "search",
                "gsrsearch": query,
                "gsrnamespace": 6,
                "gsrlimit": limit,
                "prop": "imageinfo",
                "iiprop": "url|extmetadata|size|mime",
                "iiurlwidth": 1600,
                "format": "json",
            },
        )
        records = []
        for page in (payload.get("query", {}).get("pages") or {}).values():
            image_info = page.get("imageinfo") or []
            if image_info:
                records.append(image_record(page.get("title") or "", image_info[0]))
        return records


def image_record(title: str, info: dict[str, Any]) -> dict[str, Any]:
    metadata = info.get("extmetadata") or {}
    return {
        "title": title,
        "image_url": info.get("thumburl") or info.get("url"),
        "source_page": info.get("descriptionurl"),
        "width": info.get("thumbwidth") or info.get("width"),
        "height": info.get("thumbheight") or info.get("height"),
        "original_width": info.get("width"),
        "original_height": info.get("height"),
        "mime": info.get("mime"),
        "author": text_value(metadata.get("Artist")),
        "credit": text_value(metadata.get("Credit")),
        "license": text_value(metadata.get("LicenseShortName")),
        "license_url": text_value(metadata.get("LicenseUrl")),
        "description": text_value(metadata.get("ImageDescription")),
    }


def image_is_usable(image: dict[str, Any]) -> bool:
    width = int(image.get("original_width") or image.get("width") or 0)
    height = int(image.get("original_height") or image.get("height") or 0)
    return (
        image.get("mime") in {"image/jpeg", "image/png", "image/webp"}
        and width >= 640
        and height >= 360
        and width / max(height, 1) >= 1.15
        and license_allowed(str(image.get("license") or ""))
        and bool(image.get("image_url"))
        and bool(image.get("source_page"))
    )


def manual_image_is_usable(image: dict[str, Any]) -> bool:
    width = int(image.get("original_width") or image.get("width") or 0)
    height = int(image.get("original_height") or image.get("height") or 0)
    return (
        image.get("mime") in {"image/jpeg", "image/png", "image/webp"}
        and width >= 500
        and height >= 300
        and width > height
        and license_allowed(str(image.get("license") or ""))
        and bool(image.get("image_url"))
        and bool(image.get("source_page"))
    )


def claim_filename(entity: dict[str, Any]) -> str | None:
    for claim in (entity.get("claims") or {}).get("P18") or []:
        value = (
            claim.get("mainsnak", {})
            .get("datavalue", {})
            .get("value")
        )
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def entity_text(entity: dict[str, Any]) -> str:
    pieces = []
    for group in ("labels", "descriptions", "aliases"):
        values = entity.get(group) or {}
        english = values.get("en")
        if isinstance(english, list):
            pieces.extend(text_value(value) for value in english)
        elif english:
            pieces.append(text_value(english))
    return " ".join(piece for piece in pieces if piece)


def entity_score(venue: Venue, entity: dict[str, Any], rank: int) -> float:
    search_names = [venue.name, *SEARCH_ALIASES.get(venue.id, [])]
    target = set(normalized(venue.name).split())
    city = set(normalized(venue.city).split())
    country = set(normalized(venue.country).split())
    text = normalized(entity_text(entity))
    words = set(text.split())
    overlap = len(target & words) / max(len(target), 1)
    score = overlap * 80
    if any(normalized(name) in text for name in search_names):
        score += 90
    if city and city <= words:
        score += 25
    if country and country <= words:
        score += 8
    if any(word in words for word in ("stadium", "ground", "arena", "stadion", "stade")):
        score += 35
    if "football" in words or "soccer" in words:
        score += 15
    if claim_filename(entity):
        score += 20
    return score - rank * 2


def commons_score(venue: Venue, image: dict[str, Any], rank: int) -> float:
    search_names = [venue.name, *SEARCH_ALIASES.get(venue.id, [])]
    target_scores = []
    city = set(normalized(venue.city).split())
    text = normalized(" ".join(
        [
            str(image.get("title") or ""),
            str(image.get("description") or ""),
        ]
    ))
    words = set(text.split())
    for name in search_names:
        target = set(normalized(name).split())
        overlap = len(target & words) / max(len(target), 1)
        target_scores.append(overlap * 100)
    score = max(target_scores, default=0)
    if any(normalized(name) in text for name in search_names):
        score += 80
    if city and city <= words:
        score += 20
    if any(word in words for word in ("stadium", "ground", "arena", "stadion", "stade")):
        score += 15
    return score - rank


def find_candidate(client: WikimediaClient, venue: Venue) -> dict[str, Any] | None:
    manual_filename = MANUAL_FILES.get(venue.id)
    if manual_filename:
        image = client.commons_file(manual_filename)
        if image and manual_image_is_usable(image):
            return {
                **image,
                "method": "manual_commons_review",
                "wikidata_id": None,
                "confidence_score": 300.0,
            }

    search_names = [venue.name, *SEARCH_ALIASES.get(venue.id, [])]
    search_queries = [f"{name} {venue.city}" for name in search_names]
    entity_ids: list[str] = []
    for query in search_queries:
        for result in client.search_entities(query):
            entity_id = str(result.get("id") or "")
            if entity_id and entity_id not in entity_ids:
                entity_ids.append(entity_id)
    entities = client.entities(entity_ids[:20])
    ranked_entities = sorted(
        enumerate(entities),
        key=lambda pair: entity_score(venue, pair[1], pair[0]),
        reverse=True,
    )
    for rank, entity in ranked_entities:
        score = entity_score(venue, entity, rank)
        if score < 105:
            continue
        filename = claim_filename(entity)
        if not filename:
            continue
        image = client.commons_file(filename)
        if image and image_is_usable(image):
            return {
                **image,
                "method": "wikidata_p18",
                "wikidata_id": entity.get("id"),
                "confidence_score": round(score, 1),
            }

    commons_candidates: list[dict[str, Any]] = []
    commons_queries = []
    for name in search_names:
        commons_queries.extend(
            [
                f'"{name}" {venue.city}',
                f"{name} {venue.city} football stadium",
            ]
        )
    for query in commons_queries:
        commons_candidates.extend(client.search_commons(query))
    unique_candidates = {candidate["source_page"]: candidate for candidate in commons_candidates}
    ranked_images = sorted(
        enumerate(unique_candidates.values()),
        key=lambda pair: commons_score(venue, pair[1], pair[0]),
        reverse=True,
    )
    for rank, image in ranked_images:
        score = commons_score(venue, image, rank)
        if score >= 105 and image_is_usable(image):
            return {
                **image,
                "method": "commons_search",
                "wikidata_id": None,
                "confidence_score": round(score, 1),
            }
    return None


def parse_venues(lines: list[str]) -> list[Venue]:
    venues = []
    for line in lines:
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 4 or not fields[0].isdigit():
            continue
        venues.append(Venue(*fields[:4]))
    return venues


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Find licensed Wikimedia replacements for BSD venue placeholders."
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    venues = parse_venues(sys.stdin.readlines())
    if args.limit is not None:
        venues = venues[: args.limit]
    if not venues:
        raise SystemExit("No tab-separated venue rows were provided on stdin.")

    client = WikimediaClient()
    resolved: dict[str, dict[str, Any]] = {}
    unresolved = []
    for index, venue in enumerate(venues, start=1):
        print(f"[{index}/{len(venues)}] {venue.id} {venue.name}", file=sys.stderr)
        try:
            candidate = find_candidate(client, venue)
        except requests.RequestException as error:
            print(f"  request failed: {error}", file=sys.stderr)
            candidate = None
        if candidate is None:
            unresolved.append(venue.__dict__)
            continue
        resolved[venue.id] = {
            "venue": venue.__dict__,
            **candidate,
        }

    payload = {
        "schema_version": 1,
        "resolved": resolved,
        "unresolved": unresolved,
    }
    args.output.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"Resolved {len(resolved)}/{len(venues)}; unresolved {len(unresolved)}. "
        f"Wrote {args.output}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
