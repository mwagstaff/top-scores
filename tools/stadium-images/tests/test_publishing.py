from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import pytest
import yaml
from PIL import Image

from stadium_images.publishing import (
    PublishError,
    build_publish_bundle,
    validate_publish_bundle,
)


def _write_image(path: Path, color: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (640, 360), color=color).save(path)


def _write_config(
    path: Path, image_path: str, attribution: str = "Top Scores artwork"
) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "schema_version": 1,
                "credit_defaults": {
                    "author": "Top Scores",
                    "source": "Top Scores",
                    "license": "Top Scores artwork",
                    "attribution": attribution,
                },
                "teams": {
                    "afc-bournemouth": {
                        "name": "AFC Bournemouth",
                        "aliases": ["Bournemouth"],
                        "source_team_ids": ["1044"],
                        "venue_ids": [],
                    }
                },
                "assets": [
                    {
                        "id": "bournemouth-day-01",
                        "file": image_path,
                        "role": "team",
                        "light_context": "day",
                        "team_ids": ["afc-bournemouth"],
                        "stadium": "Vitality Stadium",
                    }
                ],
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )


def test_publish_creates_content_addressed_valid_bundle(tmp_path: Path) -> None:
    image = tmp_path / "source.jpg"
    config = tmp_path / "publishing.yaml"
    output = tmp_path / "published"
    _write_image(image, "navy")
    _write_config(config, "source.jpg")

    catalog = build_publish_bundle(
        config,
        output,
        tmp_path,
        generated_at=datetime(2026, 8, 27, tzinfo=UTC),
    )

    asset = catalog["assets"][0]
    assert asset["asset_path"] == f"assets/{asset['sha256']}.webp"
    assert asset["content_type"] == "image/webp"
    assert asset["width"] == 640
    assert asset["height"] == 360
    assert (
        validate_publish_bundle(output)["catalog_version"] == catalog["catalog_version"]
    )


def test_replacing_image_changes_hash_and_catalog_version(tmp_path: Path) -> None:
    image = tmp_path / "source.jpg"
    config = tmp_path / "publishing.yaml"
    output = tmp_path / "published"
    _write_config(config, "source.jpg")
    _write_image(image, "navy")
    first = build_publish_bundle(config, output, tmp_path)

    _write_image(image, "red")
    second = build_publish_bundle(config, output, tmp_path)

    assert first["assets"][0]["id"] == second["assets"][0]["id"]
    assert first["assets"][0]["sha256"] != second["assets"][0]["sha256"]
    assert first["catalog_version"] != second["catalog_version"]


def test_publish_rejects_missing_credit_without_replacing_previous_bundle(
    tmp_path: Path,
) -> None:
    image = tmp_path / "source.jpg"
    config = tmp_path / "publishing.yaml"
    output = tmp_path / "published"
    _write_image(image, "navy")
    _write_config(config, "source.jpg")
    first = build_publish_bundle(config, output, tmp_path)

    _write_config(config, "source.jpg", attribution="")
    with pytest.raises(PublishError, match="attribution is required"):
        build_publish_bundle(config, output, tmp_path)

    assert (
        validate_publish_bundle(output)["catalog_version"] == first["catalog_version"]
    )


def test_validate_detects_modified_published_image(tmp_path: Path) -> None:
    image = tmp_path / "source.jpg"
    config = tmp_path / "publishing.yaml"
    output = tmp_path / "published"
    _write_image(image, "navy")
    _write_config(config, "source.jpg")
    catalog = build_publish_bundle(config, output, tmp_path)
    published_image = output / catalog["assets"][0]["asset_path"]
    published_image.write_bytes(b"not the published image")

    with pytest.raises(PublishError, match="hash mismatch"):
        validate_publish_bundle(output)


def test_publish_merges_optional_reviewed_artwork_include(tmp_path: Path) -> None:
    bundled_image = tmp_path / "bundled.jpg"
    reviewed_image = tmp_path / "reviewed.jpg"
    config = tmp_path / "publishing.yaml"
    include = tmp_path / "reviewed.yaml"
    output = tmp_path / "published"
    _write_image(bundled_image, "navy")
    _write_image(reviewed_image, "green")
    _write_config(config, "bundled.jpg")
    root_config = yaml.safe_load(config.read_text())
    root_config["optional_include_files"] = ["reviewed.yaml"]
    config.write_text(yaml.safe_dump(root_config, sort_keys=False), encoding="utf-8")
    include.write_text(
        yaml.safe_dump(
            {
                "schema_version": 1,
                "teams": {
                    "afc-bournemouth": {
                        "name": "AFC Bournemouth",
                        "aliases": ["The Cherries"],
                        "source_team_ids": [],
                        "venue_ids": ["venue-1"],
                    }
                },
                "assets": [
                    {
                        "id": "bournemouth-night-reviewed",
                        "file": "reviewed.jpg",
                        "role": "team",
                        "light_context": "night",
                        "team_ids": ["afc-bournemouth"],
                        "stadium": "Vitality Stadium",
                    }
                ],
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    catalog = build_publish_bundle(config, output, tmp_path)

    assert len(catalog["assets"]) == 2
    assert catalog["teams"]["afc-bournemouth"]["aliases"] == [
        "Bournemouth",
        "The Cherries",
    ]
    assert catalog["teams"]["afc-bournemouth"]["source_team_ids"] == ["1044"]
    assert catalog["teams"]["afc-bournemouth"]["venue_ids"] == ["venue-1"]
