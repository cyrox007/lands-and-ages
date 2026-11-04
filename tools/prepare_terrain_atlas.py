#!/usr/bin/env python3
"""Сборка компактных атласов PBR из фиксированных материалов ambientCG (CC0).

Все исходные архивы скачиваются только при явном запуске скрипта.
Для игры нужны лишь готовые PNG внутри godot/assets/terrain.
"""

from __future__ import annotations

import hashlib
import io
import json
import time
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image

# Порядок соответствует индексам атласа и шейдеру natural_ground.gdshader.
MATERIALS = [
    ("grass", "Grass004"),
    ("soil", "Ground071"),
    ("sand", "Ground027"),
    ("rock", "Rock014"),
    ("gravel", "Gravel001"),
    ("snow", "Snow010A"),
]
BASE = "https://ambientcg.com/get?file="
TARGET = Path(__file__).resolve().parents[1] / "godot/assets/terrain"
STRIDE = 384
BORDER = 8
INNER = STRIDE - 2 * BORDER
RESAMPLE = Image.Resampling.LANCZOS


def download(asset_id: str) -> bytes:
    url = f"{BASE}{asset_id}_1K-JPG.zip"
    last_error = None
    for attempt in range(3):
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": "LandsAndAges/1.0 (CC0 PBR atlas)"}
            )
            with urllib.request.urlopen(request, timeout=90) as response:
                body = response.read(20 * 1024 * 1024)
            if not zipfile.is_zipfile(io.BytesIO(body)):
                raise ValueError(f"Ответ не ZIP: {asset_id}")
            return body
        except (OSError, ValueError) as error:
            last_error = error
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Не удалось получить {asset_id}: {last_error}")


def read_map(archive: zipfile.ZipFile, suffix: str, mode: str) -> Image.Image:
    matches = [
        name for name in archive.namelist()
        if name.lower().endswith("_" + suffix.lower() + ".jpg")
    ]
    if len(matches) != 1:
        raise ValueError(f"Ожидалась одна карта {suffix}, найдено: {matches}")
    with archive.open(matches[0]) as handle:
        image = Image.open(io.BytesIO(handle.read()))
        return image.convert(mode).resize((INNER, INNER), RESAMPLE)


def fill_tile(atlas: Image.Image, tile: Image.Image, index: int) -> None:
    # Бордюр повторяет противоположную кромку того же тайла.
    # Так билинейная фильтрация не смешивает соседние материалы атласа.
    # Вставляем только узкие полосы, а не полную плитку со сдвигом:
    # иначе соседние слоты атласа будут случайно перезаписаны.
    padded = Image.new(tile.mode, (STRIDE, STRIDE))
    padded.paste(tile, (BORDER, BORDER))
    padded.paste(tile.crop((INNER - BORDER, 0, INNER, INNER)),
                 (0, BORDER))
    padded.paste(tile.crop((0, 0, BORDER, INNER)),
                 (BORDER + INNER, BORDER))
    padded.paste(tile.crop((0, INNER - BORDER, INNER, INNER)),
                 (BORDER, 0))
    padded.paste(tile.crop((0, 0, INNER, BORDER)),
                 (BORDER, BORDER + INNER))
    padded.paste(tile.crop((INNER - BORDER, INNER - BORDER, INNER, INNER)),
                 (0, 0))
    padded.paste(tile.crop((0, INNER - BORDER, BORDER, INNER)),
                 (BORDER + INNER, 0))
    padded.paste(tile.crop((INNER - BORDER, 0, INNER, BORDER)),
                 (0, BORDER + INNER))
    padded.paste(tile.crop((0, 0, BORDER, BORDER)),
                 (BORDER + INNER, BORDER + INNER))
    atlas.paste(padded, (index % 3 * STRIDE, index // 3 * STRIDE))


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    size = (STRIDE * 3, STRIDE * 2)
    albedo_atlas = Image.new("RGB", size)
    packed_atlas = Image.new("RGB", size)
    manifest = {
        "license": "CC0 1.0",
        "bake_version": 2,
        "source": "https://ambientcg.com/",
        "tile": STRIDE,
        "border": BORDER,
        "columns": 3,
        "materials": [],
    }

    for index, (name, asset_id) in enumerate(MATERIALS):
        data = download(asset_id)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            color = read_map(archive, "Color", "RGB")
            normal = read_map(archive, "NormalGL", "RGB")
            # У части старых наборов карта шероховатости не опубликована.
            # Явно используем матовую поверхность и фиксируем подстановку.
            try:
                roughness = read_map(archive, "Roughness", "L")
                roughness_source = "Roughness"
            except ValueError:
                roughness = Image.new("L", (INNER, INNER), 224)
                roughness_source = "constant_224"
        red, green, _ = normal.split()
        packed = Image.merge("RGB", (red, green, roughness))
        fill_tile(albedo_atlas, color, index)
        fill_tile(packed_atlas, packed, index)
        manifest["materials"].append({
            "index": index,
            "kind": name,
            "asset": asset_id,
            "url": f"https://ambientcg.com/view?id={asset_id}",
            "archive_sha256": hashlib.sha256(data).hexdigest(),
            "roughness_source": roughness_source,
        })
        print(f"{name}: {asset_id} — цвет, нормали, шероховатость")

    albedo_atlas.save(TARGET / "terrain_albedo.png", optimize=True)
    packed_atlas.save(TARGET / "terrain_normal_roughness.png", optimize=True)
    (TARGET / "sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Шесть реальных PBR-наборов собраны в два игровых атласа.")


if __name__ == "__main__":
    main()
