"""Нарезка черновых игровых ассетов из исходных концепт-листов.

Запуск: pip install pillow opencv-python numpy
        python tools/extract_hq_worker_concepts.py --output-dir /tmp/hq-drafts
"""
from argparse import ArgumentParser
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = {
    "headquarters": ROOT / "assets/headquarters/source/headquarters-concept.png",
    "workers": ROOT / "assets/workers/source/workers-concept.png",
}
BOXES = {
    "headquarters": {
        "headquarters-level1": (16, 78, 384, 409),
        "headquarters-foundation": (17, 467, 202, 594),
        "headquarters-frame": (215, 453, 420, 595),
        "headquarters-walls": (440, 450, 641, 598),
        "headquarters-roof": (639, 445, 852, 594),
        "headquarters-complete": (850, 439, 1054, 597),
        "headquarters-light-damage": (18, 860, 188, 994),
        "headquarters-heavy-damage": (189, 857, 359, 994),
        "headquarters-fresh-ruins": (365, 848, 518, 997),
        "headquarters-old-ruins": (532, 848, 686, 998),
        "headquarters-module-core": (407, 40, 614, 166),
        "headquarters-module-wing": (619, 42, 802, 165),
        "headquarters-module-cupola": (788, 28, 947, 173),
        "headquarters-module-roof": (953, 43, 1114, 165),
        "headquarters-module-flag": (790, 226, 885, 375),
        "headquarters-module-gate": (404, 235, 551, 347),
        "headquarters-module-loading": (1159, 210, 1395, 347),
    },
    "workers": {
        "builder": (16, 600, 140, 773),
        "porter": (135, 599, 262, 775),
        "logger": (250, 600, 383, 775),
        "quarry-worker": (380, 600, 511, 775),
        "farmer": (500, 600, 653, 775),
    },
}


def cutout(image, rectangle):
    """Отделяет предмет от однородной подложки; результат требует ручной чистки."""
    rgb = np.array(image.crop(rectangle).convert("RGB"))
    height, width = rgb.shape[:2]
    mask = np.full((height, width), cv2.GC_PR_BGD, np.uint8)
    border = max(3, min(width, height) // 30)
    mask[:border] = cv2.GC_BGD
    mask[-border:] = cv2.GC_BGD
    mask[:, :border] = cv2.GC_BGD
    mask[:, -border:] = cv2.GC_BGD

    # Отличающиеся по цвету области позволяют сохранить светлую кладку и одежду.
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    outer = np.concatenate([lab[:border].reshape(-1, 3),
                            lab[-border:].reshape(-1, 3)])
    distance = np.linalg.norm(lab - np.median(outer, axis=0), axis=2)
    mask[distance > 50] = cv2.GC_FGD
    mask[:border] = cv2.GC_BGD
    mask[-border:] = cv2.GC_BGD
    try:
        cv2.grabCut(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR), mask, None,
                    np.zeros((1, 65), np.float64),
                    np.zeros((1, 65), np.float64), 7, cv2.GC_INIT_WITH_MASK)
    except cv2.error:
        pass
    alpha = np.uint8(np.isin(mask, [cv2.GC_FGD, cv2.GC_PR_FGD]) * 255)
    alpha = cv2.GaussianBlur(alpha, (3, 3), 0.6)
    return Image.fromarray(np.dstack([rgb, alpha]), "RGBA")


def square(sprite, size):
    sprite.thumbnail((size - 12, size - 12), Image.Resampling.LANCZOS)
    result = Image.new("RGBA", (size, size))
    result.alpha_composite(sprite, ((size - sprite.width) // 2,
                                   size - sprite.height - 6))
    return result


def main():
    parser = ArgumentParser(description="Пересоздать черновые изображения из исходников")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    for group, images in BOXES.items():
        image = Image.open(SOURCE[group])
        destination = args.output_dir / group
        destination.mkdir(parents=True, exist_ok=True)
        for name, bounds in images.items():
            size = 384 if name == "headquarters-level1" else 224
            asset = square(cutout(image, bounds), size)
            asset.save(destination / (name + ".webp"), "WEBP", quality=88)
            print(group, name, size)


if __name__ == "__main__":
    main()
