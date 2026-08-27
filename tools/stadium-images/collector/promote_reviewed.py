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
from pathlib import Path

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

import yaml
from find_images import DEFAULT_STAGING_ROOT, _replace_directory, slugify

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
    teams: dict[str, dict] = {}
    assets = []
    copied_count = 0
    try:
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
                team_ids.append(team_id)

            if not team_ids:
                raise ValueError(f"No team assignments in {manifest_path}")

            stadium_slug = str(manifest["slug"])
            destination_directory = temporary / "assets" / stadium_slug
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
                assessment = image.get("assessment") or {}
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
                try:
                    relative_file = destination_file.relative_to(
                        project_root
                    ).as_posix()
                except ValueError as error:
                    raise ValueError(
                        f"Deployment directory must be inside the project root: {deployment_root}"
                    ) from error
                content_hash = actual_hash
                light_context = _light_context(
                    str(assessment.get("lighting") or "unknown")
                )
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
                            "source": "Wikimedia Commons",
                            "source_page": source_page,
                            "license": license_name,
                            "license_url": license_url,
                            "attribution": f"{author}, {license_name}, via Wikimedia Commons",
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


def _light_context(value: str) -> str:
    return "night" if value.casefold() in {"night", "dusk", "indoor"} else "day"


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
    args = parser.parse_args()

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


if __name__ == "__main__":
    main()
