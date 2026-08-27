#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager, nullcontext
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import requests
from openai import OpenAI
from PIL import Image, ImageOps
from pydantic import BaseModel, Field

from stadium_images.sources.wikimedia import license_allowed

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
MODEL = "gpt-5.6"
BITWARDEN_ITEM = "OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR"
BITWARDEN_FIELD = "Value"
KEYCHAIN_SERVICE = "dev.skynolimit.top-scores.image-collector"
COLLECTOR_DIR = Path(__file__).resolve().parent
DEFAULT_STAGING_ROOT = COLLECTOR_DIR / "staging"
MAX_DOWNLOAD_BYTES = 30 * 1024 * 1024
MAX_VISION_DOWNLOAD_BYTES = 10 * 1024 * 1024
VISION_MAX_SIDE = 1024
VISION_JPEG_QUALITY = 82
DEFAULT_WIKIMEDIA_CONCURRENCY = 2
DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS = 0.25
WIKIMEDIA_MAX_ATTEMPTS = 5
OPENAI_MAX_RETRIES = 4
USER_AGENT = "TopScoresStadiumResearch/1.0 (contact: mike.wagstaff@gmail.com)"


class RequestLimiter:
    def __init__(self, max_concurrency: int, min_interval_seconds: float) -> None:
        if max_concurrency < 1:
            raise ValueError("max_concurrency must be at least 1")
        if min_interval_seconds < 0:
            raise ValueError("min_interval_seconds cannot be negative")
        self._semaphore = threading.Semaphore(max_concurrency)
        self._schedule_lock = threading.Lock()
        self._next_start = 0.0
        self._min_interval_seconds = min_interval_seconds

    @contextmanager
    def slot(self):
        self._semaphore.acquire()
        try:
            with self._schedule_lock:
                now = time.monotonic()
                request_start = max(now, self._next_start)
                self._next_start = request_start + self._min_interval_seconds
            delay = request_start - now
            if delay > 0:
                time.sleep(delay)
            yield
        finally:
            self._semaphore.release()


_wikimedia_limiter = RequestLimiter(
    DEFAULT_WIKIMEDIA_CONCURRENCY,
    DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS,
)


def configure_wikimedia_requests(
    max_concurrency: int = DEFAULT_WIKIMEDIA_CONCURRENCY,
    min_interval_seconds: float = DEFAULT_WIKIMEDIA_MIN_INTERVAL_SECONDS,
) -> None:
    global _wikimedia_limiter
    _wikimedia_limiter = RequestLimiter(max_concurrency, min_interval_seconds)


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
    *,
    use_cached: bool = True,
) -> str:
    """Reuse an environment or Keychain key, falling back to Bitwarden."""

    environment_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if environment_key:
        return environment_key
    if use_cached:
        cached_key = _load_api_key_from_keychain(item_name)
        if cached_key:
            os.environ["OPENAI_API_KEY"] = cached_key
            return cached_key

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
            _store_api_key_in_keychain(item_name, value)
            return value
    raise RuntimeError(
        f"Bitwarden item '{item_name}' has no non-empty '{field_name}' field."
    )


def _load_api_key_from_keychain(item_name: str) -> str | None:
    if sys.platform != "darwin" or shutil.which("security") is None:
        return None
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-a",
            item_name,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def _store_api_key_in_keychain(item_name: str, value: str) -> None:
    if sys.platform != "darwin" or shutil.which("security") is None:
        return
    result = subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-a",
            item_name,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
            value,
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "unknown Keychain error"
        print(f"Warning: could not cache the collector API key: {detail}")


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
    payload = _get_json(
        COMMONS_API,
        params=params,
        timeout=30,
    )

    results = []
    for page in payload.get("query", {}).get("pages", {}).values():
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


def build_queries(stadium: str, club: str | None = None) -> list[str]:
    context = " ".join(
        value.strip() for value in (stadium, club or "") if value.strip()
    )
    return [
        f"{context} football stadium interior",
        f"{context} stadium pitch",
        f"{context} football ground night",
        f"{context} stadium floodlights",
        f"{context} stadium panoramic",
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
    *,
    log_prefix: str = "",
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
    prepared_images = _prepare_vision_images(images, log_prefix=log_prefix)
    if not prepared_images:
        raise RuntimeError("No candidate thumbnails could be prepared for analysis.")
    for index, data_url in prepared_images:
        content.extend(
            [
                {"type": "input_text", "text": f"CANDIDATE {index}"},
                {
                    "type": "input_image",
                    "image_url": data_url,
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
    queries: list[str] | None = None,
    log_prefix: str = "",
) -> dict:
    prefix = f"{log_prefix} " if log_prefix else ""
    print(f"{prefix}Researching: {stadium}")
    all_images = []
    for query in queries or build_queries(stadium):
        print(f"{prefix}  Searching Commons: {query}")
        try:
            all_images.extend(search_commons(query, limit=per_query))
        except requests.RequestException as error:
            print(f"{prefix}  Search failed: {error}")

    images = basic_filter(dedupe(all_images))[:30]
    print(f"{prefix}  {len(images)} usable candidates found.")
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

    print(f"{prefix}  Sending candidates to GPT-5.6 for visual analysis...")
    analysis = score_images(stadium, images, client, log_prefix=log_prefix)
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
    data = _download_bytes(
        url,
        session=session,
        timeout=60,
        max_bytes=MAX_DOWNLOAD_BYTES,
        size_error="image exceeds the 30 MB staging limit",
    )

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


def _prepare_vision_images(
    images: list[dict],
    *,
    log_prefix: str = "",
) -> list[tuple[int, str]]:
    prefix = f"{log_prefix} " if log_prefix else ""
    session = requests.Session()
    prepared = []
    for index, image in enumerate(images):
        try:
            prepared.append(
                (index, _vision_data_url(image["thumbnail_url"], session=session))
            )
        except (OSError, ValueError, requests.RequestException) as error:
            print(f"{prefix}  Candidate {index} thumbnail skipped: {error}")
    return prepared


def _vision_data_url(url: str, *, session: requests.Session) -> str:
    data = _download_bytes(
        url,
        session=session,
        timeout=45,
        max_bytes=MAX_VISION_DOWNLOAD_BYTES,
        size_error="thumbnail exceeds the 10 MB analysis limit",
    )
    try:
        with Image.open(BytesIO(data)) as source:
            image = ImageOps.exif_transpose(source)
            image.thumbnail(
                (VISION_MAX_SIDE, VISION_MAX_SIDE),
                Image.Resampling.LANCZOS,
            )
            if image.mode in {"RGBA", "LA"} or (
                image.mode == "P" and "transparency" in image.info
            ):
                rgba = image.convert("RGBA")
                rgb = Image.new("RGB", rgba.size, "white")
                rgb.paste(rgba, mask=rgba.getchannel("A"))
            else:
                rgb = image.convert("RGB")
            output = BytesIO()
            rgb.save(
                output,
                format="JPEG",
                quality=VISION_JPEG_QUALITY,
                optimize=True,
            )
    except (OSError, ValueError) as error:
        raise ValueError("thumbnail is not a supported raster image") from error
    encoded = base64.b64encode(output.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{encoded}"


def _get_json(
    url: str,
    *,
    params: dict,
    timeout: int,
    session: requests.Session | None = None,
) -> dict:
    request_session = session or requests
    for attempt in range(WIKIMEDIA_MAX_ATTEMPTS):
        try:
            with _request_slot(url):
                response = request_session.get(
                    url,
                    params=params,
                    headers={"User-Agent": USER_AGENT},
                    timeout=timeout,
                )
                response.raise_for_status()
                return response.json()
        except requests.RequestException as error:
            if not _retry_request(error, attempt):
                raise
    raise AssertionError("unreachable")


def _download_bytes(
    url: str,
    *,
    session: requests.Session,
    timeout: int,
    max_bytes: int,
    size_error: str,
) -> bytes:
    for attempt in range(WIKIMEDIA_MAX_ATTEMPTS):
        response = None
        try:
            with _request_slot(url):
                response = session.get(
                    url,
                    headers={"User-Agent": USER_AGENT},
                    timeout=timeout,
                    stream=True,
                )
                response.raise_for_status()
                content_length = int(response.headers.get("Content-Length") or 0)
                if content_length > max_bytes:
                    raise ValueError(size_error)

                chunks = []
                byte_count = 0
                for chunk in response.iter_content(chunk_size=128 * 1024):
                    if not chunk:
                        continue
                    byte_count += len(chunk)
                    if byte_count > max_bytes:
                        raise ValueError(size_error)
                    chunks.append(chunk)
                data = b"".join(chunks)
                if not data:
                    raise ValueError("downloaded image is empty")
                return data
        except requests.RequestException as error:
            if not _retry_request(error, attempt):
                raise
        finally:
            if response is not None:
                close = getattr(response, "close", None)
                if close is not None:
                    close()
    raise AssertionError("unreachable")


def _request_slot(url: str):
    hostname = (urlparse(url).hostname or "").casefold()
    if hostname == "wikimedia.org" or hostname.endswith(".wikimedia.org"):
        return _wikimedia_limiter.slot()
    return nullcontext()


def _retry_request(error: requests.RequestException, attempt: int) -> bool:
    if attempt >= WIKIMEDIA_MAX_ATTEMPTS - 1:
        return False
    response = getattr(error, "response", None)
    status_code = getattr(response, "status_code", None)
    if status_code is not None and status_code not in {408, 429, 500, 502, 503, 504}:
        return False
    retry_after = 0.0
    if response is not None:
        try:
            retry_after = float(response.headers.get("Retry-After") or 0)
        except ValueError:
            retry_after = 0.0
    time.sleep(max(retry_after, 1.0 * (2**attempt)))
    return True


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
    parser.add_argument(
        "--refresh-api-key",
        action="store_true",
        help="Ignore the cached Keychain value and reload it from Bitwarden",
    )
    args = parser.parse_args()
    if args.wikimedia_concurrency < 1:
        parser.error("--wikimedia-concurrency must be at least 1")
    if args.wikimedia_min_interval < 0:
        parser.error("--wikimedia-min-interval cannot be negative")
    configure_wikimedia_requests(
        args.wikimedia_concurrency,
        args.wikimedia_min_interval,
    )

    api_key = load_openai_api_key(
        args.bitwarden_item,
        use_cached=not args.refresh_api_key,
    )
    result = research_stadium(
        args.stadium,
        OpenAI(api_key=api_key, max_retries=OPENAI_MAX_RETRIES),
        per_query=args.per_query,
        queries=build_queries(args.stadium, args.club),
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
