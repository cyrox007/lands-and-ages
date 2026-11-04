extends RefCounted
## Природные объекты не являются частью грунта и не зависят от камеры.

signal objects_changed(chunks: Array[Vector2i], revision: int)

const Terrain = preload("res://scripts/terrain.gd")
const FORMAT_VERSION := 1
const GRID_STEP := 3
const MAX_OBJECTS := 200000
const TREE_SPECIES := ["сосна", "ель", "берёза", "дуб"]

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var last_day := 0
var revision := 0
var generated := false

var _objects: Dictionary = {}
var _chunks: Dictionary = {}


func _init(map: RefCounted, water: RefCounted,
        ground: RefCounted, weather: RefCounted) -> void:
    world = map
    hydro = water
    surface = ground
    climate = weather
    last_day = weather.day


static func _hash(x: int, y: int, seed: int) -> float:
    return Terrain.hash2(x, y, seed)


func _index(object: Dictionary) -> void:
    var cell := Vector2i(int(object["x"]), int(object["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)
    if not _chunks.has(chunk):
        _chunks[chunk] = []
    _chunks[chunk].append(int(object["id"]))


func _mark_changes(changed: Dictionary) -> void:
    if changed.is_empty():
        return
    revision += 1
    var chunks: Array[Vector2i] = []
    for chunk in changed.keys():
        chunks.append(chunk)
    chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.y < b.y or (a.y == b.y and a.x < b.x))
    objects_changed.emit(chunks, revision)


func _species(temperature: float, moisture: float, random: float) -> String:
    if temperature < 7.0:
        return "ель" if moisture > 0.62 and random > 0.33 else "сосна"
    if temperature < 16.0:
        return "берёза" if random < 0.37 else (
            "ель" if moisture > 0.68 else "сосна")
    return "дуб" if moisture > 0.47 else "сосна"


func generate() -> bool:
    # Фиксированная сетка кандидатов исключает зависимость от порядка чанков.
    if generated:
        return false
    hydro.ensure_ready()
    surface.ensure_ready()
    climate.ensure_ready()
    var config: RefCounted = world.config
    for y in range(2, config.height - 1, GRID_STEP):
        for x in range(2, config.width - 1, GRID_STEP):
            var cell := Vector2i(x, y)
            var index: int = hydro.cell_index(cell)
            if hydro.has_water(index):
                continue
            var point := Vector2(float(x) + 0.5, float(y) + 0.5)
            var normal: Vector3 = world.normal_at(cell)
            var slope := 1.0 - normal.y
            if slope > 0.42:
                continue
            var soil: Dictionary = surface.profile_at(cell)
            var moisture: float = float(soil.get("moisture", 0.0))
            var growth: float = float(soil.get("growth_potential", 0.0))
            var temperature: float = climate.temperature_at_index(index)
            var cluster := _hash(x / 21, y / 21, config.seed + 3001)
            var chance := _hash(x, y, config.seed + 3002)
            var kind := ""
            var species := ""
            var density := clampf(growth * 0.48 + moisture * 0.19 +
                cluster * 0.30 - slope * 0.75, 0.0, 0.80)
            if soil.get("substrate") == "скала":
                density *= 0.18
            if chance < density:
                kind = "дерево"
                species = _species(temperature, moisture,
                    _hash(x, y, config.seed + 3003))
            elif chance < density + 0.12 * moisture:
                kind = "кустарник"
                species = "кустарник"
            elif chance > 0.94 and (slope > 0.08 or soil.get("substrate") == "скала"):
                kind = "валун"
                species = "камень"
            if kind.is_empty():
                continue
            var age := 0
            var stock := 0
            if kind == "дерево":
                age = 2 * 96 + int(_hash(x, y, config.seed + 3004) * 38.0 * 96.0)
                stock = maxi(1, age / 96 * 3)
            elif kind == "кустарник":
                age = int(_hash(x, y, config.seed + 3004) * 10.0 * 96.0)
            var id: int = y * int(config.width) + x + 1
            var item := {
                "id": id, "kind": kind, "species": species,
                "x": x, "y": y, "age_days": age,
                "health": 1000, "wood_units": stock, "fallen_wood": 0,
                "state": "целое", "radius": 0.35 if kind == "валун" else (
                    0.21 if kind == "дерево" else 0.12)
            }
            _objects[id] = item
            _index(item)
            if _objects.size() >= MAX_OBJECTS:
                break
        if _objects.size() >= MAX_OBJECTS:
            break
    generated = true
    last_day = climate.day
    return true


func count() -> int:
    return _objects.size()


func object_at(id: int) -> Dictionary:
    return _objects[id].duplicate(true) if _objects.has(id) else {}


func objects_in_chunk(chunk: Vector2i) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for id in _chunks.get(chunk, []):
        result.append(_objects[id].duplicate(true))
    return result


func wood_total() -> int:
    var total := 0
    for item in _objects.values():
        total += int(item["wood_units"]) + int(item["fallen_wood"])
    return total


func _modify(id: int, item: Dictionary) -> void:
    _objects[id] = item
    var changed := {world.config.chunk_of(
        Vector2i(int(item["x"]), int(item["y"]))): true}
    _mark_changes(changed)


func fell_tree(id: int) -> Dictionary:
    # Рубка изменяет физический ресурс; анимация не создаёт древесину.
    var item: Dictionary = object_at(id)
    if item.is_empty() or item["kind"] != "дерево"             or item["state"] != "целое":
        return {}
    var wood := int(item["wood_units"])
    item["wood_units"] = 0
    item["fallen_wood"] = wood
    item["state"] = "пень"
    _modify(id, item)
    return {"id": id, "wood_units": wood, "state": "пень"}


func take_fallen_wood(id: int, amount: int) -> bool:
    var item: Dictionary = object_at(id)
    if item.is_empty() or amount <= 0             or amount > int(item.get("fallen_wood", 0)):
        return false
    item["fallen_wood"] = int(item["fallen_wood"]) - amount
    _modify(id, item)
    return true


func advance_day(day: int) -> int:
    if not generated or day <= last_day or day != climate.day:
        return 0
    var changed := {}
    var updates := 0
    for id in _objects.keys():
        # Восемь очередей: не проверяем всю экосистему в каждом такте.
        if posmod(day - int(id), 8) != 0:
            continue
        var item: Dictionary = _objects[id]
        if item["kind"] == "валун" or item["state"] == "пень":
            continue
        var cell := Vector2i(int(item["x"]), int(item["y"]))
        var index: int = hydro.cell_index(cell)
        if index < 0:
            continue
        var old_state: String = str(item["state"])
        item["age_days"] = int(item["age_days"]) + 8
        var temperature: float = climate.temperature_at_index(index)
        var moisture: float = surface.moisture_at_index(index)
        var flood: bool = hydro.flooded_at(index)
        var stress := int(maxf(0.0, absf(temperature - 12.0) - 23.0) * 1.1)
        if moisture < 0.18:
            stress += 12
        if flood:
            stress += 24
        if stress > 0:
            item["health"] = maxi(0, int(item["health"]) - stress)
        elif int(item["health"]) < 1000:
            item["health"] = mini(1000, int(item["health"]) + 3)
        if int(item["health"]) == 0 and old_state == "целое":
            item["state"] = "сухостой"
        if item["kind"] == "дерево":
            if item["state"] == "целое" and item["age_days"] % 96 < 8:
                item["wood_units"] = int(item["wood_units"]) + (
                    3 if int(item["age_days"]) < 60 * 96 else 1)
            elif item["state"] == "сухостой" and day % 96 < 8:
                item["wood_units"] = maxi(0, int(item["wood_units"]) - 1)
        _objects[id] = item
        updates += 1
        if old_state != str(item["state"]):
            changed[world.config.chunk_of(cell)] = true
    last_day = day
    _mark_changes(changed)
    return updates


func to_data() -> Dictionary:
    var ids := _objects.keys()
    ids.sort()
    var items: Array = []
    for id in ids:
        var entry: Dictionary = _objects[id]
        items.append([
            int(entry["id"]), str(entry["kind"]), str(entry["species"]),
            int(entry["x"]), int(entry["y"]), int(entry["age_days"]),
            int(entry["health"]), int(entry["wood_units"]),
            int(entry["fallen_wood"]), str(entry["state"])
        ])
    return {
        "version": FORMAT_VERSION, "generated": generated,
        "last_day": last_day, "objects": items
    }


func load_data(data: Dictionary) -> bool:
    if data.get("version") != FORMAT_VERSION             or not (data.get("generated") is bool)             or not (data.get("objects") is Array):
        return false
    var day: Variant = data.get("last_day")
    if not (day is int or day is float) or day != climate.day:
        return false
    var raw_items: Array = data["objects"]
    if raw_items.size() > mini(MAX_OBJECTS,
            world.config.width * world.config.height):
        return false
    var restored := {}
    var by_chunk := {}
    for raw in raw_items:
        if not (raw is Array) or raw.size() != 10:
            return false
        for number in [0, 3, 4, 5, 6, 7, 8]:
            if not (raw[number] is int or raw[number] is float)                     or not is_finite(float(raw[number]))                     or float(raw[number]) != float(int(raw[number])):
                return false
        var id := int(raw[0])
        var x := int(raw[3])
        var y := int(raw[4])
        var cell := Vector2i(x, y)
        if id != y * world.config.width + x + 1                 or not world.config.contains_cell(cell) or restored.has(id):
            return false
        if not (raw[1] is String) or not (raw[2] is String)                 or not (raw[9] is String):
            return false
        var kind: String = raw[1]
        if kind not in ["дерево", "кустарник", "валун"]                 or (kind == "дерево" and raw[2] not in TREE_SPECIES)                 or raw[9] not in ["целое", "сухостой", "пень"]:
            return false
        if int(raw[5]) < 0 or int(raw[5]) > 100000000                 or int(raw[6]) < 0 or int(raw[6]) > 1000                 or int(raw[7]) < 0 or int(raw[7]) > 10000000                 or int(raw[8]) < 0 or int(raw[8]) > 10000000:
            return false
        var item := {
            "id": id, "kind": kind, "species": String(raw[2]),
            "x": x, "y": y, "age_days": int(raw[5]),
            "health": int(raw[6]), "wood_units": int(raw[7]),
            "fallen_wood": int(raw[8]), "state": String(raw[9]),
            "radius": 0.35 if kind == "валун" else (
                0.21 if kind == "дерево" else 0.12)
        }
        restored[id] = item
        var chunk: Vector2i = world.config.chunk_of(cell)
        if not by_chunk.has(chunk):
            by_chunk[chunk] = []
        by_chunk[chunk].append(id)
    if not data["generated"] and not raw_items.is_empty():
        return false
    _objects = restored
    _chunks = by_chunk
    generated = bool(data["generated"])
    last_day = int(day)
    revision += 1
    return true
