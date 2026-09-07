"""Sync server removals before publishing; preserve rejected originals outside active folders."""
from __future__ import annotations

import json
import re
import shlex
import shutil
import subprocess
from pathlib import Path

import yaml


def matches(asset: dict, entries: list[dict]) -> bool:
    source = (asset.get("credit") or {}).get("source_page")
    return any(entry["id"] == asset.get("id") or entry["sha256"] == asset.get("sha256")
               or (entry.get("source_page") and entry["source_page"] == source) for entry in entries)


def validate_entries(value: object) -> list[dict]:
    if not isinstance(value, list) or any(
        not isinstance(entry, dict)
        or not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,79}", str(entry.get("id", "")))
        or not re.fullmatch(r"[a-f0-9]{64}", str(entry.get("sha256", "")))
        for entry in value
    ):
        raise ValueError("Invalid server artwork deletion record")
    return value


def sync_deletions(settings: dict | None, project_root: Path) -> list[dict]:
    if not settings:
        return []
    host = str(settings["host"])
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9@._-]*", host):
        raise ValueError("Invalid artwork deletion sync host")
    remote_path = shlex.quote(str(settings["path"]))
    # Missing file means no deletions yet. Connection/permission/JSON errors stop publishing.
    command = f"if test -f {remote_path}; then cat {remote_path}; else printf '[]'; fi"
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command],
                            check=True, capture_output=True, text=True, timeout=30)
    entries = validate_entries(json.loads(result.stdout))
    cache = project_root / "tools/stadium-images/collector/server-deletions.json"
    previous = validate_entries(json.loads(cache.read_text())) if cache.exists() else []
    combined = {(entry["id"], entry["sha256"]): entry for entry in previous + entries}
    entries = list(combined.values())
    cache.parent.mkdir(parents=True, exist_ok=True)
    temporary = cache.with_suffix(".tmp")
    temporary.write_text(json.dumps(entries, indent=2) + "\n")
    temporary.replace(cache)
    reconcile_local_images(project_root, entries)
    return entries


def reconcile_local_images(project_root: Path, entries: list[dict]) -> None:
    if not entries:
        return
    collector = (project_root / "tools/stadium-images/collector").resolve()
    allowed = [(collector / folder).resolve() for folder in ("deployment/assets", "staging", "reviewed")]

    def quarantine(file: Path) -> None:
        source = file.resolve()
        if not any(root in source.parents for root in allowed):
            raise ValueError(f"Refusing to move an image outside collector folders: {file}")
        if not source.is_file():
            return
        target = collector / "removed" / source.relative_to(collector)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if target.read_bytes() != source.read_bytes():
                raise ValueError(f"Conflicting removed original: {target}")
            source.unlink()
        else:
            shutil.move(source, target)

    config_path = collector / "deployment/publishing.yaml"
    if config_path.exists():
        config = yaml.safe_load(config_path.read_text())
        retained = []
        for asset in config.get("assets", []):
            if matches(asset, entries):
                quarantine(project_root / asset["file"])
            else:
                retained.append(asset)
        if len(retained) != len(config.get("assets", [])):
            config["assets"] = retained
            temporary = config_path.with_suffix(".tmp")
            temporary.write_text(yaml.safe_dump(config, sort_keys=False, allow_unicode=True))
            temporary.replace(config_path)

    for folder in ("staging", "reviewed"):
        for manifest_path in (collector / folder).rglob("manifest.json"):
            manifest = json.loads(manifest_path.read_text())
            retained = []
            for image in manifest.get("staged_images", []):
                asset = {"id": f"{manifest.get('slug')}-any-{str(image.get('sha256', ''))[:10]}",
                         "sha256": image.get("sha256"),
                         "credit": {"source_page": (image.get("source") or {}).get("commons_page")}}
                if matches(asset, entries):
                    filename = str(image.get("filename", ""))
                    if not filename or Path(filename).name != filename:
                        raise ValueError("Invalid staged image filename")
                    quarantine(manifest_path.parent / filename)
                else:
                    retained.append(image)
            if len(retained) != len(manifest.get("staged_images", [])):
                manifest["staged_images"] = retained
                temporary = manifest_path.with_suffix(".tmp")
                temporary.write_text(json.dumps(manifest, indent=2) + "\n")
                temporary.replace(manifest_path)
