from __future__ import annotations

import base64
import hashlib
import importlib
import json
import os
import sys
import threading
import time
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import requests
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

    def close(self) -> None:
        return None


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


def test_reuses_openai_key_from_keychain_without_bitwarden(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(
        find_images,
        "_load_api_key_from_keychain",
        lambda _item_name: "keychain-key",
    )

    def unexpected_bitwarden_lookup(_name):
        raise AssertionError("Bitwarden should not be consulted")

    monkeypatch.setattr(find_images.shutil, "which", unexpected_bitwarden_lookup)

    assert find_images.load_openai_api_key() == "keychain-key"
    assert os.environ["OPENAI_API_KEY"] == "keychain-key"


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
    monkeypatch.setattr(find_images, "_store_api_key_in_keychain", lambda *_args: None)

    assert find_images.load_openai_api_key(use_cached=False) == "collector-key"
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
    monkeypatch.setattr(find_images, "_store_api_key_in_keychain", lambda *_args: None)

    assert find_images.load_openai_api_key(use_cached=False) == "collector-key"
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


def test_single_stadium_queries_add_club_context_without_changing_stadium_name():
    queries = find_images.build_queries("Emirates Stadium", "Arsenal")

    assert len(queries) == 5
    assert all(query.startswith("Emirates Stadium Arsenal ") for query in queries)


def test_vision_thumbnail_is_resized_and_embedded_as_a_data_url():
    data_url = find_images._vision_data_url(
        "https://example.com/stadium.png",
        session=FakeSession(png_bytes()),
    )

    assert data_url.startswith("data:image/jpeg;base64,")
    encoded = data_url.partition(",")[2]
    with Image.open(BytesIO(base64.b64decode(encoded))) as image:
        assert image.format == "JPEG"
        assert max(image.size) == find_images.VISION_MAX_SIDE


def test_score_images_never_passes_wikimedia_urls_to_openai(monkeypatch):
    captured = {}
    analysis = find_images.StadiumAssessment(
        assessments=[
            find_images.ImageAssessment(
                index=0,
                score=80,
                venue_confidence=90,
                composition=80,
                ui_suitability=80,
                lighting="day",
                shot_type="wide interior",
                suitable=True,
                reason="Clear stadium view.",
            )
        ],
        summary="Suitable.",
    )

    def fake_parse(**kwargs):
        captured.update(kwargs)
        return SimpleNamespace(output_parsed=analysis)

    monkeypatch.setattr(
        find_images,
        "_prepare_vision_images",
        lambda *_args, **_kwargs: [(0, "data:image/jpeg;base64,dGVzdA==")],
    )
    client = SimpleNamespace(responses=SimpleNamespace(parse=fake_parse))

    result = find_images.score_images(
        "Turf Moor",
        [{"thumbnail_url": "https://upload.wikimedia.org/example.jpg"}],
        client,
    )

    image_parts = [
        item
        for item in captured["input"][0]["content"]
        if item["type"] == "input_image"
    ]
    assert result == analysis
    assert [part["image_url"] for part in image_parts] == [
        "data:image/jpeg;base64,dGVzdA=="
    ]


def test_wikimedia_download_retries_429_using_retry_after(monkeypatch):
    class RateLimitedResponse(FakeResponse):
        status_code = 429

        def __init__(self, data: bytes):
            super().__init__(data)
            self.headers = {"Retry-After": "3"}

        def raise_for_status(self) -> None:
            raise requests.HTTPError("rate limited", response=self)

    class SequenceSession:
        def __init__(self):
            self.responses = [RateLimitedResponse(b""), FakeResponse(png_bytes())]

        def get(self, *_args, **_kwargs):
            return self.responses.pop(0)

    sleeps = []
    monkeypatch.setattr(find_images.time, "sleep", sleeps.append)

    data, extension = find_images._download_image(
        "https://upload.wikimedia.org/example.png",
        SequenceSession(),
    )

    assert data == png_bytes()
    assert extension == "png"
    assert 3.0 in sleeps


def test_league_scopes_resolve_every_configured_club():
    premier, _ = collect_all.load_collection_targets(scopes={"premier-league"})
    championship, _ = collect_all.load_collection_targets(scopes={"championship"})

    assert len(premier) == 20
    assert len(championship) == 24
    assert any(target["slug"] == "emirates-stadium" for target in premier)
    assert any(target["slug"] == "vicarage-road" for target in championship)
    assert all(target["search_terms"] for target in premier + championship)


def test_major_team_wrapper_resolves_every_threshold_team():
    targets, threshold = collect_all.load_collection_targets(scopes={"major"})
    assert threshold == 1750
    assert any(target["slug"] == "emirates-stadium" for target in targets)
    assert any(target["slug"] == "bayarena" for target in targets)
    assert any(target["slug"] == "stadio-giuseppe-sinigaglia" for target in targets)
    assert len({target["slug"] for target in targets}) == len(targets)


def test_collection_runs_five_stadium_pipelines_in_parallel(tmp_path, monkeypatch):
    lock = threading.Lock()
    first_batch = threading.Barrier(5)
    active = 0
    maximum_active = 0
    started = 0
    client_options = []

    def fake_research(*_args, **_kwargs):
        nonlocal active, maximum_active, started
        with lock:
            active += 1
            started += 1
            current_started = started
            maximum_active = max(maximum_active, active)
        if current_started <= 5:
            first_batch.wait(timeout=2)
        time.sleep(0.01)
        with lock:
            active -= 1
        return {}

    def fake_stage(_result, *, staging_root, slug, **_kwargs):
        return staging_root / slug

    monkeypatch.setattr(collect_all, "research_stadium", fake_research)
    monkeypatch.setattr(collect_all, "stage_suitable_images", fake_stage)

    def fake_client_factory(**kwargs):
        client_options.append(kwargs)
        return object()

    targets = [
        {
            "club": f"Club {index}",
            "stadium": f"Stadium {index}",
            "slug": f"stadium-{index}",
            "teams": [],
            "search_terms": [f"Stadium {index} Club {index}"],
            "source": "test",
        }
        for index in range(6)
    ]

    failures = collect_all.collect_targets(
        targets,
        api_key="test-key",
        staging_root=tmp_path,
        per_query=1,
        min_score=70,
        max_downloads=1,
        replace=False,
        client_factory=fake_client_factory,
    )

    assert failures == []
    assert collect_all.DEFAULT_WORKERS == 5
    assert maximum_active == 5
    assert all(
        options["max_retries"] == find_images.OPENAI_MAX_RETRIES
        for options in client_options
    )


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
