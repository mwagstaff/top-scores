from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import yaml
from PIL import Image, ImageOps

SCHEMA_VERSION = 1
VALID_ROLES = {"generic_backdrop", "generic_match", "team"}
VALID_LIGHT_CONTEXTS = {"any", "day", "night"}
ASSET_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{1,79}$")
HASH_PATTERN = re.compile(r"^[a-f0-9]{64}$")
DEFAULT_MAX_DIMENSION = 1_600
DEFAULT_WEBP_QUALITY = 86
DEFAULT_PUBLISH_DIR = Path(__file__).resolve().parents[2] / "published"
DEFAULT_PROJECT_ROOT = Path(__file__).resolve().parents[4]


class PublishError(ValueError):
    pass


def build_publish_bundle(
    config_path: Path,
    output_dir: Path = DEFAULT_PUBLISH_DIR,
    project_root: Path = DEFAULT_PROJECT_ROOT,
    generated_at: datetime | None = None,
) -> dict[str, Any]:
    config = _load_config_with_optional_includes(config_path, project_root)
    teams = _normalize_teams(config.get("teams"))
    credit_defaults = _mapping(config.get("credit_defaults"), "credit_defaults")
    assets = config.get("assets")
    if not isinstance(assets, list) or not assets:
        raise PublishError("assets must contain at least one image")

    temporary_dir = output_dir.parent / f".{output_dir.name}.tmp-{uuid.uuid4().hex}"
    asset_output_dir = temporary_dir / "assets"
    asset_output_dir.mkdir(parents=True, exist_ok=False)

    normalized_assets: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    try:
        for raw_asset in assets:
            asset = _normalize_asset(
                raw_asset,
                teams=teams,
                credit_defaults=credit_defaults,
                project_root=project_root,
                output_dir=asset_output_dir,
            )
            asset_id = asset["id"]
            if asset_id in seen_ids:
                raise PublishError(f"duplicate asset id: {asset_id}")
            seen_ids.add(asset_id)
            normalized_assets.append(asset)

        normalized_assets.sort(key=lambda item: item["id"])
        version_input = {
            "schema_version": SCHEMA_VERSION,
            "teams": teams,
            "assets": normalized_assets,
        }
        catalog_version = hashlib.sha256(_canonical_json(version_input)).hexdigest()
        timestamp = (generated_at or datetime.now(UTC)).astimezone(UTC).isoformat()
        catalog = {
            "schema_version": SCHEMA_VERSION,
            "catalog_version": catalog_version,
            "generated_at": timestamp,
            "teams": teams,
            "assets": normalized_assets,
        }
        _write_json(temporary_dir / "catalog.json", catalog)
        _replace_directory(temporary_dir, output_dir)
        return catalog
    except Exception:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise


def validate_publish_bundle(bundle_dir: Path) -> dict[str, Any]:
    catalog_path = bundle_dir / "catalog.json"
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublishError(f"could not read {catalog_path}: {error}") from error

    if catalog.get("schema_version") != SCHEMA_VERSION:
        raise PublishError(f"unsupported schema_version in {catalog_path}")
    if not HASH_PATTERN.fullmatch(str(catalog.get("catalog_version") or "")):
        raise PublishError("catalog_version must be a SHA-256 value")
    assets = catalog.get("assets")
    if not isinstance(assets, list):
        raise PublishError("catalog assets must be an array")

    for asset in assets:
        content_hash = str(asset.get("sha256") or "")
        asset_path = str(asset.get("asset_path") or "")
        if not HASH_PATTERN.fullmatch(content_hash):
            raise PublishError(f"invalid sha256 for asset {asset.get('id')}")
        if asset_path != f"assets/{content_hash}.webp":
            raise PublishError(f"invalid asset_path for asset {asset.get('id')}")
        file_path = bundle_dir / asset_path
        if not file_path.is_file():
            raise PublishError(f"missing published image: {asset_path}")
        actual_hash = hashlib.sha256(file_path.read_bytes()).hexdigest()
        if actual_hash != content_hash:
            raise PublishError(f"hash mismatch for published image: {asset_path}")
    return catalog


def _load_config(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise PublishError(f"could not read {path}: {error}") from error
    if not isinstance(value, dict):
        raise PublishError("publishing configuration must be an object")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise PublishError(f"schema_version must be {SCHEMA_VERSION}")
    return value


def _load_config_with_optional_includes(
    path: Path,
    project_root: Path,
) -> dict[str, Any]:
    config = _load_config(path)
    include_files = config.get("optional_include_files") or []
    if not isinstance(include_files, list):
        raise PublishError("optional_include_files must be an array")

    combined = {
        **config,
        "teams": dict(_mapping(config.get("teams"), "teams")),
        "assets": list(config.get("assets") or []),
    }
    root = project_root.resolve()
    for include_value in include_files:
        relative_path = Path(_required_text(include_value, "optional include file"))
        include_path = (root / relative_path).resolve()
        if include_path != root and root not in include_path.parents:
            raise PublishError(
                f"optional include file escapes the project root: {relative_path}"
            )
        if not include_path.exists():
            continue
        included = _load_config(include_path)
        if included.get("optional_include_files"):
            raise PublishError(
                f"nested optional includes are not supported: {relative_path}"
            )
        for team_id, raw_team in _mapping(
            included.get("teams"), "included teams"
        ).items():
            existing = combined["teams"].get(team_id)
            if existing is None:
                combined["teams"][team_id] = raw_team
                continue
            combined["teams"][team_id] = _merge_team_config(team_id, existing, raw_team)
        included_defaults = _mapping(
            included.get("credit_defaults"),
            "included credit_defaults",
        )
        for raw_asset in included.get("assets") or []:
            asset = dict(_mapping(raw_asset, "included asset"))
            if included_defaults:
                asset["credit"] = {
                    **included_defaults,
                    **_mapping(asset.get("credit"), "included asset credit"),
                }
            combined["assets"].append(asset)
    return combined


def _merge_team_config(team_id: str, first: Any, second: Any) -> dict[str, Any]:
    left = _mapping(first, f"team {team_id}")
    right = _mapping(second, f"team {team_id}")
    left_name = _required_text(left.get("name"), f"team {team_id} name")
    right_name = _required_text(right.get("name"), f"team {team_id} name")
    if left_name.casefold() != right_name.casefold():
        raise PublishError(f"conflicting names for included team {team_id}")
    return {
        "name": left_name,
        "aliases": sorted(
            set(_text_list(left.get("aliases"))) | set(_text_list(right.get("aliases")))
        ),
        "source_team_ids": sorted(
            set(_text_list(left.get("source_team_ids")))
            | set(_text_list(right.get("source_team_ids")))
        ),
        "venue_ids": sorted(
            set(_text_list(left.get("venue_ids")))
            | set(_text_list(right.get("venue_ids")))
        ),
    }


def _normalize_teams(value: Any) -> dict[str, dict[str, Any]]:
    raw_teams = _mapping(value, "teams")
    teams: dict[str, dict[str, Any]] = {}
    for team_id, raw_team in sorted(raw_teams.items()):
        if not ASSET_ID_PATTERN.fullmatch(str(team_id)):
            raise PublishError(f"invalid team id: {team_id}")
        team = _mapping(raw_team, f"team {team_id}")
        name = _required_text(team.get("name"), f"team {team_id} name")
        teams[str(team_id)] = {
            "name": name,
            "aliases": _text_list(team.get("aliases")),
            "source_team_ids": _text_list(team.get("source_team_ids")),
            "venue_ids": _text_list(team.get("venue_ids")),
        }
    return teams


def _normalize_asset(
    value: Any,
    *,
    teams: dict[str, dict[str, Any]],
    credit_defaults: dict[str, Any],
    project_root: Path,
    output_dir: Path,
) -> dict[str, Any]:
    raw = _mapping(value, "asset")
    asset_id = _required_text(raw.get("id"), "asset id")
    if not ASSET_ID_PATTERN.fullmatch(asset_id):
        raise PublishError(f"invalid asset id: {asset_id}")

    role = _required_text(raw.get("role"), f"asset {asset_id} role")
    if role not in VALID_ROLES:
        raise PublishError(f"invalid role for asset {asset_id}: {role}")
    light_context = str(raw.get("light_context") or "any").strip().lower()
    if light_context not in VALID_LIGHT_CONTEXTS:
        raise PublishError(
            f"invalid light_context for asset {asset_id}: {light_context}"
        )
    if role in {"generic_match", "team"} and light_context == "any":
        raise PublishError(f"asset {asset_id} requires day or night light_context")
    if role == "generic_backdrop" and light_context != "any":
        raise PublishError(f"generic backdrop {asset_id} must use light_context: any")

    team_ids = _text_list(raw.get("team_ids"))
    if role == "team" and not team_ids:
        raise PublishError(f"team asset {asset_id} requires team_ids")
    if role != "team" and team_ids:
        raise PublishError(f"non-team asset {asset_id} cannot define team_ids")
    unknown_teams = [team_id for team_id in team_ids if team_id not in teams]
    if unknown_teams:
        raise PublishError(
            f"asset {asset_id} references unknown teams: {', '.join(unknown_teams)}"
        )

    relative_source = _required_text(raw.get("file"), f"asset {asset_id} file")
    source = (project_root / relative_source).resolve()
    root = project_root.resolve()
    if source != root and root not in source.parents:
        raise PublishError(f"asset {asset_id} file escapes the project root")
    if not source.is_file():
        raise PublishError(f"asset {asset_id} file does not exist: {relative_source}")

    credit = {
        **credit_defaults,
        **_mapping(raw.get("credit"), f"asset {asset_id} credit"),
    }
    normalized_credit = {
        "author": _required_text(credit.get("author"), f"asset {asset_id} author"),
        "author_url": _optional_text(credit.get("author_url")),
        "source": _required_text(credit.get("source"), f"asset {asset_id} source"),
        "source_page": _optional_text(credit.get("source_page")),
        "license": _required_text(credit.get("license"), f"asset {asset_id} license"),
        "license_url": _optional_text(credit.get("license_url")),
        "attribution": _required_text(
            credit.get("attribution"), f"asset {asset_id} attribution"
        ),
    }

    data, width, height = _webp_derivative(source)
    content_hash = hashlib.sha256(data).hexdigest()
    destination = output_dir / f"{content_hash}.webp"
    if not destination.exists():
        destination.write_bytes(data)

    return {
        "id": asset_id,
        "role": role,
        "light_context": light_context,
        "team_ids": team_ids,
        "stadium": _optional_text(raw.get("stadium")),
        "sha256": content_hash,
        "asset_path": f"assets/{content_hash}.webp",
        "content_type": "image/webp",
        "byte_size": len(data),
        "width": width,
        "height": height,
        "credit": normalized_credit,
    }


def _webp_derivative(source: Path) -> tuple[bytes, int, int]:
    from io import BytesIO

    try:
        with Image.open(source) as image:
            if getattr(image, "n_frames", 1) != 1:
                raise PublishError(f"animated images are not supported: {source}")
            normalized = ImageOps.exif_transpose(image).convert("RGB")
            if normalized.width < 300 or normalized.height < 180:
                raise PublishError(f"image is too small to publish: {source}")
            normalized.thumbnail(
                (DEFAULT_MAX_DIMENSION, DEFAULT_MAX_DIMENSION),
                Image.Resampling.LANCZOS,
            )
            output = BytesIO()
            normalized.save(
                output,
                format="WEBP",
                quality=DEFAULT_WEBP_QUALITY,
                method=6,
            )
            return output.getvalue(), normalized.width, normalized.height
    except PublishError:
        raise
    except (OSError, ValueError) as error:
        raise PublishError(f"could not process image {source}: {error}") from error


def _replace_directory(temporary: Path, destination: Path) -> None:
    backup = destination.parent / f".{destination.name}.previous"
    shutil.rmtree(backup, ignore_errors=True)
    if destination.exists():
        os.replace(destination, backup)
    try:
        os.replace(temporary, destination)
    except Exception:
        if backup.exists() and not destination.exists():
            os.replace(backup, destination)
        raise
    shutil.rmtree(backup, ignore_errors=True)


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise PublishError(f"{label} must be an object")
    return value


def _text_list(value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PublishError("expected an array of text values")
    return sorted({_required_text(item, "list value") for item in value})


def _required_text(value: Any, label: str) -> str:
    text = str(value or "").strip()
    if not text:
        raise PublishError(f"{label} is required")
    return text


def _optional_text(value: Any) -> str | None:
    text = str(value or "").strip()
    return text or None


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
