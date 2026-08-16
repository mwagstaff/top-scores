from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageOps


def create_hero_derivative(
    source: Path, destination: Path, width: int, height: int
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as image:
        normalized = ImageOps.exif_transpose(image).convert("RGB")
        processed = ImageOps.fit(
            normalized,
            (width, height),
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )
        processed.save(destination, format="WEBP", quality=86, method=6)
