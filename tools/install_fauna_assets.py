#!/usr/bin/env python3
"""Устанавливает настоящие анимированные CC0-модели фауны для Godot.

Программа НЕ рисует животных из примитивов. Загрузка выполняется только
при сборке/подготовке проекта; сама игра не зависит от внешней сети.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "godot" / "assets" / "fauna"
QUATERNIUS = (
    "https://raw.githubusercontent.com/agentkaerf/FreeModels/main/"
    "Ultimate%20Animated%20Animals%20-%20July%202021/glTF/"
)
ASSETS = {
    "олень": ("Deer.gltf", QUATERNIUS + "Deer.gltf", "Quaternius"),
    "взрослый олень": ("Stag.gltf", QUATERNIUS + "Stag.gltf", "Quaternius"),
    "волк": ("Wolf.gltf", QUATERNIUS + "Wolf.gltf", "Quaternius"),
    "лиса": ("Fox.gltf", QUATERNIUS + "Fox.gltf", "Quaternius"),
    "корова": ("Cow.gltf", QUATERNIUS + "Cow.gltf", "Quaternius"),
    "собака": ("Husky.gltf", QUATERNIUS + "Husky.gltf", "Quaternius"),
    "кабан": (
        "Boar.glb", "https://gobkit.com/freebies/animalB/Boar.glb", "Gobkit"
    ),
}
SOURCES = {
    "Quaternius": "https://quaternius.com/packs/ultimateanimatedanimals.html",
    "Gobkit": "https://gobkit.itch.io/gobkit-free-animal-pack-vol-2",
}
MAX_BYTES = 40 * 1024 * 1024


def fetch(url: str) -> bytes:
    """Скачивает строго определённый исходный ассет по HTTPS.

    Ограничение размера защищает машину сборки от непредвиденно
    увеличенного файла, а разрешённые домены исключают чужие ссылки.
    """
    allowed = ("raw.githubusercontent.com", "gobkit.com")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in allowed:
        raise ValueError("Источник ассета не разрешён: " + url)
    request = urllib.request.Request(url, headers={
        "User-Agent": "LandsAndAges-CC0-AssetInstaller/1.0"
    })
    with urllib.request.urlopen(request, timeout=40) as response:
        data = response.read(MAX_BYTES + 1)
    if not data or len(data) > MAX_BYTES:
        raise ValueError("Файл пустой или превышает допустимый размер")
    return data


def document(data: bytes, filename: str) -> dict:
    """Извлекает glTF-документ из текста или бинарного контейнера GLB.

    Проверка требует настоящий полигональный меш, скелет и анимацию;
    файл со схемой коробки или статической картинкой не пройдёт.
    """
    if filename.endswith(".gltf"):
        model = json.loads(data.decode("utf-8"))
    else:
        if len(data) < 20 or data[:4] != b"glTF":
            raise ValueError("Некорректный заголовок GLB")
        version, length, block_size, block_type = struct.unpack_from(
            "<IIII", data, 4
        )
        if version != 2 or length != len(data) or block_type != 0x4E4F534A:
            raise ValueError("Некорректные блоки GLB")
        model = json.loads(data[20:20 + block_size].rstrip(b"\x00 ").decode("utf-8"))
    if not model.get("meshes") or not model.get("skins") or not model.get("animations"):
        raise ValueError("У животного нет полноценного меша, рига или анимаций")
    joints = max(len(skin.get("joints", [])) for skin in model["skins"])
    if joints < 8:
        raise ValueError("Скелет недостаточен для движения животного")
    if not any(mesh.get("primitives") for mesh in model["meshes"]):
        raise ValueError("Отсутствует полигональная геометрия")
    return model


def dependencies(model: dict) -> list[str]:
    """Находит внешние файлы glTF, не позволяя выйти из каталога.

    Встроенные base64-буферы не скачиваются повторно, внешние
    изображения и .bin получают тот же подтверждённый источник.
    """
    result: set[str] = set()
    for item in model.get("buffers", []) + model.get("images", []):
        name = str(item.get("uri", ""))
        if not name or name.startswith("data:"):
            continue
        if Path(name).name != name or "/" in name or "\\" in name:
            raise ValueError("Недопустимый путь внешнего буфера: " + name)
        result.add(name)
    return sorted(result)


def install(check_only: bool) -> None:
    """Устанавливает модели и фиксирует происхождение каждого файла.

    Файлы не перегружаются при проверке уже готового набора. В конце
    сохраняются хеши и метаданные лицензии для воспроизводимой сборки.
    """
    DESTINATION.mkdir(parents=True, exist_ok=True)
    manifest = {"license": "CC0-1.0", "models": {}}
    for kind, (filename, url, author) in ASSETS.items():
        target = DESTINATION / filename
        if check_only and not target.exists():
            raise FileNotFoundError("Не установлен вид: " + kind)
        data = target.read_bytes() if target.exists() else fetch(url)
        gltf = document(data, filename)
        if not target.exists():
            target.write_bytes(data)
        # Подтягиваем только реальные внешние текстуры/буферы glTF.
        files = [filename]
        for name in dependencies(gltf):
            dependency = DESTINATION / name
            if check_only and not dependency.exists():
                raise FileNotFoundError("Недостаёт внешнего файла: " + name)
            if not dependency.exists():
                dependency.write_bytes(fetch(url.rsplit("/", 1)[0] + "/" + name))
            files.append(name)
        manifest["models"][kind] = {
            "file": filename, "author": author,
            "source": SOURCES[author], "license": "CC0-1.0",
            "skins": len(gltf["skins"]),
            "joints": max(len(s["joints"]) for s in gltf["skins"]),
            "animations": [a.get("name", "") for a in gltf["animations"]],
            "sha256": hashlib.sha256(data).hexdigest(),
            "files": files
        }
        print(f"Модель {kind}: скелет и {len(gltf['animations'])} анимаций")
    (DESTINATION / "asset_provenance.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="Проверить уже установленные ассеты")
    args = parser.parse_args()
    install(args.check)
