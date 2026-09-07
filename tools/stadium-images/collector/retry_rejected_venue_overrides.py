#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

from find_images import (
    OPENAI_MAX_RETRIES,
    basic_filter,
    configure_wikimedia_requests,
    dedupe,
    load_openai_api_key,
    score_images,
    search_commons,
)
from openai import OpenAI
from research_venue_overrides import SEARCH_ALIASES, WikimediaClient

DEFAULT_WORKERS = 5


def load_candidates(paths: list[Path]) -> dict[str, dict]:
    merged: dict[str, dict] = {}
    for path in paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        merged.update(payload.get("resolved") or {})
    return merged


def search_queries(venue_id: str, venue: dict) -> list[str]:
    names = [venue["name"], *SEARCH_ALIASES.get(venue_id, [])]
    queries = []
    for name in names:
        queries.extend(
            [
                f'"{name}" {venue["city"]} football stadium',
                f"{name} {venue['city']} stadium interior pitch",
                f"{name} {venue['city']} stadium panorama",
            ]
        )
    return queries


def retry_candidate(
    venue_id: str,
    previous: dict,
    *,
    api_key: str,
    per_query: int,
) -> tuple[str, dict | None, str]:
    venue = previous["venue"]
    label = f"[{venue_id} {venue['name']}]"
    print(f"{label} searching")
    images = []
    for query in search_queries(venue_id, venue):
        try:
            images.extend(search_commons(query, limit=per_query))
        except Exception as error:  # noqa: BLE001 - continue other source queries
            print(f"{label} search failed: {error}")
    previous_page = previous.get("source_page")
    images = [
        image
        for image in basic_filter(dedupe(images))
        if image.get("commons_page") != previous_page
    ][:30]
    if not images:
        return venue_id, None, "No alternative licensed landscape candidates found."

    client = OpenAI(api_key=api_key, max_retries=OPENAI_MAX_RETRIES)
    analysis = score_images(
        f"{venue['name']}, {venue['city']}, {venue['country']}",
        images,
        client,
        log_prefix=label,
    )
    accepted = sorted(
        (
            assessment
            for assessment in analysis.assessments
            if assessment.suitable
            and assessment.venue_confidence >= 70
            and assessment.score >= 60
            and assessment.index < len(images)
        ),
        key=lambda assessment: (
            -assessment.score,
            -assessment.venue_confidence,
            assessment.index,
        ),
    )
    if not accepted:
        return venue_id, None, analysis.summary

    assessment = accepted[0]
    selected = images[assessment.index]
    title = str(selected.get("title") or "")
    metadata = WikimediaClient().commons_file(title)
    if metadata is None:
        return venue_id, None, "Selected Commons file metadata was unavailable."
    return (
        venue_id,
        {
            "venue": venue,
            **metadata,
            "method": "visual_commons_retry",
            "wikidata_id": None,
            "confidence_score": float(assessment.venue_confidence),
            "visual_score": assessment.score,
            "visual_reason": assessment.reason,
        },
        analysis.summary,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Find visually verified alternatives for rejected venue images."
    )
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--reviews", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--per-query", type=int, default=12)
    args = parser.parse_args()
    if args.workers < 1:
        raise SystemExit("--workers must be at least 1")

    candidates = load_candidates(args.inputs)
    review_payload = json.loads(args.reviews.read_text(encoding="utf-8"))
    reviews = review_payload.get("reviews") or {}
    rejected = [
        (venue_id, candidates[venue_id])
        for venue_id, review in reviews.items()
        if not review.get("suitable") and venue_id in candidates
    ]
    api_key = load_openai_api_key()
    configure_wikimedia_requests(max_concurrency=2, min_interval_seconds=0.25)

    resolved: dict[str, dict] = {}
    unresolved = []
    with ThreadPoolExecutor(max_workers=min(args.workers, len(rejected))) as executor:
        futures = {
            executor.submit(
                retry_candidate,
                venue_id,
                previous,
                api_key=api_key,
                per_query=args.per_query,
            ): (venue_id, previous)
            for venue_id, previous in rejected
        }
        for future in as_completed(futures):
            venue_id, previous = futures[future]
            try:
                result_id, candidate, summary = future.result()
            except Exception as error:  # noqa: BLE001 - retain every failure
                candidate = None
                result_id = venue_id
                summary = str(error)
            if candidate is None:
                unresolved.append({**previous["venue"], "reason": summary})
                print(f"[{result_id}] unresolved: {summary}")
            else:
                resolved[result_id] = candidate
                print(f"[{result_id}] resolved: {candidate['title']}")

    payload = {
        "schema_version": 1,
        "resolved": dict(sorted(resolved.items(), key=lambda item: int(item[0]))),
        "unresolved": sorted(unresolved, key=lambda item: int(item["id"])),
    }
    args.output.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"Resolved {len(resolved)}/{len(rejected)} rejected venues; "
        f"unresolved {len(unresolved)}. Wrote {args.output}"
    )


if __name__ == "__main__":
    main()
