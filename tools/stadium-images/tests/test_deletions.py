import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml
from PIL import Image

from stadium_images.deletions import reconcile_local_images, sync_deletions
from stadium_images.publishing import build_publish_bundle

ENTRY = {"id": "stadium-any-1234567890", "sha256": "a" * 64,
         "source_page": "https://commons.wikimedia.org/wiki/File:Removed.jpg"}


def test_reconciliation_removes_active_references_and_quarantines_only_matching_files(tmp_path):
    root = tmp_path / "tools/stadium-images/collector"
    approved = root / "deployment/assets/team-18/removed.jpg"
    approved.parent.mkdir(parents=True)
    approved.write_bytes(b"approved original")
    kept = approved.with_name("keep.jpg")
    kept.write_bytes(b"keep")
    config = root / "deployment/publishing.yaml"
    asset = {"id": ENTRY["id"], "file": str(approved.relative_to(tmp_path)), "credit": {"source_page": ENTRY["source_page"]}}
    config.write_text(yaml.safe_dump({"schema_version": 1, "teams": {}, "assets": [asset, {"id": "keep", "file": str(kept.relative_to(tmp_path))}]}))
    for folder in ("staging/team-18", "reviewed/old/team-18"):
        directory = root / folder
        directory.mkdir(parents=True)
        (directory / "removed.jpg").write_bytes(b"staged original")
        (directory / "keep.jpg").write_bytes(b"keep")
        (directory / "manifest.json").write_text(json.dumps({"slug": "stadium", "staged_images": [
            {"filename": "removed.jpg", "sha256": "1234567890" + "b" * 54, "source": {"commons_page": ENTRY["source_page"]}},
            {"filename": "keep.jpg", "sha256": "c" * 64}]}))
    reconcile_local_images(tmp_path, [ENTRY])
    reconcile_local_images(tmp_path, [ENTRY])
    assert not approved.exists()
    assert kept.read_bytes() == b"keep"
    assert (root / "removed/deployment/assets/team-18/removed.jpg").read_bytes() == b"approved original"
    assert [a["id"] for a in yaml.safe_load(config.read_text())["assets"]] == ["keep"]
    for folder in ("staging/team-18", "reviewed/old/team-18"):
        assert not (root / folder / "removed.jpg").exists()
        assert (root / folder / "keep.jpg").exists()
        assert len(json.loads((root / folder / "manifest.json").read_text())["staged_images"]) == 1


def test_reconciliation_refuses_paths_outside_collector(tmp_path):
    source = tmp_path / "important.jpg"
    source.write_bytes(b"keep")
    config = tmp_path / "tools/stadium-images/collector/deployment/publishing.yaml"
    config.parent.mkdir(parents=True)
    config.write_text(yaml.safe_dump({"assets": [{"id": ENTRY["id"], "file": "important.jpg"}]}))
    with pytest.raises(ValueError, match="outside collector"):
        reconcile_local_images(tmp_path, [ENTRY])
    assert source.read_bytes() == b"keep"


def test_sync_keeps_previously_recorded_deletions_and_fails_on_connection_error(tmp_path, monkeypatch):
    replies = iter([json.dumps([ENTRY]), "[]"])
    monkeypatch.setattr("stadium_images.deletions.subprocess.run", lambda *a, **k: SimpleNamespace(stdout=next(replies)))
    settings = {"host": "sky", "path": "/safe/artwork.deletions.json"}
    assert sync_deletions(settings, tmp_path) == [ENTRY]
    assert sync_deletions(settings, tmp_path) == [ENTRY]
    def fail(*args, **kwargs):
        raise subprocess.CalledProcessError(255, "ssh")
    monkeypatch.setattr("stadium_images.deletions.subprocess.run", fail)
    with pytest.raises(subprocess.CalledProcessError):
        sync_deletions(settings, tmp_path)


def test_publisher_excludes_removed_ids_and_matching_reprocessed_sources(tmp_path, monkeypatch):
    image = tmp_path / "original.jpg"
    Image.new("RGB", (640, 360), "red").save(image)
    config = tmp_path / "publishing.yaml"
    config.write_text(yaml.safe_dump({"schema_version": 1, "teams": {},
        "credit_defaults": {"author": "Test", "source": "Test", "license": "CC0", "attribution": "Test"},
        "deletion_sync": {"host": "sky", "path": "/safe/deletions.json"},
        "assets": [{"id": ENTRY["id"], "file": "already-removed.jpg", "role": "generic_match"},
                   {"id": "new-encoding", "file": "original.jpg", "role": "generic_match", "credit": {"source_page": ENTRY["source_page"]}},
                   {"id": "kept-image", "file": "original.jpg", "role": "generic_match"}]}))
    monkeypatch.setattr("stadium_images.deletions.subprocess.run", lambda *a, **k: SimpleNamespace(stdout=json.dumps([ENTRY])))
    output = tmp_path / "published"
    catalog = build_publish_bundle(config, output, tmp_path)
    assert [asset["id"] for asset in catalog["assets"]] == ["kept-image"]
    assert len(list(output.rglob("*.webp"))) == 1
    assert image.exists()  # Bundled/non-collector originals are never moved.
    previous = (output / "catalog.json").read_bytes()
    monkeypatch.setattr("stadium_images.deletions.subprocess.run", lambda *a, **k: SimpleNamespace(stdout="corrupt"))
    with pytest.raises(ValueError):
        build_publish_bundle(config, output, tmp_path)
    assert (output / "catalog.json").read_bytes() == previous
