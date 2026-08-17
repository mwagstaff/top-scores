from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

from ..database import StateDatabase
from ..models import League
from ..output import record_sort_key


def create_review_sheet(
    output_dir: Path,
    database: StateDatabase,
    league: League,
    destination: Path,
    *,
    picks_per_stadium: int = 3,
    thumbnail_size: tuple[int, int] = (320, 180),
) -> int:
    thumbnail_width, thumbnail_height = thumbnail_size
    header_height = 30
    caption_height = 24
    row_height = header_height + thumbnail_height + caption_height
    canvas = Image.new(
        "RGB",
        (thumbnail_width * picks_per_stadium, row_height * len(league.stadiums)),
        (18, 22, 27),
    )
    draw = ImageDraw.Draw(canvas)
    rendered = 0
    for row, stadium in enumerate(league.stadiums):
        y = row * row_height
        draw.text(
            (10, y + 8),
            f"{stadium.name} — {stadium.club}",
            fill=(240, 243, 247),
        )
        records = sorted(
            database.list_images(league.slug, stadium.slug),
            key=record_sort_key,
        )[:picks_per_stadium]
        for column, record in enumerate(records):
            x = column * thumbnail_width
            with Image.open(output_dir / record.local_original_path) as image:
                thumbnail = ImageOps.fit(
                    ImageOps.exif_transpose(image).convert("RGB"),
                    thumbnail_size,
                    method=Image.Resampling.LANCZOS,
                )
            canvas.paste(thumbnail, (x, y + header_height))
            draw.rectangle(
                (
                    x,
                    y + header_height + thumbnail_height,
                    x + thumbnail_width,
                    y + row_height,
                ),
                fill=(30, 36, 43),
            )
            draw.text(
                (x + 7, y + header_height + thumbnail_height + 6),
                f"{record.score:.1f} · {record.time_of_day} · {record.source}",
                fill=(218, 224, 231),
            )
            rendered += 1
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, "JPEG", quality=90, optimize=True)
    return rendered
