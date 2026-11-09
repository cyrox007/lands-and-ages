extends RefCounted
## Реестр измеримых природных источников этапа 12.
## Древесина остаётся исключительно в NatureRegistry этапа 10.

const FORMAT_VERSION := 1
const MAX_SOURCES := 200000
const MAX_UNITS := 1000000000

var world: RefCounted
var _sources: Dictionary = {}
var revision := 0

func _init(map: RefCounted) -> void:
    # Привязка к физическому миру исключает произвольные координаты.
    world = map

static func source_id(kind: String, cell: Vector2i) -> String:
    # Строковый ключ сохраняет однозначность между видами и клетками.
    return "%s:%d:%d" % [kind, cell.x, cell.y]

func _valid_entry(item: Dictionary) -> bool:
    # Сначала проверяем типы; данные из сохранения могут быть повреждены.
    for key in ["id", "kind", "material"]:
        if not (item.get(key) is String) or String(item[key]).is_empty():
            return false
    for key in ["x", "y", "quality", "initial_units", "remaining_units"]:
        var value: Variant = item.get(key)
        if not (value is int or value is float):
            return false
        if not is_finite(float(value)) or float(value) != float(int(value)):
            return false
    var cell := Vector2i(int(item["x"]), int(item["y"]))
    if not world.config.contains_cell(cell):
        return false
    if item["kind"] == "древесина":
        return false
    if item["id"] != source_id(String(item["kind"]), cell):
        return false
    var total := int(item["initial_units"])
    var amount := int(item["remaining_units"])
    var quality := int(item["quality"])
    return total > 0 and total <= MAX_UNITS and amount >= 0 \
        and amount <= total and quality >= 0 and quality <= 1000

func add_source(kind: String, material: String, cell: Vector2i,
        units: int, quality: int) -> bool:
    # Создаём лишь источник, найденный внешней геологической моделью.
    # Никакой добычи или товара на складе этот метод не создаёт.
    var id := source_id(kind, cell)
    var item := {
        "id": id, "kind": kind, "material": material,
        "x": cell.x, "y": cell.y,
        "initial_units": units, "remaining_units": units,
        "quality": quality
    }
    if _sources.has(id) or _sources.size() >= MAX_SOURCES \
            or not _valid_entry(item):
        return false
    _sources[id] = item
    revision += 1
    return true

func source_at(kind: String, cell: Vector2i) -> Dictionary:
    # Возвращаем копию, чтобы вызывающий код не менял запасы напрямую.
    var item: Dictionary = _sources.get(source_id(kind, cell), {})
    return item.duplicate(true)

func extract(id: String, units: int) -> int:
    # Забираем только реально существующее сырьё без отрицательных запасов.
    if units <= 0 or not _sources.has(id):
        return 0
    var item: Dictionary = _sources[id]
    var taken := mini(units, int(item["remaining_units"]))
    if taken == 0:
        return 0
    item["remaining_units"] = int(item["remaining_units"]) - taken
    _sources[id] = item
    revision += 1
    return taken

func to_data() -> Dictionary:
    # Сортировка обеспечивает одинаковую сериализацию при любом порядке ввода.
    var ids := _sources.keys()
    ids.sort()
    var items: Array = []
    for id in ids:
        items.append((_sources[id] as Dictionary).duplicate(true))
    return {"version": FORMAT_VERSION, "sources": items}

func load_data(data: Dictionary) -> bool:
    # Сначала валидируем весь снимок и лишь потом меняем текущий мир.
    if data.get("version") != FORMAT_VERSION or not (data.get("sources") is Array):
        return false
    var entries: Array = data["sources"]
    if entries.size() > MAX_SOURCES:
        return false
    var restored := {}
    for entry in entries:
        if not (entry is Dictionary) or not _valid_entry(entry):
            return false
        var id: String = entry["id"]
        if restored.has(id):
            return false
        restored[id] = (entry as Dictionary).duplicate(true)
    _sources = restored
    revision += 1
    return true
