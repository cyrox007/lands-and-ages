#!/usr/bin/env python3
"""Проверяет узнаваемую анатомию авторских скелетных животных."""

from __future__ import annotations

import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "godot" / "assets" / "fauna"

SPECIES = {
    "Goose": {
        "bones": {"Root", "Neck", "Head", "Beak", "WingLeft",
                  "WingRight", "LegLeft", "LegRight"},
        "forbidden": {"LegFrontLeft", "LegBackLeft", "Snout"},
        "vertical": True,
    },
    "Hare": {
        "bones": {"Root", "Head", "EarLeft", "EarRight", "Tail",
                  "LegFrontLeft", "LegBackLeft"},
        "forbidden": {"Beak", "Snout", "WingLeft"},
        "vertical": True,
    },
    "Hen": {
        "bones": {"Root", "Neck", "Head", "Beak",
                  "WingLeft", "WingRight", "LegLeft", "LegRight"},
        "forbidden": {"LegFrontLeft", "Snout", "TuskLeft"},
        "vertical": True,
    },
    "Cat": {
        "bones": {"Root", "Head", "EarLeft", "EarRight", "Tail",
                  "LegFrontLeft", "LegBackLeft"},
        "forbidden": {"Beak", "WingLeft", "TuskLeft"},
        "vertical": False,
    },
    "Boar": {
        "bones": {"Root", "Head", "Snout", "TuskLeft", "TuskRight",
                  "LegFrontLeft", "LegFrontRight", "LegBackLeft", "LegBackRight"},
        "forbidden": {"Beak", "Neck"},
        "vertical": False,
    },
}


def inspect(species: str, expectations: dict) -> None:
    """Проверяет заголовок GLB, костный скелет и реальные размеры сетки."""
    path = ROOT / f"{species}_LandsAndAges.glb"
    data = path.read_bytes()

    # Сверяем бинарный glTF 2.0, чтобы переименование постороннего
    # ресурса не выглядело для теста корректным новым животным.
    if len(data) < 20 or data[:4] != b"glTF":
        raise ValueError(f"Неверный GLB: {path}")
    version, total, json_length = struct.unpack_from("<III", data, 4)
    if version != 2 or total != len(data):
        raise ValueError(f"Повреждён GLB: {path}")
    document = json.loads(data[20:20 + json_length].decode("utf-8"))

    # Набор костей должен соответствовать конкретному виду. Этим
    # блокируем старую ситуацию: гусь с четырьмя кабаньими ногами.
    names = {node.get("name", "") for node in document["nodes"]}
    if not expectations["bones"] <= names or expectations["forbidden"] & names:
        raise ValueError(f"Неверная анатомия: {species}")
    if len(document.get("skins", [])) != 1:
        raise ValueError(f"Нет отдельного скелета: {species}")

    # Проверяем четыре настоящих анимационных клипа.
    clips = {animation.get("name", "")
             for animation in document.get("animations", [])}
    if not {"Idle", "Walk", "Attack", "Death"} <= clips:
        raise ValueError(f"Неполная анимация: {species}")

    # Собираем фактические границы вершин, а не размеры камеры:
    # проверка работает одинаково на Android и обычном ПК.
    primitives = document["meshes"][0]["primitives"]
    accessors = document["accessors"]
    if not primitives or any("JOINTS_0" not in p["attributes"] or
                             "WEIGHTS_0" not in p["attributes"]
                             for p in primitives):
        raise ValueError(f"Отсутствует skinned mesh: {species}")
    positions = [accessors[p["attributes"]["POSITION"]] for p in primitives]
    spans = [max(a["max"][i] for a in positions) -
             min(a["min"][i] for a in positions) for i in range(3)]

    # У гуся высота шеи выраженно превышает ширину корпуса.
    # У кабана длинное туловище с носом заметно длиннее ширины.
    if expectations["vertical"] and spans[1] <= spans[0] * (1.4 if species == "Hen" else 1.6):
        raise ValueError("Гусь снова выглядит как шарообразный меш")
    if not expectations["vertical"] and spans[2] <= spans[0] * 2.0:
        raise ValueError("У кабана пропал вытянутый силуэт")
    print(f"FAUNA-SHAPE: {species}: кости, анимации, форма — успешно")


def main() -> None:
    """Проверяет оба вида независимо, не скрывая ошибку одной общей моделью."""
    for species, expected in SPECIES.items():
        # Каждой физической популяции назначается строго свой риг.
        inspect(species, expected)


if __name__ == "__main__":
    main()
