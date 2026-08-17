from pathlib import Path

from PIL import Image

from stadium_images.models import FilterConfig, ImageCandidate, Stadium
from stadium_images.processing.classifier import HeuristicImageClassifier
from stadium_images.processing.dedupe import calculate_hashes, perceptual_distance
from stadium_images.processing.scorer import (
    identity_confidence,
    obvious_text_rejection,
    score_candidate,
)


def candidate(**overrides: object) -> ImageCandidate:
    values = {
        "source": "wikimedia",
        "source_id": "123",
        "source_page": "https://commons.wikimedia.org/wiki/File:Example.jpg",
        "image_url": "https://upload.wikimedia.org/example.jpg",
        "download_url": "https://upload.wikimedia.org/example.jpg",
        "author": "Jane Smith",
        "author_url": None,
        "license": "CC BY 4.0",
        "license_url": "https://creativecommons.org/licenses/by/4.0/",
        "attribution": "Jane Smith, CC BY 4.0",
        "width": 4096,
        "height": 2304,
        "mime_type": "image/jpeg",
        "title": "Emirates Stadium interior pitch",
        "description": "Wide angle view of the stadium bowl",
        "categories": ("Emirates Stadium",),
        "search_query": "Emirates Stadium",
    }
    values.update(overrides)
    return ImageCandidate(**values)


def stadium() -> Stadium:
    return Stadium(
        club="Arsenal",
        name="Emirates Stadium",
        slug="emirates-stadium",
        aliases=("Arsenal Stadium",),
        search_terms=("Emirates Stadium",),
    )


def test_identity_and_score_favour_stadium_wide_angle() -> None:
    value = candidate()
    identity = identity_confidence(value, stadium())
    score = score_candidate(value, stadium(), FilterConfig(), identity)

    assert identity == 0.98
    assert score.score >= 8
    assert any("hero-friendly" in reason for reason in score.reasons)


def test_obvious_non_stadium_scene_is_rejected() -> None:
    value = candidate(
        title="A surgical operation",
        description="An aquatint with the stadium barely visible through a window",
    )

    assert obvious_text_rejection(value) == "aquatint"


def test_classifier_combines_keyword_and_luminance(tmp_path: Path) -> None:
    image_path = tmp_path / "night.jpg"
    Image.new("RGB", (1800, 1000), (18, 22, 35)).save(image_path)

    result = HeuristicImageClassifier().classify(
        image_path,
        candidate(title="Emirates Stadium at night", search_query="Emirates Stadium"),
    )

    assert result.time_of_day == "night"
    assert result.confidence >= 0.9
    assert any("luminance" in reason for reason in result.reasons)


def test_classifier_maps_twilight_to_night_and_always_returns_two_categories(
    tmp_path: Path,
) -> None:
    twilight_path = tmp_path / "twilight.jpg"
    ambiguous_path = tmp_path / "ambiguous.jpg"
    Image.new("RGB", (1800, 1000), (85, 85, 100)).save(twilight_path)
    Image.new("RGB", (1800, 1000), (112, 112, 112)).save(ambiguous_path)
    classifier = HeuristicImageClassifier()

    twilight = classifier.classify(
        twilight_path,
        candidate(title="Stadium at twilight", search_query="Stadium"),
    )
    ambiguous = classifier.classify(
        ambiguous_path,
        candidate(title="Stadium bowl", search_query="Stadium"),
    )

    assert twilight.time_of_day == "night"
    assert ambiguous.time_of_day in {"day", "night"}


def test_hashes_detect_exact_and_visual_matches(tmp_path: Path) -> None:
    first = tmp_path / "first.jpg"
    second = tmp_path / "second.jpg"
    Image.new("RGB", (1800, 1000), (80, 120, 160)).save(first, quality=95)
    Image.new("RGB", (1800, 1000), (80, 120, 160)).save(second, quality=80)

    first_sha, first_phash = calculate_hashes(first)
    second_sha, second_phash = calculate_hashes(second)

    assert first_sha != second_sha
    assert perceptual_distance(first_phash, second_phash) <= 2
