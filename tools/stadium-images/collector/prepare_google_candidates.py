#!/usr/bin/env python3

"""Convert a user-approved Google Images review batch into collector manifests."""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlparse

from _runtime import ensure_collector_runtime

ensure_collector_runtime()

from find_images import DEFAULT_STAGING_ROOT, slugify
from stadium_images.team_folders import identities


APPROVAL_NOTE = (
    "Project owner confirmed no restrictions for reuse after reviewing the Google "
    "Images usage-rights information on 2026-09-06."
)


def _candidate_filename(candidate: dict) -> str:
    return str(candidate.get("filename") or candidate.get("file") or "").strip()


def _candidate_source_page(candidate: dict) -> str:
    return str(candidate.get("source_page") or "").strip()


def _candidate_source_url(candidate: dict) -> str:
    return str(candidate.get("image_url") or candidate.get("source_url") or "").strip()


def _publisher(source_page: str) -> str:
    hostname = (urlparse(source_page).hostname or "Original publisher").removeprefix("www.")
    return hostname


def prepare_google_candidates(staging_root: Path = DEFAULT_STAGING_ROOT) -> int:
    queue_path = staging_root / "_review" / "queue.json"
    queue = json.loads(queue_path.read_text(encoding="utf-8"))
    known = identities()
    prepared_count = 0

    for row in queue:
        team_name = str(row["team"])
        team_slug = slugify(team_name)
        identity = known.get(team_slug)
        if identity is None:
            matches = [
                value
                for value in known.values()
                if team_slug in {slugify(alias) for alias in value.get("aliases") or []}
            ]
            if len(matches) == 1:
                identity = matches[0]
        if identity is None:
            raise ValueError(f"No verified team identity for {team_name}")
        bsd_team_id = str(identity["bsd_team_id"])
        folder_name = f"{team_slug}-{bsd_team_id}"
        destination = staging_root / folder_name
        current_folder = row.get("folder")
        source = staging_root / str(current_folder) if current_folder else staging_root / "unmapped" / team_slug
        if source != destination and source.exists():
            if destination.exists():
                raise FileExistsError(f"Both source and destination exist for {team_name}")
            source.rename(destination)
        if not destination.is_dir():
            raise FileNotFoundError(f"Missing candidate folder for {team_name}: {destination}")

        row["bsd_team_id"] = bsd_team_id
        row["folder"] = folder_name
        row["identity_verified"] = True
        row["identity_source"] = (
            "https://api.skynolimit.dev/top-scores/api/v1/teams/catalog"
        )

        sidecar_path = destination / "candidates.json"
        sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        sidecar["bsd_team_id"] = bsd_team_id
        sidecar["team_folder"] = folder_name
        sidecar["review_status"] = "approved"
        sidecar["reuse_approval"] = {
            "status": "approved_for_reuse",
            "approved_by": "project_owner",
            "approved_at": "2026-09-06",
            "basis": APPROVAL_NOTE,
        }

        staged_images = []
        for candidate in sidecar.get("candidates") or []:
            filename = _candidate_filename(candidate)
            if not filename or Path(filename).name != filename:
                raise ValueError(f"Invalid candidate filename in {sidecar_path}: {filename}")
            image_path = destination / filename
            if not image_path.is_file():
                raise FileNotFoundError(image_path)
            sha256 = hashlib.sha256(image_path.read_bytes()).hexdigest()
            recorded_hash = str(candidate.get("sha256") or "")
            if recorded_hash and recorded_hash != sha256:
                raise ValueError(f"Hash mismatch for {image_path}")

            if "discovery_license_status" not in candidate:
                candidate["discovery_license_status"] = candidate.get(
                    "license_status", candidate.get("licence_status")
                )
            if candidate.get("license_note") and "discovery_license_note" not in candidate:
                candidate["discovery_license_note"] = candidate["license_note"]
            candidate["license_status"] = "approved_for_reuse"
            candidate["license_note"] = APPROVAL_NOTE
            candidate["review_status"] = "approved"

            source_page = _candidate_source_page(candidate)
            if not source_page.startswith(("https://", "http://")):
                raise ValueError(f"Missing source page for {image_path}")
            publisher = _publisher(source_page)
            staged_images.append(
                {
                    "filename": filename,
                    "sha256": sha256,
                    "byte_size": image_path.stat().st_size,
                    "assessment": {
                        "suitable": True,
                        "reason": "Approved by the project owner in the local review gallery.",
                    },
                    "source": {
                        "title": str(candidate.get("title") or filename),
                        "thumbnail_url": _candidate_source_url(candidate),
                        "original_url": _candidate_source_url(candidate),
                        "width": candidate.get("width"),
                        "height": candidate.get("height"),
                        "artist": publisher,
                        "license": "Reuse permitted (verified by project owner)",
                        "license_url": None,
                        "credit": publisher,
                        "description": APPROVAL_NOTE,
                        "commons_page": source_page,
                        "source_name": publisher,
                        "attribution": (
                            f"{publisher}; reuse permission verified by project owner. "
                            f"Source: {source_page}"
                        ),
                    },
                }
            )
            prepared_count += 1

        sidecar_path.write_text(
            json.dumps(sidecar, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        manifest = {
            "schema_version": 1,
            "generated_at": datetime.now(UTC).isoformat(),
            "stadium": str(row.get("stadium") or ""),
            "slug": str(row.get("stadium_slug") or slugify(str(row.get("stadium") or team_name))),
            "teams": [
                {
                    "name": team_name,
                    "aliases": identity.get("aliases") or [],
                    "bsd_team_id": bsd_team_id,
                }
            ],
            "candidate_count": len(staged_images),
            "minimum_score": 0,
            "analysis_summary": "Approved by the project owner in the local review gallery.",
            "staged_images": staged_images,
            "download_errors": [],
        }
        (destination / "manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    queue_path.write_text(
        json.dumps(queue, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return prepared_count


if __name__ == "__main__":
    count = prepare_google_candidates()
    print(f"Prepared {count} user-approved Google Images candidate(s) for promotion")
