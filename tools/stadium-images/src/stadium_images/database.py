from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from typing import Self

from .models import ImageRecord


class StateDatabase:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self._create_schema()

    def close(self) -> None:
        self.connection.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _create_schema(self) -> None:
        self.connection.executescript(
            """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS candidate_state (
                league TEXT NOT NULL,
                stadium_slug TEXT NOT NULL,
                source TEXT NOT NULL,
                source_id TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                status TEXT NOT NULL,
                reason TEXT,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (league, stadium_slug, source, source_id, fingerprint)
            );
            CREATE TABLE IF NOT EXISTS images (
                league TEXT NOT NULL,
                stadium_slug TEXT NOT NULL,
                image_id TEXT NOT NULL,
                source TEXT NOT NULL,
                source_id TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                perceptual_hash TEXT NOT NULL,
                record_json TEXT NOT NULL,
                PRIMARY KEY (league, stadium_slug, image_id)
            );
            CREATE INDEX IF NOT EXISTS images_sha256
                ON images (league, stadium_slug, sha256);
            """
        )
        self.connection.commit()

    def candidate_status(
        self,
        league: str,
        stadium_slug: str,
        source: str,
        source_id: str,
        fingerprint: str,
    ) -> str | None:
        row = self.connection.execute(
            """
            SELECT status FROM candidate_state
            WHERE league = ? AND stadium_slug = ? AND source = ?
              AND source_id = ? AND fingerprint = ?
            """,
            (league, stadium_slug, source, source_id, fingerprint),
        ).fetchone()
        return str(row["status"]) if row else None

    def set_candidate_status(
        self,
        league: str,
        stadium_slug: str,
        source: str,
        source_id: str,
        fingerprint: str,
        status: str,
        reason: str | None = None,
    ) -> None:
        self.connection.execute(
            """
            INSERT INTO candidate_state (
                league, stadium_slug, source, source_id, fingerprint,
                status, reason, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (league, stadium_slug, source, source_id, fingerprint)
            DO UPDATE SET status = excluded.status, reason = excluded.reason,
                          updated_at = excluded.updated_at
            """,
            (
                league,
                stadium_slug,
                source,
                source_id,
                fingerprint,
                status,
                reason,
                datetime.now(UTC).isoformat(),
            ),
        )
        self.connection.commit()

    def save_image(self, record: ImageRecord) -> None:
        self.connection.execute(
            """
            INSERT INTO images (
                league, stadium_slug, image_id, source, source_id,
                sha256, perceptual_hash, record_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (league, stadium_slug, image_id)
            DO UPDATE SET source = excluded.source, source_id = excluded.source_id,
                          sha256 = excluded.sha256,
                          perceptual_hash = excluded.perceptual_hash,
                          record_json = excluded.record_json
            """,
            (
                record.league,
                record.stadium_slug,
                record.id,
                record.source,
                record.source_id,
                record.sha256,
                record.perceptual_hash,
                json.dumps(record.to_dict(), ensure_ascii=False, sort_keys=True),
            ),
        )
        self.connection.commit()

    def list_images(
        self, league: str, stadium_slug: str | None = None
    ) -> list[ImageRecord]:
        if stadium_slug is None:
            rows = self.connection.execute(
                "SELECT record_json FROM images WHERE league = ?",
                (league,),
            ).fetchall()
        else:
            rows = self.connection.execute(
                "SELECT record_json FROM images WHERE league = ? AND stadium_slug = ?",
                (league, stadium_slug),
            ).fetchall()
        return [ImageRecord.from_dict(json.loads(row["record_json"])) for row in rows]

    def list_all_images(self) -> list[ImageRecord]:
        rows = self.connection.execute("SELECT record_json FROM images").fetchall()
        return [ImageRecord.from_dict(json.loads(row["record_json"])) for row in rows]

    def find_exact_duplicate(
        self, league: str, stadium_slug: str, sha256: str
    ) -> ImageRecord | None:
        row = self.connection.execute(
            """
            SELECT record_json FROM images
            WHERE league = ? AND stadium_slug = ? AND sha256 = ?
            LIMIT 1
            """,
            (league, stadium_slug, sha256),
        ).fetchone()
        return ImageRecord.from_dict(json.loads(row["record_json"])) if row else None

    def delete_image(self, record: ImageRecord) -> None:
        self.connection.execute(
            "DELETE FROM images WHERE league = ? AND stadium_slug = ? AND image_id = ?",
            (record.league, record.stadium_slug, record.id),
        )
        self.connection.commit()
