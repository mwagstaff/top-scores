#!/usr/bin/env python3
"""
Fetch missing team logos.

- Pulls team names from: http://localhost:3000/api/v1/audit/missing-team-logos
- Fetches logos in parallel (default 20 workers; configurable via MAX_WORKERS env var)
- Tries hard to get an actual crest/logo (not a random lead photo) by:
    1) searching Wikipedia with a football-biased query
    2) resolving the page's Wikidata QID
    3) preferring Wikidata P154 (logo image), falling back to P18 (image)
    4) turning the Commons filename into a direct download URL

- Saves files to ./logos with filenames matching the team names EXACTLY (minus extension),
  only replacing characters that would break filesystem paths.

Requires: requests
"""

import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import quote

import requests

AUDIT_URL = "http://localhost:3000/api/v1/audit/missing-team-logos"
OUT_DIR = "logos"
TIMEOUT_SECS = 10

# Parallelism (easy to configure)
MAX_WORKERS = int(os.getenv("MAX_WORKERS", "20"))


# --- Filename handling --------------------------------------------------------

def safe_filename(name: str) -> str:
    """
    Preserve the team name EXACTLY as returned by the audit JSON list,
    only removing/replacing characters that would break filenames/paths.
    """
    return (
        name.strip()
        .replace("/", "-")   # avoid creating subdirectories
        .replace(":", "-")   # awkward across filesystems/tools
    )


# --- Audit endpoint parsing ---------------------------------------------------

def fetch_missing_teams() -> list[str]:
    r = requests.get(AUDIT_URL, timeout=TIMEOUT_SECS)
    r.raise_for_status()
    data = r.json()

    if isinstance(data, list):
        if all(isinstance(x, str) for x in data):
            return [x.strip() for x in data if x and x.strip()]
        if all(isinstance(x, dict) for x in data):
            out: list[str] = []
            for obj in data:
                for key in ("team", "name", "displayName", "teamName", "label", "value"):
                    v = obj.get(key)
                    if isinstance(v, str) and v.strip():
                        out.append(v.strip())
                        break
            return out

    if isinstance(data, dict):
        for key in ("teams", "missing", "missingTeams", "data", "results"):
            v = data.get(key)
            if isinstance(v, list):
                if all(isinstance(x, str) for x in v):
                    return [x.strip() for x in v if x and x.strip()]
                if all(isinstance(x, dict) for x in v):
                    out: list[str] = []
                    for obj in v:
                        for k2 in ("team", "name", "displayName", "teamName", "label", "value"):
                            vv = obj.get(k2)
                            if isinstance(vv, str) and vv.strip():
                                out.append(vv.strip())
                                break
                    return out

    raise ValueError(f"Unexpected JSON shape from {AUDIT_URL}: {type(data)}")


# --- Wikipedia/Wikidata/Commons helpers --------------------------------------

def wikipedia_search_titles(query: str, limit: int = 5) -> list[str]:
    api = "https://en.wikipedia.org/w/api.php"
    params = {
        "action": "query",
        "list": "search",
        "srsearch": query,
        "format": "json",
        "utf8": 1,
        "srlimit": limit,
    }
    r = requests.get(api, params=params, timeout=TIMEOUT_SECS, headers={"User-Agent": "logo-fetcher/1.0"})
    if r.status_code != 200:
        return []
    hits = r.json().get("query", {}).get("search", []) or []
    titles: list[str] = []
    for h in hits:
        t = h.get("title")
        if isinstance(t, str) and t.strip():
            titles.append(t.strip())
    return titles


def choose_best_wikipedia_title(team: str) -> str | None:
    candidates: list[str] = []

    candidates += wikipedia_search_titles(f'{team} football club', 5)
    candidates += wikipedia_search_titles(f'{team} F.C.', 5)
    candidates += wikipedia_search_titles(f'{team} FC', 5)

    candidates += wikipedia_search_titles(f'{team} national football team', 5)
    candidates += wikipedia_search_titles(f'{team} national team football', 5)

    if not candidates:
        candidates = wikipedia_search_titles(team, 5)

    if not candidates:
        return None

    team_l = team.lower()
    preferred_keywords = (
        "f.c", "fc", "football club", "a.f.c", "c.f", "s.c", "sv", "ac", "sk",
        "national football team", "national team",
    )

    def score(title: str) -> int:
        t = title.lower()
        s = 0
        if team_l in t:
            s += 5
        for kw in preferred_keywords:
            if kw in t:
                s += 5
        if "city" in t or "town" in t or "province" in t:
            s -= 3
        return s

    candidates_sorted = sorted(dict.fromkeys(candidates), key=score, reverse=True)
    return candidates_sorted[0]


def wikipedia_title_to_qid(title: str) -> str | None:
    api = "https://en.wikipedia.org/w/api.php"
    params = {
        "action": "query",
        "prop": "pageprops",
        "titles": title,
        "format": "json",
        "utf8": 1,
    }
    r = requests.get(api, params=params, timeout=TIMEOUT_SECS, headers={"User-Agent": "logo-fetcher/1.0"})
    if r.status_code != 200:
        return None
    pages = r.json().get("query", {}).get("pages", {}) or {}
    for _, page in pages.items():
        qid = (page.get("pageprops") or {}).get("wikibase_item")
        if isinstance(qid, str) and qid.startswith("Q"):
            return qid
    return None


def wikidata_first_commons_filename(qid: str, prop: str) -> str | None:
    url = f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"
    r = requests.get(url, timeout=TIMEOUT_SECS, headers={"User-Agent": "logo-fetcher/1.0"})
    if r.status_code != 200:
        return None
    entity = (r.json().get("entities") or {}).get(qid) or {}
    claims = entity.get("claims") or {}
    prop_claims = claims.get(prop) or []
    if not prop_claims:
        return None
    mainsnak = (prop_claims[0].get("mainsnak") or {})
    dv = ((mainsnak.get("datavalue") or {}).get("value"))
    return dv if isinstance(dv, str) and dv.strip() else None


def wikidata_logo_or_image_filename(qid: str) -> str | None:
    return (
        wikidata_first_commons_filename(qid, "P154")
        or wikidata_first_commons_filename(qid, "P18")
    )


def commons_file_url(filename: str) -> str | None:
    api = "https://commons.wikimedia.org/w/api.php"
    params = {
        "action": "query",
        "prop": "imageinfo",
        "titles": f"File:{filename}",
        "iiprop": "url",
        "format": "json",
        "utf8": 1,
    }
    r = requests.get(api, params=params, timeout=TIMEOUT_SECS, headers={"User-Agent": "logo-fetcher/1.0"})
    if r.status_code != 200:
        return None
    pages = r.json().get("query", {}).get("pages", {}) or {}
    for _, page in pages.items():
        ii = (page.get("imageinfo") or [])
        if not ii:
            continue
        u = ii[0].get("url")
        if isinstance(u, str) and u.strip():
            return u
    return None


def wikipedia_summary_thumbnail(title: str) -> str | None:
    url = f"https://en.wikipedia.org/api/rest_v1/page/summary/{quote(title)}"
    r = requests.get(url, timeout=TIMEOUT_SECS, headers={"User-Agent": "logo-fetcher/1.0"})
    if r.status_code != 200:
        return None
    data = r.json()
    thumb = (data.get("thumbnail") or {}).get("source")
    return thumb if isinstance(thumb, str) and thumb.strip() else None


def get_logo_url(team: str) -> tuple[str | None, str | None]:
    title = choose_best_wikipedia_title(team) or team

    qid = wikipedia_title_to_qid(title)
    if qid:
        fn = wikidata_logo_or_image_filename(qid)
        if fn:
            url = commons_file_url(fn)
            if url:
                return url, title

    return wikipedia_summary_thumbnail(title), title


def download(url: str) -> bytes:
    r = requests.get(url, timeout=TIMEOUT_SECS, headers={"User-Agent": "logo-fetcher/1.0"})
    r.raise_for_status()
    return r.content


# --- Parallel worker ----------------------------------------------------------

def process_team(team: str) -> tuple[str, str, str]:
    """
    Returns (status, team, message)
    status: "saved" | "skipped" | "not_found" | "download_failed"
    """
    team = (team or "").strip()
    if not team:
        return "not_found", team, "empty team name"

    filename = safe_filename(team) + ".png"
    path = os.path.join(OUT_DIR, filename)

    if os.path.exists(path):
        return "skipped", team, f"Exists: {path}"

    url, title_used = get_logo_url(team)
    if not url:
        return "not_found", team, f"No logo URL (title tried: {title_used})"

    try:
        blob = download(url)
    except Exception as e:
        return "download_failed", team, f"Download failed: {e} (url: {url})"

    with open(path, "wb") as f:
        f.write(blob)

    return "saved", team, f"Saved {path} (from: {title_used})"


# --- Main --------------------------------------------------------------------

def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)

    try:
        teams = fetch_missing_teams()
    except Exception as e:
        print(f"❌ Failed to fetch teams from audit endpoint: {e}", file=sys.stderr)
        return 1

    teams = [t for t in teams if t.strip().upper() not in ("TBC", "TBD", "UNKNOWN", "N/A")]

    if not teams:
        print("✅ No missing teams returned.")
        return 0

    print(f"Found {len(teams)} missing teams")
    print(f"Using MAX_WORKERS={MAX_WORKERS}\n")

    counts = {"saved": 0, "skipped": 0, "not_found": 0, "download_failed": 0}

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futures = [ex.submit(process_team, t) for t in teams]

        for fut in as_completed(futures):
            status, team, msg = fut.result()
            counts[status] += 1

            prefix = {
                "saved": "✅",
                "skipped": "↩️ ",
                "not_found": "❌",
                "download_failed": "⚠️ ",
            }.get(status, "•")

            print(f"{prefix} {team}: {msg}")

    print(
        f"\nDone. Saved={counts['saved']}, skipped_existing={counts['skipped']}, "
        f"not_found={counts['not_found']}, download_failed={counts['download_failed']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())