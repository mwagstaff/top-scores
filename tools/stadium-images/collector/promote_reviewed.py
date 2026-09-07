#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import shutil
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import yaml
from find_images import DEFAULT_STAGING_ROOT, _replace_directory, slugify
from stadium_images.team_folders import identify_team, team_folder

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_DEPLOYMENT_ROOT = Path(__file__).resolve().parent / "deployment"
DEFAULT_PUBLISH_COMMAND = PROJECT_ROOT / "tools/stadium-images/.venv/bin/stadium-images"


def promote_reviewed_images(
    staging_root: Path = DEFAULT_STAGING_ROOT,
    deployment_root: Path = DEFAULT_DEPLOYMENT_ROOT,
    project_root: Path = PROJECT_ROOT,
) -> tuple[Path, int]:
    if not staging_root.is_dir():
        raise FileNotFoundError(f"Staging directory does not exist: {staging_root}")

    manifests = sorted(staging_root.glob("*/manifest.json"))
    if not manifests:
        raise ValueError(f"No stadium manifests found under {staging_root}")

    deployment_root.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(
        tempfile.mkdtemp(prefix=f".{deployment_root.name}-", dir=deployment_root.parent)
    )
    existing_config_path = deployment_root / "publishing.yaml"
    existing_config = (
        yaml.safe_load(existing_config_path.read_text(encoding="utf-8"))
        if existing_config_path.is_file() else {}
    )
    teams: dict[str, dict] = existing_config.get("teams") or {}
    assets = list(existing_config.get("assets") or [])
    copied_count = 0
    try:
        if deployment_root.is_dir():
            shutil.copytree(deployment_root, temporary, dirs_exist_ok=True)
        for manifest_path in manifests:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest.get("schema_version") != 1:
                raise ValueError(f"Unsupported staging manifest: {manifest_path}")
            remaining = [
                image
                for image in manifest.get("staged_images") or []
                if (manifest_path.parent / str(image.get("filename") or "")).is_file()
            ]
            if not remaining:
                continue

            team_ids = []
            for raw_team in manifest.get("teams") or []:
                raw_team = identify_team(raw_team)
                name = str(raw_team.get("name") or "").strip()
                if not name:
                    raise ValueError(f"Missing team name in {manifest_path}")
                team_id = slugify(name)
                aliases = sorted(
                    {
                        str(alias).strip()
                        for alias in raw_team.get("aliases") or []
                        if str(alias).strip()
                        and str(alias).strip().casefold() != name.casefold()
                    }
                )
                existing = teams.get(team_id)
                if existing and existing["name"].casefold() != name.casefold():
                    raise ValueError(f"Team ID collision for {name}: {team_id}")
                if existing:
                    existing["aliases"] = sorted(
                        set(existing["aliases"]) | set(aliases)
                    )
                else:
                    teams[team_id] = {
                        "name": name,
                        "aliases": aliases,
                        "source_team_ids": [],
                        "venue_ids": [],
                    }
                teams[team_id]["bsd_team_id"] = raw_team["bsd_team_id"]
                team_ids.append(team_id)

            if not team_ids:
                raise ValueError(f"No team assignments in {manifest_path}")

            stadium_slug = str(manifest["slug"])
            if len(team_ids) != 1:
                raise ValueError("Stage each club separately, including clubs sharing a stadium")
            folder = team_folder(teams[team_ids[0]])
            destination_directory = temporary / "assets" / folder
            destination_directory.mkdir(parents=True, exist_ok=True)
            for image in remaining:
                filename = str(image["filename"])
                if Path(filename).name != filename:
                    raise ValueError(
                        f"Invalid staged filename in {manifest_path}: {filename}"
                    )
                source_file = manifest_path.parent / filename
                actual_hash = hashlib.sha256(source_file.read_bytes()).hexdigest()
                if actual_hash != str(image.get("sha256") or ""):
                    raise ValueError(
                        f"Staged image hash changed after collection: {source_file}"
                    )
                destination_file = destination_directory / filename
                shutil.copy2(source_file, destination_file)

                metadata = image.get("source") or {}
                author_html = str(
                    metadata.get("artist") or metadata.get("credit") or ""
                )
                author = _plain_text(author_html)
                license_name = _plain_text(str(metadata.get("license") or ""))
                source_page = _optional_url(metadata.get("commons_page"))
                if not author or not license_name or not source_page:
                    raise ValueError(
                        f"Incomplete Wikimedia credit metadata for {source_file}"
                    )
                author_url = _first_link(author_html)
                license_url = _optional_url(metadata.get("license_url"))
                source_name = _plain_text(
                    str(metadata.get("source_name") or "Wikimedia Commons")
                )
                attribution = _plain_text(
                    str(
                        metadata.get("attribution")
                        or f"{author}, {license_name}, via {source_name}"
                    )
                )
                try:
                    relative_file = (deployment_root / "assets" / folder / filename).relative_to(
                        project_root
                    ).as_posix()
                except ValueError as error:
                    raise ValueError(
                        f"Deployment directory must be inside the project root: {deployment_root}"
                    ) from error
                content_hash = actual_hash
                # Lighting is retained only as a legacy wire field; galleries mix freely.
                light_context = "any"
                if any(asset["file"] == relative_file for asset in assets):
                    continue
                assets.append(
                    {
                        "id": f"{stadium_slug}-{light_context}-{content_hash[:10]}",
                        "file": relative_file,
                        "role": "team",
                        "light_context": light_context,
                        "team_ids": sorted(set(team_ids)),
                        "stadium": str(manifest["stadium"]),
                        "credit": {
                            "author": author,
                            "author_url": author_url,
                            "source": source_name,
                            "source_page": source_page,
                            "license": license_name,
                            "license_url": license_url,
                            "attribution": attribution,
                        },
                    }
                )
                copied_count += 1

        if not assets:
            raise ValueError("No reviewed images remain in staging.")
        include_config = {
            "schema_version": 1,
            "teams": dict(sorted(teams.items())),
            "assets": sorted(assets, key=lambda asset: asset["id"]),
        }
        (temporary / "publishing.yaml").write_text(
            yaml.safe_dump(include_config, sort_keys=False, allow_unicode=True),
            encoding="utf-8",
        )
        _replace_directory(temporary, deployment_root)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return deployment_root, copied_count


def _plain_text(value: str) -> str:
    without_tags = re.sub(r"<[^>]+>", " ", value)
    return " ".join(html.unescape(without_tags).split())


def _first_link(value: str) -> str | None:
    match = re.search(r"href=[\"']([^\"']+)[\"']", html.unescape(value), re.IGNORECASE)
    return _optional_url(match.group(1)) if match else None


def _optional_url(value: object) -> str | None:
    text = str(value or "").strip()
    return text if text.startswith(("https://", "http://")) else None


def archive_reviewed_staging(staging_root: Path) -> Path:
    """Keep the review manifests (including rejected filenames) out of new staging."""
    archive = staging_root.parent / "reviewed" / datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    archive.parent.mkdir(parents=True, exist_ok=True)
    staging_root.rename(archive)
    staging_root.mkdir()
    return archive


def organize_existing_images(
    deployment_root: Path = DEFAULT_DEPLOYMENT_ROOT,
    project_root: Path = PROJECT_ROOT,
) -> int:
    """Atomically move approved originals and update their publishing references."""
    config = yaml.safe_load((deployment_root / "publishing.yaml").read_text())
    config["teams"] = {key: identify_team(team) for key, team in config["teams"].items()}
    registered = {(project_root / asset["file"]).resolve() for asset in config["assets"]}
    unregistered = [path for path in (deployment_root / "assets").rglob("*")
                    if path.is_file() and path.name != ".DS_Store" and path.resolve() not in registered]
    if unregistered:
        raise ValueError(f"Add unregistered originals to publishing.yaml before moving: {unregistered}")
    temporary = Path(tempfile.mkdtemp(prefix=".organize-", dir=deployment_root.parent))
    try:
        shutil.copytree(deployment_root, temporary, dirs_exist_ok=True)
        shutil.rmtree(temporary / "assets")
        for asset in config["assets"]:
            source = project_root / asset["file"]
            if len(asset["team_ids"]) != 1:
                raise ValueError(f"Assign one team per reviewed original: {asset['id']}")
            folder = team_folder(config["teams"][asset["team_ids"][0]])
            relative = Path("assets") / folder / source.name
            destination = temporary / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists() and destination.read_bytes() != source.read_bytes():
                relative = relative.with_name(f"{asset['id']}{source.suffix}")
                destination = temporary / relative
            shutil.copy2(source, destination)
            asset["file"] = (deployment_root / relative).relative_to(project_root).as_posix()
        (temporary / "publishing.yaml").write_text(
            yaml.safe_dump(config, sort_keys=False, allow_unicode=True), encoding="utf-8"
        )
        _replace_directory(temporary, deployment_root)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return len(config["assets"])


def run_publisher(command: Path = DEFAULT_PUBLISH_COMMAND) -> None:
    executable = str(command) if command.is_file() else shutil.which("stadium-images")
    if not executable:
        raise FileNotFoundError(
            "stadium-images is not installed; create the documented virtual environment first."
        )
    subprocess.run([executable, "publish"], check=True, cwd=PROJECT_ROOT)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Promote every image left after human staging review and rebuild the "
            "server artwork bundle."
        )
    )
    parser.add_argument("--staging-root", type=Path, default=DEFAULT_STAGING_ROOT)
    parser.add_argument("--deployment-root", type=Path, default=DEFAULT_DEPLOYMENT_ROOT)
    parser.add_argument("--no-publish", action="store_true")
    parser.add_argument("--organize-existing", action="store_true",
                        help="Move approved originals into team name/BSD ID directories")
    args = parser.parse_args()

    if args.organize_existing:
        count = organize_existing_images(args.deployment_root)
        print(f"Organized {count} approved originals by team")
        if not args.no_publish:
            run_publisher()
        return

    destination, count = promote_reviewed_images(
        staging_root=args.staging_root,
        deployment_root=args.deployment_root,
    )
    print(f"Promoted {count} reviewed image(s) to {destination}")
    if not args.no_publish:
        run_publisher()
        print(
            "Rebuilt the persistent deployment bundle under tools/stadium-images/published."
        )
        print(f"Archived reviewed staging at {archive_reviewed_staging(args.staging_root)}")


if __name__ == "__main__":
    main()
