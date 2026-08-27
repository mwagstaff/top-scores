from __future__ import annotations

import hashlib
import importlib
import json
import os
import sys
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import yaml
from PIL import Image

COLLECTOR_DIR = Path(__file__).resolve().parents[1] / "collector"
if str(COLLECTOR_DIR) not in sys.path:
    sys.path.insert(0, str(COLLECTOR_DIR))

find_images = importlib.import_module("find_images")
collect_all = importlib.import_module("collect_all")
promote_reviewed = importlib.import_module("promote_reviewed")


def png_bytes() -> bytes:
    output = BytesIO()
    Image.new("RGB", (1_600, 900), "green").save(output, format="PNG")
    return output.getvalue()


class FakeResponse:
    def __init__(self, data: bytes):
        self.data = data
        self.headers: dict[str, str] = {}

    def raise_for_status(self) -> None:
        return None

    def iter_content(self, chunk_size: int):
        del chunk_size
        yield self.data


class FakeSession:
    def __init__(self, data: bytes):
        self.data = data

    def get(self, *_args, **_kwargs) -> FakeResponse:
        return FakeResponse(self.data)


def test_reuses_openai_key_from_environment_without_bitwarden(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "existing-key")

    def unexpected_bitwarden_lookup(_name):
        raise AssertionError("Bitwarden should not be consulted")

    monkeypatch.setattr(find_images.shutil, "which", unexpected_bitwarden_lookup)

    assert find_images.load_openai_api_key() == "existing-key"


def test_loads_openai_key_from_bitwarden_value_field(monkeypatch):
    calls = []

    def fake_bw(arguments, _environment):
        calls.append(arguments)
        if arguments == ["status"]:
            return SimpleNamespace(stdout='{"status":"locked"}')
        if arguments == ["unlock", "--raw"]:
            return SimpleNamespace(stdout="session-token\n")
        return SimpleNamespace(
            stdout=json.dumps({"fields": [{"name": "Value", "value": "collector-key"}]})
        )

    monkeypatch.delenv("BW_SESSION", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(find_images.shutil, "which", lambda _name: "/usr/local/bin/bw")
    monkeypatch.setattr(find_images, "_run_bw", fake_bw)

    assert find_images.load_openai_api_key() == "collector-key"
    assert os.environ["OPENAI_API_KEY"] == "collector-key"
    assert ["sync"] in calls
    assert calls[-1] == ["get", "item", "OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR"]


def test_reunlocks_when_inherited_bitwarden_session_is_stale(monkeypatch):
    calls = []

    def fake_bw(arguments, environment):
        calls.append(arguments)
        if (
            arguments[:2] == ["get", "item"]
            and environment.get("BW_SESSION") == "stale-session"
        ):
            raise RuntimeError("stale")
        if arguments == ["status"]:
            return SimpleNamespace(stdout='{"status":"locked"}')
        if arguments == ["unlock", "--raw"]:
            return SimpleNamespace(stdout="fresh-session\n")
        return SimpleNamespace(
            stdout=json.dumps({"fields": [{"name": "Value", "value": "collector-key"}]})
        )

    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("BW_SESSION", "stale-session")
    monkeypatch.setattr(find_images.shutil, "which", lambda _name: "/usr/local/bin/bw")
    monkeypatch.setattr(find_images, "_run_bw", fake_bw)

    assert find_images.load_openai_api_key() == "collector-key"
    assert ["status"] in calls
    assert ["sync"] in calls
    assert calls[-1] == ["get", "item", "OPENAI_API_KEY_TOP_SCORES_IMAGE_COLLECTOR"]


def test_stages_only_suitable_images_above_threshold(tmp_path):
    result = {
        "stadium": "Example Stadium",
        "candidate_count": 2,
        "images": [
            {"original_url": "https://example.com/one.png", "title": "one"},
            {"original_url": "https://example.com/two.png", "title": "two"},
        ],
        "analysis": {
            "summary": "One suitable image.",
            "assessments": [
                {
                    "index": 0,
                    "score": 82,
                    "venue_confidence": 95,
                    "composition": 80,
                    "ui_suitability": 84,
                    "lighting": "day",
                    "shot_type": "wide interior",
                    "suitable": True,
                    "reason": "Clear venue and pitch.",
                },
                {
                    "index": 1,
                    "score": 91,
                    "venue_confidence": 30,
                    "composition": 90,
                    "ui_suitability": 90,
                    "lighting": "night",
                    "shot_type": "exterior",
                    "suitable": False,
                    "reason": "Wrong venue.",
                },
            ],
        },
    }

    destination = find_images.stage_suitable_images(
        result,
        staging_root=tmp_path,
        slug="example-stadium",
        teams=[{"name": "Example FC", "aliases": []}],
        session=FakeSession(png_bytes()),
    )
    manifest = json.loads((destination / "manifest.json").read_text())
    assert len(manifest["staged_images"]) == 1
    assert manifest["staged_images"][0]["assessment"]["index"] == 0
    assert (destination / manifest["staged_images"][0]["filename"]).is_file()


def test_major_team_wrapper_resolves_every_threshold_team():
    targets, threshold = collect_all.load_collection_targets()
    assert threshold == 1750
    assert any(target["slug"] == "emirates-stadium" for target in targets)
    assert any(target["slug"] == "bayarena" for target in targets)
    assert any(target["slug"] == "stadio-giuseppe-sinigaglia" for target in targets)
    assert len({target["slug"] for target in targets}) == len(targets)


def test_promotion_uses_only_files_remaining_after_review(tmp_path):
    staging = tmp_path / "staging" / "example-stadium"
    staging.mkdir(parents=True)
    kept_data = png_bytes()
    kept_name = "01-090-kept.png"
    (staging / kept_name).write_bytes(kept_data)
    manifest = {
        "schema_version": 1,
        "stadium": "Example Stadium",
        "slug": "example-stadium",
        "teams": [{"name": "Example FC", "aliases": ["Example"]}],
        "staged_images": [
            {
                "filename": kept_name,
                "sha256": hashlib.sha256(kept_data).hexdigest(),
                "assessment": {"lighting": "dusk"},
                "source": {
                    "artist": '<a href="https://example.com/jane">Jane Smith</a>',
                    "license": "CC BY-SA 4.0",
                    "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
                    "commons_page": "https://commons.wikimedia.org/wiki/File:Example.jpg",
                },
            },
            {
                "filename": "02-080-deleted.png",
                "sha256": "b" * 64,
                "assessment": {"lighting": "day"},
                "source": {},
            },
        ],
    }
    (staging / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    deployment = tmp_path / "deployment"
    _, count = promote_reviewed.promote_reviewed_images(
        staging_root=tmp_path / "staging",
        deployment_root=deployment,
        project_root=tmp_path,
    )

    assert count == 1
    config = yaml.safe_load((deployment / "publishing.yaml").read_text())
    assert len(config["assets"]) == 1
    assert config["assets"][0]["light_context"] == "night"
    assert config["assets"][0]["credit"]["author"] == "Jane Smith"
    assert not (deployment / "assets/example-stadium/02-080-deleted.png").exists()
