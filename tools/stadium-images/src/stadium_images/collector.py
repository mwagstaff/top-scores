from __future__ import annotations

import hashlib
import json
from collections import Counter
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError
from rich.console import Console

from .database import StateDatabase
from .http import HTTPClient, HTTPError, RateLimitError
from .models import FilterConfig, ImageCandidate, ImageRecord, League, Stadium
from .output import OutputWriter, duplicate_preference, record_sort_key
from .processing.classifier import HeuristicImageClassifier, ImageClassifier
from .processing.dedupe import calculate_hashes, perceptual_distance
from .processing.scorer import (
    identity_confidence,
    obvious_text_rejection,
    score_candidate,
)
from .sources.base import ImageSource

PIPELINE_VERSION = 1
TERMINAL_STATUSES = {"accepted", "rejected", "duplicate", "not_retained", "superseded"}


class Collector:
    def __init__(
        self,
        *,
        output_dir: Path,
        database: StateDatabase,
        http: HTTPClient,
        sources: dict[str, ImageSource],
        classifier: ImageClassifier | None = None,
        console: Console | None = None,
    ) -> None:
        self.output_dir = output_dir
        self.database = database
        self.http = http
        self.sources = sources
        self.classifier = classifier or HeuristicImageClassifier()
        self.console = console or Console()

    def collect(
        self,
        league: League,
        stadiums: tuple[Stadium, ...],
        source_names: tuple[str, ...],
        *,
        min_score: float | None = None,
        retention_limit: int | None = None,
        results_per_query: int | None = None,
    ) -> None:
        filters = (
            replace(league.filters, min_score=min_score)
            if min_score is not None
            else league.filters
        )
        query_limit = results_per_query or league.results_per_query
        fingerprint = _fingerprint(filters, retention_limit, query_limit)

        available_sources: list[ImageSource] = []
        for source_name in source_names:
            source = self.sources.get(source_name)
            if source is None:
                raise ValueError(f"Unknown source {source_name!r}")
            if source.available:
                available_sources.append(source)
            else:
                self.console.print(
                    f"[yellow]WARNING:[/] {source_name} skipped because its API key is not set"
                )
        if not available_sources:
            raise ValueError("None of the requested image sources are available")

        writer = OutputWriter(self.output_dir, self.database)
        for stadium in stadiums:
            stats: Counter[str] = Counter()
            seen: set[tuple[str, str]] = set()
            for source in available_sources:
                source_rate_limited = False
                source_query_limit = getattr(source, "max_queries_per_stadium", None)
                queries = (
                    stadium.search_terms[:source_query_limit]
                    if source_query_limit is not None
                    else stadium.search_terms
                )
                for query in queries:
                    try:
                        candidates = source.search(stadium, query, query_limit)
                    except RateLimitError as error:
                        self._print_rate_limit(stadium, source, error)
                        stats["rate_limited"] += 1
                        source_rate_limited = True
                        break
                    except (HTTPError, OSError, ValueError) as error:
                        self.console.print(
                            f"[yellow]WARNING:[/] [{stadium.name}] {source.name} query {query!r} failed: {error}"
                        )
                        stats["search_errors"] += 1
                        continue
                    stats["discovered"] += len(candidates)
                    self.console.print(
                        f"[{stadium.name}] {source.name} search {query!r} returned {len(candidates)} results"
                    )
                    for candidate in candidates:
                        key = (candidate.source, candidate.source_id)
                        if key in seen:
                            stats["repeated_search_result"] += 1
                            continue
                        seen.add(key)
                        try:
                            self._process_candidate(
                                league,
                                stadium,
                                candidate,
                                source,
                                filters,
                                fingerprint,
                                stats,
                            )
                        except RateLimitError as error:
                            self._print_rate_limit(stadium, source, error)
                            stats["rate_limited"] += 1
                            source_rate_limited = True
                            break
                    if source_rate_limited:
                        break

            self._apply_retention(league, stadium, retention_limit, fingerprint, stats)
            records = writer.write_stadium(league, stadium)
            writer.write_global_files()
            self._print_summary(stadium, stats, records)

    def _process_candidate(
        self,
        league: League,
        stadium: Stadium,
        candidate: ImageCandidate,
        source: ImageSource,
        filters: FilterConfig,
        fingerprint: str,
        stats: Counter[str],
    ) -> None:
        if self.database.is_manually_rejected(
            league.slug,
            stadium.slug,
            candidate.source,
            candidate.source_id,
        ):
            stats["manual_rejection"] += 1
            return
        status = self.database.candidate_status(
            league.slug,
            stadium.slug,
            candidate.source,
            candidate.source_id,
            fingerprint,
        )
        if status in TERMINAL_STATUSES:
            stats["resumed"] += 1
            return

        rejection = self._cheap_rejection(candidate, stadium, filters)
        if rejection:
            self._reject(league, stadium, candidate, fingerprint, rejection)
            stats[rejection] += 1
            return

        work_path = self._work_path(league, stadium, candidate)
        work_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            source.before_download(candidate)
            self.http.download(candidate.download_url, work_path)
            candidate = self._validated_candidate(candidate, work_path, filters)
            identity = identity_confidence(candidate, stadium)
            score = score_candidate(candidate, stadium, filters, identity)
            if score.score < filters.min_score:
                self._reject(league, stadium, candidate, fingerprint, "low_score")
                stats["low_score"] += 1
                return

            classification = self.classifier.classify(work_path, candidate)
            sha256, perceptual_hash = calculate_hashes(work_path)
            original_path = self._original_path(league, stadium, candidate)
            record = ImageRecord(
                id=candidate.id,
                league=league.slug,
                stadium_slug=stadium.slug,
                stadium=stadium.name,
                club=stadium.club,
                source=candidate.source,
                source_id=candidate.source_id,
                source_page=candidate.source_page,
                image_url=candidate.image_url,
                download_url=candidate.download_url,
                title=candidate.title,
                description=candidate.description,
                categories=candidate.categories,
                mime_type=candidate.mime_type,
                author=candidate.author,
                author_url=candidate.author_url,
                license=candidate.license,
                license_url=candidate.license_url,
                attribution=candidate.attribution,
                width=candidate.width,
                height=candidate.height,
                orientation="landscape"
                if candidate.width >= candidate.height
                else "portrait",
                time_of_day=classification.time_of_day,
                classification_confidence=classification.confidence,
                classification_reasons=classification.reasons,
                score=score.score,
                score_reasons=score.reasons,
                identity_confidence=identity,
                sha256=sha256,
                perceptual_hash=perceptual_hash,
                local_original_path=original_path.relative_to(
                    self.output_dir
                ).as_posix(),
                search_query=candidate.search_query,
                downloaded_at=datetime.now(UTC).isoformat(),
            )
            duplicate = self._find_duplicate(record, filters.perceptual_hash_distance)
            if duplicate is not None:
                if duplicate_preference(duplicate) <= duplicate_preference(record):
                    self._reject(league, stadium, candidate, fingerprint, "duplicate")
                    stats["duplicate"] += 1
                    return
                self._remove_record(duplicate)
                self.database.set_candidate_status(
                    duplicate.league,
                    duplicate.stadium_slug,
                    duplicate.source,
                    duplicate.source_id,
                    fingerprint,
                    "superseded",
                    f"replaced by {record.id}",
                )
                stats["duplicate_replaced"] += 1

            original_path.parent.mkdir(parents=True, exist_ok=True)
            work_path.replace(original_path)
            self.database.save_image(record)
            self.database.set_candidate_status(
                league.slug,
                stadium.slug,
                candidate.source,
                candidate.source_id,
                fingerprint,
                "accepted",
            )
            stats["accepted"] += 1
        except RateLimitError as error:
            self.database.set_candidate_status(
                league.slug,
                stadium.slug,
                candidate.source,
                candidate.source_id,
                fingerprint,
                "error",
                str(error),
            )
            raise
        except (HTTPError, OSError, UnidentifiedImageError, ValueError) as error:
            self.database.set_candidate_status(
                league.slug,
                stadium.slug,
                candidate.source,
                candidate.source_id,
                fingerprint,
                "error",
                str(error),
            )
            stats["errors"] += 1
            self.console.print(
                f"[yellow]WARNING:[/] [{stadium.name}] {candidate.id} failed: {error}"
            )
        finally:
            work_path.unlink(missing_ok=True)

    def _print_rate_limit(
        self,
        stadium: Stadium,
        source: ImageSource,
        error: RateLimitError,
    ) -> None:
        retry_message = (
            f" Retry after about {error.retry_after:.0f} seconds."
            if error.retry_after is not None
            else " Retry this command later."
        )
        self.console.print(
            f"[yellow]WARNING:[/] [{stadium.name}] {source.name} rate limit reached; "
            f"stopping that provider for this run.{retry_message} Progress has been saved."
        )

    @staticmethod
    def _cheap_rejection(
        candidate: ImageCandidate, stadium: Stadium, filters: FilterConfig
    ) -> str | None:
        if not candidate.license or not candidate.source_page:
            return "invalid_license"
        if candidate.mime_type not in {"image/jpeg", "image/png", "image/webp"}:
            return "invalid_type"
        if candidate.width < filters.min_width or candidate.height < filters.min_height:
            return "too_small"
        if candidate.aspect_ratio < filters.min_aspect_ratio:
            return "wrong_orientation"
        text_rejection = obvious_text_rejection(candidate)
        if text_rejection:
            return "obvious_non_photo"
        if identity_confidence(candidate, stadium) < 0.45:
            return "poor_relevance"
        return None

    @staticmethod
    def _validated_candidate(
        candidate: ImageCandidate,
        path: Path,
        filters: FilterConfig,
    ) -> ImageCandidate:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            normalized = ImageOps.exif_transpose(image)
            width, height = normalized.size
            detected_format = (image.format or "").upper()
        if detected_format not in {"JPEG", "MPO", "PNG", "WEBP"}:
            raise ValueError(
                f"unsupported downloaded image format: {detected_format or 'unknown'}"
            )
        if width < filters.min_width or height < filters.min_height:
            raise ValueError(f"downloaded image is too small: {width}x{height}")
        if width / height < filters.min_aspect_ratio:
            raise ValueError(
                f"downloaded image aspect ratio is too narrow: {width / height:.2f}"
            )
        mime = {
            "JPEG": "image/jpeg",
            "MPO": "image/jpeg",
            "PNG": "image/png",
            "WEBP": "image/webp",
        }[detected_format]
        return replace(candidate, width=width, height=height, mime_type=mime)

    def _find_duplicate(
        self, record: ImageRecord, distance_threshold: int
    ) -> ImageRecord | None:
        exact = self.database.find_exact_duplicate(
            record.league, record.stadium_slug, record.sha256
        )
        if exact is not None and exact.id != record.id:
            return exact
        for existing in self.database.list_images(record.league, record.stadium_slug):
            if existing.id == record.id:
                continue
            if (
                perceptual_distance(existing.perceptual_hash, record.perceptual_hash)
                <= distance_threshold
            ):
                return existing
        return None

    def _apply_retention(
        self,
        league: League,
        stadium: Stadium,
        retention_limit: int | None,
        fingerprint: str,
        stats: Counter[str],
    ) -> None:
        records = self.database.list_images(league.slug, stadium.slug)
        for category in ("day", "night"):
            limit = (
                retention_limit
                if retention_limit is not None
                else league.retention.limit_for(category)
            )
            category_records = sorted(
                (record for record in records if record.time_of_day == category),
                key=record_sort_key,
            )
            for record in category_records[limit:]:
                self._remove_record(record)
                self.database.set_candidate_status(
                    league.slug,
                    stadium.slug,
                    record.source,
                    record.source_id,
                    fingerprint,
                    "not_retained",
                    f"outside top {limit} for {category}",
                )
                stats["not_retained"] += 1

        records = self.database.list_images(league.slug, stadium.slug)
        total_limit = league.retention.total
        for record in sorted(records, key=record_sort_key)[total_limit:]:
            self._remove_record(record)
            self.database.set_candidate_status(
                league.slug,
                stadium.slug,
                record.source,
                record.source_id,
                fingerprint,
                "not_retained",
                f"outside top {total_limit} overall",
            )
            stats["not_retained"] += 1

    def _remove_record(self, record: ImageRecord) -> None:
        (self.output_dir / record.local_original_path).unlink(missing_ok=True)
        self.database.delete_image(record)

    def _reject(
        self,
        league: League,
        stadium: Stadium,
        candidate: ImageCandidate,
        fingerprint: str,
        reason: str,
    ) -> None:
        self.database.set_candidate_status(
            league.slug,
            stadium.slug,
            candidate.source,
            candidate.source_id,
            fingerprint,
            "duplicate" if reason == "duplicate" else "rejected",
            reason,
        )

    def _work_path(
        self, league: League, stadium: Stadium, candidate: ImageCandidate
    ) -> Path:
        return (
            self.output_dir
            / ".work"
            / league.slug
            / stadium.slug
            / f"{candidate.id}{_extension(candidate)}"
        )

    def _original_path(
        self, league: League, stadium: Stadium, candidate: ImageCandidate
    ) -> Path:
        return (
            self.output_dir
            / league.slug
            / stadium.team_slug
            / "original"
            / f"{candidate.id}{_extension(candidate)}"
        )

    def _print_summary(
        self,
        stadium: Stadium,
        stats: Counter[str],
        records: list[ImageRecord],
    ) -> None:
        counts = Counter(record.time_of_day for record in records)
        self.console.print(f"\n[bold]{stadium.name}[/] — {stadium.club}")
        self.console.print(f"  Candidates discovered  {stats['discovered']}")
        self.console.print(f"  Resumed/skipped        {stats['resumed']}")
        self.console.print(f"  Accepted this run      {stats['accepted']}")
        self.console.print(f"  Retained               {len(records)}")
        for category in ("day", "night"):
            self.console.print(f"  {category.title():<21}{counts[category]}")
        if records:
            average = sum(record.score for record in records) / len(records)
            self.console.print(f"  Average score          {average:.1f}")
            self.console.print(
                f"  Best score             {max(record.score for record in records):.1f}"
            )


def _extension(candidate: ImageCandidate) -> str:
    return {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}.get(
        candidate.mime_type,
        ".jpg",
    )


def _fingerprint(
    filters: FilterConfig, retention_limit: int | None, query_limit: int
) -> str:
    value = {
        "pipeline": PIPELINE_VERSION,
        "filters": filters.__dict__,
        "retention_limit": retention_limit,
        "query_limit": query_limit,
    }
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:16]
