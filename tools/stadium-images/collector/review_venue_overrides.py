#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import requests
from find_images import MODEL, _vision_data_url, load_openai_api_key
from openai import OpenAI
from pydantic import BaseModel, Field

DEFAULT_BATCH_SIZE = 12


class VenueImageReview(BaseModel):
    venue_id: str
    identity_confidence: int = Field(ge=0, le=100)
    hero_suitability: int = Field(ge=0, le=100)
    suitable: bool
    reason: str


class VenueImageReviewBatch(BaseModel):
    reviews: list[VenueImageReview]


def load_candidates(paths: list[Path]) -> dict[str, dict]:
    merged: dict[str, dict] = {}
    for path in paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        merged.update(payload.get("resolved") or {})
    return dict(sorted(merged.items(), key=lambda item: int(item[0])))


def review_batch(client: OpenAI, candidates: list[tuple[str, dict]]) -> list[dict]:
    content: list[dict] = [
        {
            "type": "input_text",
            "text": """
Review football-stadium photos for a premium match-details hero card. Each
candidate below has its own requested venue, city, and country. Assess each
image only against the venue paired with it.

Set suitable=true only when the image visibly depicts that requested stadium
and works as a stadium image: the ground, stands, pitch, bowl, or unmistakable
stadium exterior must be prominent. Reject nearby streets, car parks, maps,
logos, unrelated buildings, player/person close-ups, and crowd or concert
shots that do not clearly show the venue. A modest lower-league ground can be
suitable; photographic grandeur is not required. Return exactly one review
for every supplied BSD venue ID.
""".strip(),
        }
    ]
    prepared_ids = []
    session = requests.Session()
    for venue_id, candidate in candidates:
        venue = candidate["venue"]
        try:
            data_url = _vision_data_url(candidate["image_url"], session=session)
        except (OSError, ValueError, requests.RequestException) as error:
            print(f"  {venue_id} thumbnail failed: {error}")
            continue
        prepared_ids.append(venue_id)
        content.extend(
            [
                {
                    "type": "input_text",
                    "text": (
                        f"BSD VENUE ID {venue_id}: {venue['name']}, "
                        f"{venue['city']}, {venue['country']}"
                    ),
                },
                {"type": "input_image", "image_url": data_url, "detail": "high"},
            ]
        )
    if not prepared_ids:
        return []

    response = client.responses.parse(
        model=MODEL,
        input=[{"role": "user", "content": content}],
        text_format=VenueImageReviewBatch,
    )
    if response.output_parsed is None:
        raise RuntimeError("OpenAI returned no structured venue-image review.")
    reviews = [review.model_dump() for review in response.output_parsed.reviews]
    returned_ids = {review["venue_id"] for review in reviews}
    missing = set(prepared_ids) - returned_ids
    if missing:
        raise RuntimeError(f"Review omitted venue IDs: {', '.join(sorted(missing))}")
    return reviews


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Visually verify proposed BSD venue-image replacements."
    )
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    args = parser.parse_args()
    if args.batch_size < 1:
        raise SystemExit("--batch-size must be at least 1")

    candidates = load_candidates(args.inputs)
    api_key = load_openai_api_key()
    client = OpenAI(api_key=api_key, max_retries=4)
    reviews: dict[str, dict] = {}
    items = list(candidates.items())
    for start in range(0, len(items), args.batch_size):
        batch = items[start : start + args.batch_size]
        print(
            f"Reviewing {start + 1}-{start + len(batch)} of {len(items)} "
            f"({', '.join(venue_id for venue_id, _ in batch)})"
        )
        for review in review_batch(client, batch):
            reviews[review["venue_id"]] = review

    payload = {
        "schema_version": 1,
        "candidate_count": len(candidates),
        "reviews": dict(sorted(reviews.items(), key=lambda item: int(item[0]))),
    }
    args.output.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    accepted = sum(review["suitable"] for review in reviews.values())
    print(f"Accepted {accepted}/{len(reviews)}. Wrote {args.output}")


if __name__ == "__main__":
    main()
