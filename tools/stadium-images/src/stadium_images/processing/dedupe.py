from __future__ import annotations

import hashlib
from pathlib import Path

import imagehash
from PIL import Image


def calculate_hashes(image_path: Path) -> tuple[str, str]:
    digest = hashlib.sha256()
    with image_path.open("rb") as image_file:
        for chunk in iter(lambda: image_file.read(1024 * 1024), b""):
            digest.update(chunk)
    with Image.open(image_path) as image:
        perceptual_hash = str(imagehash.phash(image.convert("RGB")))
    return digest.hexdigest(), perceptual_hash


def perceptual_distance(first: str, second: str) -> int:
    return int(imagehash.hex_to_hash(first) - imagehash.hex_to_hash(second))
