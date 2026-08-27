#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import requests
from openai import OpenAI
from PIL import Image
from pydantic import BaseModel, Field

from stadium_images.sources.wikimedia import license_allowed

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
MODEL = "gpt-5.6"
BITWARDEN_ITEM = "OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR"
BITWARDEN_FIELD = "Value"
COLLECTOR_DIR = Path(__file__).resolve().parent
DEFAULT_STAGING_ROOT = COLLECTOR_DIR / "staging"
MAX_DOWNLOAD_BYTES = 30 * 1024 * 1024
USER_AGENT = "TopScoresStadiumResearch/1.0 (contact: mike.wagstaff@gmail.com)"


class ImageAssessment(BaseModel):
    index: int = Field(ge=0)
    score: int = Field(ge=0, le=100)
    venue_confidence: int = Field(ge=0, le=100)
    composition: int = Field(ge=0, le=100)
    ui_suitability: int = Field(ge=0, le=100)
    lighting: Literal["day", "dusk", "night", "indoor", "unknown"]
    shot_type: str
    suitable: bool
    reason: str


class StadiumAssessment(BaseModel):
    assessments: list[ImageAssessment]
    summary: str


def load_openai_api_key(
    item_name: str = BITWARDEN_ITEM,
    field_name: str = BITWARDEN_FIELD,
) -> str:
    """Reuse an environment key or load it from a Bitwarden custom field."""

    environment_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if environment_key:
        return environment_key

    if shutil.which("bw") is None:
        raise RuntimeError("Bitwarden CLI 'bw' is required and was not found in PATH.")

    command_environment = os.environ.copy()
    session = command_environment.get("BW_SESSION", "").strip()
    item_result = None
    if session:
        try:
            item_result = _run_bw(["get", "item", item_name], command_environment)
        except RuntimeError:
            session = ""
            command_environment.pop("BW_SESSION", None)

    if item_result is None:
        status = _run_bw(["status"], command_environment)
        try:
            vault_status = json.loads(status.stdout).get("status")
        except json.JSONDecodeError as error:
            raise RuntimeError("Bitwarden returned an invalid vault status.") from error
        if vault_status == "unauthenticated":
            raise RuntimeError(
                "Bitwarden is not logged in. Run 'bw login' and try again."
            )
        if vault_status == "locked":
            unlocked = _run_bw(["unlock", "--raw"], command_environment)
            session = unlocked.stdout.strip()
            if not session:
                raise RuntimeError("Bitwarden did not return an unlocked session.")
            command_environment["BW_SESSION"] = session
        if session:
            _run_bw(["sync"], command_environment)
        item_result = _run_bw(["get", "item", item_name], command_environment)
    try:
        item = json.loads(item_result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"Bitwarden item '{item_name}' was not valid JSON."
        ) from error

    wanted_name = field_name.casefold()
    for field in item.get("fields") or []:
        if str(field.get("name") or "").strip().casefold() != wanted_name:
            continue
        value = str(field.get("value") or "").strip()
        if value:
            os.environ["OPENAI_API_KEY"] = value
            return value
    raise RuntimeError(
        f"Bitwarden item '{item_name}' has no non-empty '{field_name}' field."
    )


def _run_bw(
    arguments: list[str], environment: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    is_unlock = bool(arguments and arguments[0] == "unlock")
    command = ["bw", *arguments]
    if not is_unlock:
        command.insert(1, "--nointeraction")
    try:
        return subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=None if is_unlock else subprocess.PIPE,
            text=True,
            env=environment,
        )
    except subprocess.CalledProcessError as error:
        action = " ".join(arguments[:2])
        detail = (error.stderr or "").strip()
        if detail:
            raise RuntimeError(f"Bitwarden '{action}' failed: {detail}") from None
        raise RuntimeError(
            f"Bitwarden '{action}' failed with no error detail."
        ) from None


def search_commons(query: str, limit: int = 20) -> list[dict]:
    """Search Wikimedia Commons for image candidates."""

    params = {
        "action": "query",
        "generator": "search",
        "gsrsearch": query,
        "gsrnamespace": 6,
        "gsrlimit": limit,
        "prop": "imageinfo",
        "iiprop": "url|extmetadata|size",
        "iiurlwidth": 1600,
        "format": "json",
    }
    response = requests.get(
        COMMONS_API,
        params=params,
        headers={"User-Agent": USER_AGENT},
        timeout=30,
    )
    response.raise_for_status()

    results = []
    for page in response.json().get("query", {}).get("pages", {}).values():
        info_list = page.get("imageinfo", [])
        if not info_list:
            continue
        info = info_list[0]
        metadata = info.get("extmetadata", {})
        results.append(
            {
                "title": page.get("title"),
                "thumbnail_url": info.get("thumburl") or info.get("url"),
                "original_url": info.get("url"),
                "width": info.get("width"),
                "height": info.get("height"),
                "artist": metadata.get("Artist", {}).get("value"),
                "license": metadata.get("LicenseShortName", {}).get("value"),
                "license_url": metadata.get("LicenseUrl", {}).get("value"),
                "credit": metadata.get("Credit", {}).get("value"),
                "description": metadata.get("ImageDescription", {}).get("value"),
                "commons_page": info.get("descriptionurl"),
            }
        )
    return results


def build_queries(stadium: str) -> list[str]:
    return [
        f"{stadium} football stadium interior",
        f"{stadium} stadium pitch",
        f"{stadium} football ground night",
        f"{stadium} stadium floodlights",
        f"{stadium} stadium panoramic",
    ]


def dedupe(images: list[dict]) -> list[dict]:
    seen = set()
    result = []
    for image in images:
        url = image.get("original_url")
        if not url or url in seen:
            continue
        seen.add(url)
        result.append(image)
    return result


def basic_filter(images: list[dict]) -> list[dict]:
    """Remove obviously unsuitable images before spending vision tokens."""

    result = []
    for image in images:
        width = image.get("width") or 0
        height = image.get("height") or 0
        license_name = str(image.get("license") or "")
        if width < 1200 or width <= height or not license_allowed(license_name):
            continue
        result.append(image)
    return result


def score_images(
    stadium: str,
    images: list[dict],
    client: OpenAI,
) -> StadiumAssessment:
    """Ask GPT-5.6 to inspect every candidate and return structured scores."""

    content: list[dict] = [
        {
            "type": "input_text",
            "text": f"""
You are selecting photography for a premium iPhone football scores app called
Top Scores. The requested venue is {stadium}.

Evaluate every candidate. Set suitable=true only when the image is confidently
the requested venue and is genuinely suitable as a wide match-details hero.
Prioritise identifiable architecture, a visible pitch, cinematic landscape
composition, good day or floodlit atmosphere, room for UI overlays, and strong
perceived resolution. Penalise exterior-only views, foreground obstruction,
spectator or player close-ups, poor lighting, distortion, dominant advertising,
uncertain identity, and mediocre photography. Be strict: mediocre images score
below 60. Return exactly one assessment for every supplied candidate index.
""".strip(),
        }
    ]
    for index, image in enumerate(images):
        content.extend(
            [
                {"type": "input_text", "text": f"CANDIDATE {index}"},
                {
                    "type": "input_image",
                    "image_url": image["thumbnail_url"],
                    "detail": "high",
                },
            ]
        )

    response = client.responses.parse(
        model=MODEL,
        input=[{"role": "user", "content": content}],
        text_format=StadiumAssessment,
    )
    if response.output_parsed is None:
        raise RuntimeError("OpenAI returned no structured stadium assessment.")
    return response.output_parsed


def research_stadium(
    stadium: str,
    client: OpenAI,
    per_query: int = 10,
) -> dict:
    print(f"Researching: {stadium}")
    all_images = []
    for query in build_queries(stadium):
        print(f"  Searching Commons: {query}")
        try:
            all_images.extend(search_commons(query, limit=per_query))
        except requests.RequestException as error:
            print(f"  Search failed: {error}")

    images = basic_filter(dedupe(all_images))[:30]
    print(f"  {len(images)} usable candidates found.")
    if not images:
        return {
            "stadium": stadium,
            "candidate_count": 0,
            "images": [],
            "analysis": StadiumAssessment(
                assessments=[],
                summary="No suitable candidates found.",
            ).model_dump(),
        }

    print("  Sending candidates to GPT-5.6 for visual analysis...")
    analysis = score_images(stadium, images, client)
    return {
        "stadium": stadium,
        "candidate_count": len(images),
        "images": images,
        "analysis": analysis.model_dump(),
    }


def stage_suitable_images(
    result: dict,
    *,
    staging_root: Path,
    slug: str,
    min_score: int = 70,
    max_downloads: int = 10,
    replace: bool = False,
    teams: list[dict] | None = None,
    session: requests.Session | None = None,
) -> Path:
    destination = staging_root / slug
    if destination.exists() and not replace:
        raise FileExistsError(
            f"Staging directory already exists: {destination}. "
            "Review it, or rerun with --replace."
        )

    assessments = [
        ImageAssessment.model_validate(value)
        for value in result["analysis"]["assessments"]
    ]
    selected = sorted(
        (
            assessment
            for assessment in assessments
            if assessment.suitable and assessment.score >= min_score
        ),
        key=lambda assessment: (-assessment.score, assessment.index),
    )[:max_downloads]

    staging_root.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{slug}-", dir=staging_root))
    download_session = session or requests.Session()
    staged_images = []
    download_errors = []
    try:
        for rank, assessment in enumerate(selected, start=1):
            if assessment.index >= len(result["images"]):
                download_errors.append(
                    {
                        "index": assessment.index,
                        "error": "assessment index is out of range",
                    }
                )
                continue
            image_metadata = result["images"][assessment.index]
            try:
                data, extension = _download_image(
                    image_metadata["original_url"],
                    download_session,
                )
            except (OSError, ValueError, requests.RequestException) as error:
                download_errors.append({"index": assessment.index, "error": str(error)})
                print(f"  Download failed for candidate {assessment.index}: {error}")
                continue

            content_hash = hashlib.sha256(data).hexdigest()
            filename = (
                f"{rank:02d}-{assessment.score:03d}-{content_hash[:10]}.{extension}"
            )
            (temporary / filename).write_bytes(data)
            staged_images.append(
                {
                    "filename": filename,
                    "sha256": content_hash,
                    "byte_size": len(data),
                    "assessment": assessment.model_dump(),
                    "source": image_metadata,
                }
            )

        manifest = {
            "schema_version": 1,
            "generated_at": datetime.now(UTC).isoformat(),
            "stadium": result["stadium"],
            "slug": slug,
            "teams": teams or [],
            "candidate_count": result.get(
                "candidate_count", len(result.get("images", []))
            ),
            "minimum_score": min_score,
            "analysis_summary": result["analysis"]["summary"],
            "staged_images": staged_images,
            "download_errors": download_errors,
        }
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        _replace_directory(temporary, destination)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return destination


def _download_image(url: str, session: requests.Session) -> tuple[bytes, str]:
    response = session.get(
        url,
        headers={"User-Agent": USER_AGENT},
        timeout=60,
        stream=True,
    )
    response.raise_for_status()
    content_length = int(response.headers.get("Content-Length") or 0)
    if content_length > MAX_DOWNLOAD_BYTES:
        raise ValueError("image exceeds the 30 MB staging limit")

    chunks = []
    byte_count = 0
    for chunk in response.iter_content(chunk_size=128 * 1024):
        if not chunk:
            continue
        byte_count += len(chunk)
        if byte_count > MAX_DOWNLOAD_BYTES:
            raise ValueError("image exceeds the 30 MB staging limit")
        chunks.append(chunk)
    data = b"".join(chunks)
    if not data:
        raise ValueError("downloaded image is empty")

    from io import BytesIO

    try:
        with Image.open(BytesIO(data)) as image:
            image.verify()
            image_format = str(image.format or "").upper()
    except (OSError, ValueError) as error:
        raise ValueError("download is not a supported raster image") from error
    extension = {
        "JPEG": "jpg",
        "PNG": "png",
        "WEBP": "webp",
        "TIFF": "tif",
    }.get(image_format)
    if extension is None:
        raise ValueError(f"unsupported image format: {image_format or 'unknown'}")
    return data, extension


def _replace_directory(temporary: Path, destination: Path) -> None:
    backup = destination.parent / f".{destination.name}.previous"
    shutil.rmtree(backup, ignore_errors=True)
    if destination.exists():
        os.replace(destination, backup)
    try:
        os.replace(temporary, destination)
    except Exception:
        if backup.exists() and not destination.exists():
            os.replace(backup, destination)
        raise
    shutil.rmtree(backup, ignore_errors=True)


def slugify(value: str) -> str:
    import re
    import unicodedata

    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", normalized.lower()).strip("-")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Find, score, and stage reviewable stadium images."
    )
    parser.add_argument("stadium", help='Stadium name, e.g. "Anfield"')
    parser.add_argument("--club", help="Club name used for the eventual app assignment")
    parser.add_argument("--slug", help="Stable staging directory name")
    parser.add_argument("--per-query", type=int, default=10)
    parser.add_argument("--min-score", type=int, default=70)
    parser.add_argument("--max-downloads", type=int, default=10)
    parser.add_argument("--staging-root", type=Path, default=DEFAULT_STAGING_ROOT)
    parser.add_argument(
        "--output", type=Path, help="Optional extra copy of the manifest"
    )
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--bitwarden-item", default=BITWARDEN_ITEM)
    args = parser.parse_args()

    api_key = load_openai_api_key(args.bitwarden_item)
    result = research_stadium(
        args.stadium,
        OpenAI(api_key=api_key),
        per_query=args.per_query,
    )
    team_name = args.club or args.stadium
    staging_directory = stage_suitable_images(
        result,
        staging_root=args.staging_root,
        slug=args.slug or slugify(args.stadium),
        min_score=args.min_score,
        max_downloads=args.max_downloads,
        replace=args.replace,
        teams=[{"name": team_name, "aliases": []}],
    )
    manifest_path = staging_directory / "manifest.json"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(manifest_path, args.output)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    print(f"\n{manifest['analysis_summary']}")
    print(f"Staged {len(manifest['staged_images'])} image(s) in {staging_directory}")


if __name__ == "__main__":
    main()
