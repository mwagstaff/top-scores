from __future__ import annotations

import math
import re

from ..models import FilterConfig, ImageCandidate, ScoreResult, Stadium

REJECT_TEXT = (
    "logo",
    "club crest",
    "badge",
    "seating plan",
    "stadium map",
    "location map",
    "diagram",
    "illustration",
    "screenshot",
    "collage",
)
POSITIVE_TEXT = (
    "interior",
    "inside",
    "pitch",
    "wide angle",
    "panorama",
    "floodlight",
    "stadium bowl",
)
NEGATIVE_TEXT = (
    "exterior",
    "outside",
    "selfie",
    "portrait",
    "close-up",
    "close up",
    "aerial",
)


def obvious_text_rejection(candidate: ImageCandidate) -> str | None:
    text = candidate.searchable_text.casefold()
    return next((term for term in REJECT_TEXT if term in text), None)


def identity_confidence(candidate: ImageCandidate, stadium: Stadium) -> float:
    text = _normalized(candidate.searchable_text)
    names = (stadium.name, *stadium.aliases)
    if any(_normalized(name) in text for name in names if name):
        return 0.98
    if _normalized(stadium.club) in text and "stadium" in text:
        return 0.82
    categories = " ".join(candidate.categories).casefold()
    if stadium.club.casefold() in categories:
        return 0.72
    query = _normalized(candidate.search_query)
    if any(_normalized(name) in query for name in names if name):
        return 0.52
    return 0.20


def score_candidate(
    candidate: ImageCandidate,
    stadium: Stadium,
    filters: FilterConfig,
    identity: float,
) -> ScoreResult:
    score = 2.0 + 3.5 * identity
    reasons = [f"identity confidence {identity:.2f}"]

    megapixels = candidate.width * candidate.height / 1_000_000
    resolution_points = min(1.35, max(0.0, math.log2(max(megapixels, 1.0)) * 0.45))
    score += resolution_points
    reasons.append(
        f"resolution {candidate.width}×{candidate.height} (+{resolution_points:.2f})"
    )

    aspect = candidate.aspect_ratio
    if (
        filters.preferred_aspect_ratio_min
        <= aspect
        <= filters.preferred_aspect_ratio_max
    ):
        score += 1.2
        reasons.append(f"hero-friendly aspect ratio {aspect:.2f} (+1.20)")
    elif aspect >= filters.min_aspect_ratio:
        score += 0.55
        reasons.append(f"acceptable landscape aspect ratio {aspect:.2f} (+0.55)")

    text = candidate.searchable_text.casefold()
    positive_hits = [term for term in POSITIVE_TEXT if term in text]
    if positive_hits:
        bonus = min(1.0, len(positive_hits) * 0.35)
        score += bonus
        reasons.append(f"useful scene terms: {', '.join(positive_hits)} (+{bonus:.2f})")

    negative_hits = [term for term in NEGATIVE_TEXT if term in text]
    if negative_hits:
        penalty = min(1.5, len(negative_hits) * 0.6)
        score -= penalty
        reasons.append(
            f"less suitable scene terms: {', '.join(negative_hits)} (-{penalty:.2f})"
        )

    return ScoreResult(round(max(0.0, min(10.0, score)), 2), tuple(reasons))


def _normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()
