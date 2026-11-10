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
    "тур": ("Bull.gltf", QUATERNIUS + "Bull.gltf", "Quaternius"),
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
PINNED_GIT_BLOBS = {
    "Deer.gltf": "7c8abdd5018ea0869a85d6eb8056c0d4f673fd0e",
    "Bull.gltf": "2c501bc7f6d6237322206db027e4b7fb41eace37",
    "Wolf.gltf": "36f718eabfc65c25c971acfd3ef73b5fcc3fc7b9",
    "Fox.gltf": "fded2c7ed91ef52729d6fe7c1345d8438620f33d",
    "Cow.gltf": "f90a67b34818693e418c1cf6ae5c9565ec1d90fc",
    "Husky.gltf": "cece6d1fc74ad0c0e37ac59cb766274838e938c3",
}
# Следующие виды доступны только как настоящие скелетные GLB.
# Их точные адреса берём из официального CC0-манифеста, а не
# угадываем по имени файла и не подменяем чужим животным.
GOBKIT_SPECIES = {
    "заяц": ("Hare.glb", "Hare"),
    "дикий гусь": ("Goose.glb", "Goose"),
    "курица": ("Rooster.glb", "Rooster"),
}
GOBKIT_MANIFEST = "https://gobkit.com/api/free"
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


def resolve_gobkit(check_only: bool) -> dict[str, tuple[str, str, str]]:
    """Проверяет происхождение новых скелетных животных.

    При установке читаем живой официальный каталог CC0; при повторной
    локальной проверке используем уже сохранённый проверенный адрес,
    чтобы проверка не зависела от работающего интернета.
    """
    located = {}
    if check_only:
        manifest_file = DESTINATION / "asset_provenance.json"
        if not manifest_file.exists():
            raise FileNotFoundError("Нет списка происхождения GLB-моделей")
        previous = json.loads(manifest_file.read_text(encoding="utf-8"))
        for kind, (filename, _) in GOBKIT_SPECIES.items():
            record = previous.get("models", {}).get(kind, {})
            if record.get("file") != filename or not record.get("download_url"):
                raise ValueError("Нет подтверждённого первоисточника: " + kind)
            located[kind] = (filename, record["download_url"], "Gobkit")
        return located

    catalogue = json.loads(fetch(GOBKIT_MANIFEST).decode("utf-8"))
    for pack in catalogue.get("packs", []):
        if "CC0" not in str(pack.get("license", "")):
            continue
        for model in pack.get("models", []):
            name = str(model.get("name", "")).casefold()
            if not model.get("rigged") or not model.get("animations"):
                continue
            if "CC0" not in str(model.get("license", "")):
                continue
            for kind, (filename, expected) in GOBKIT_SPECIES.items():
                if name != expected.casefold() or kind in located:
                    continue
                address = str(model.get("url", ""))
                parsed = urllib.parse.urlparse(address)
                if parsed.scheme != "https" or parsed.hostname != "gobkit.com" \
                        or not address.endswith("/" + filename):
                    continue
                located[kind] = (filename, address, "Gobkit")
    absent = sorted(set(GOBKIT_SPECIES) - set(located))
    if absent:
        raise ValueError("В официальном CC0-каталоге нет видов: "
                         + ", ".join(absent))
    return located


def install(check_only: bool) -> None:
    """Устанавливает модели и фиксирует происхождение каждого файла.

    Файлы не перегружаются при проверке уже готового набора. В конце
    сохраняются хеши и метаданные лицензии для воспроизводимой сборки.
    """
    DESTINATION.mkdir(parents=True, exist_ok=True)
    existing = {}
    provenance = DESTINATION / "asset_provenance.json"
    if check_only and provenance.exists():
        existing = json.loads(provenance.read_text(encoding="utf-8")).get(
            "models", {})
    models = {**ASSETS, **resolve_gobkit(check_only)}
    manifest = {"license": "CC0-1.0", "models": {}}
    for kind, (filename, url, author) in models.items():
        target = DESTINATION / filename
        if check_only and not target.exists():
            raise FileNotFoundError("Не установлен вид: " + kind)
        data = target.read_bytes() if target.exists() else fetch(url)
        # Фиксированный Git-blob хеш основного glTF обнаруживает
        # замену файла на зеркале, в том числе при повторной сборке.
        if filename in PINNED_GIT_BLOBS:
            header = f"blob {len(data)}".encode("utf-8") + bytes([0])
            if hashlib.sha1(header + data).hexdigest() != PINNED_GIT_BLOBS[filename]:
                raise ValueError("Изменился проверенный исходный ассет: " + filename)
        if check_only:
            previous_hash = existing.get(kind, {}).get("sha256")
            if previous_hash and hashlib.sha256(data).hexdigest() != previous_hash:
                raise ValueError("Изменён ранее проверенный файл: " + filename)
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
            "download_url": url,
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
