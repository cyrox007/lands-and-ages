extends RefCounted
## Природные объекты не являются частью грунта и не зависят от камеры.

signal objects_changed(chunks: Array[Vector2i], revision: int)
signal tree_felled(previous: Dictionary)

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
    if not _objects.has(id):
        return {}
    var item: Dictionary = _objects[id].duplicate(true)
    item["radius"] = footprint_radius(item)
    return item


func objects_in_chunk(chunk: Vector2i) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    for id in _chunks.get(chunk, []):
        result.append(object_at(int(id)))
    return result


static func footprint_radius(item: Dictionary) -> float:
    # Крона не является коллизией; только ствол, пень или валун.
    if item.get("kind") == "валун":
        return 0.35
    if item.get("kind") == "кустарник":
        return 0.0
    if item.get("state") == "пень":
        return 0.15
    return 0.17 * clampf(float(item.get("age_days", 0)) /
        (20.0 * 96.0), 0.20, 1.25)


func intersects_solid(point: Vector2, radius: float = 0.0,
        ignored_id: int = -1) -> bool:
    if not world.config.contains_point(point) or radius < 0.0:
        return true
    # Пространственный поиск ограничен соседними чанками, а не всей картой.
    var size: int = world.config.chunk_size
    var near: int = ceili((radius + 1.0) / float(size)) + 1
    var center: Vector2i = world.config.chunk_of(world.config.cell_at(point))
    for cy in range(center.y - near, center.y + near + 1):
        for cx in range(center.x - near, center.x + near + 1):
            for id in _chunks.get(Vector2i(cx, cy), []):
                if id == ignored_id:
                    continue
                var item: Dictionary = _objects[id]
                var support := footprint_radius(item)
                if support <= 0.0:
                    continue
                var origin := Vector2(float(item["x"]) + 0.5,
                    float(item["y"]) + 0.5)
                if origin.distance_to(point) < support + radius:
                    return true
    return false


func interaction_points(id: int, clearance: float = 0.28) -> Array[Vector2]:
    # Будущие лесорубы используют физические точки подхода, не спрайт.
    var points: Array[Vector2] = []
    var item: Dictionary = object_at(id)
    if item.is_empty() or item["kind"] not in ["дерево", "валун"]:
        return points
    var origin := Vector2(float(item["x"]) + 0.5,
        float(item["y"]) + 0.5)
    var offset := footprint_radius(item) + clearance
    var directions: Array[Vector2] = [
        Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN
    ]
    for direction in directions:
        var point: Vector2 = origin + direction * offset
        if not world.config.contains_point(point):
            continue
        var index: int = hydro.cell_index(world.config.cell_at(point))
        if hydro.has_water(index) or intersects_solid(point, 0.08, id):
            continue
        points.append(point)
    return points


func canopy_pressure_at(cell: Vector2i, ignored_id: int = -1) -> float:
    # Затенение рассчитывается по соседним чанкам, а не по всей карте.
    if not world.config.contains_cell(cell):
        return 0.0
    var chunk: Vector2i = world.config.chunk_of(cell)
    var size: int = world.config.chunk_size
    var range_chunks: int = ceili(5.0 / float(size)) + 1
    var pressure := 0.0
    for cy in range(chunk.y - range_chunks, chunk.y + range_chunks + 1):
        for cx in range(chunk.x - range_chunks, chunk.x + range_chunks + 1):
            for id in _chunks.get(Vector2i(cx, cy), []):
                if int(id) == ignored_id:
                    continue
                var item: Dictionary = _objects[id]
                if item["kind"] != "дерево" or item["state"] != "целое":
                    continue
                var location := Vector2(float(item["x"]), float(item["y"]))
                var distance: float = location.distance_to(Vector2(cell))
                if distance >= 5.0:
                    continue
                var crown: float = clampf(
                    float(item["age_days"]) / (20.0 * 96.0), 0.10, 1.0)
                pressure += (1.0 - distance / 5.0) * crown \
                    * float(item["health"]) / 1000.0
    return minf(3.0, pressure)


func ground_cover_at(cell: Vector2i) -> float:
    # Массовая трава не получает миллион отдельных ID.
    # Её плотность определяется сохранёнными почвой, погодой и деревьями.
    if not world.config.contains_cell(cell):
        return 0.0
    var index: int = hydro.cell_index(cell)
    if hydro.has_water(index) or hydro.flooded_at(index):
        return 0.0
    var soil: Dictionary = surface.profile_at(cell)
    if soil.is_empty():
        return 0.0
    var moisture: float = float(soil.get("moisture", 0.0))
    var fertility: float = float(soil.get("fertility", 0.0))
    var snow: float = float(soil.get("snow", 0.0))
    var temperature: float = climate.temperature_at_index(index)
    var climate_factor := clampf((temperature + 3.0) / 11.0, 0.0, 1.0)
    climate_factor *= clampf((42.0 - temperature) / 12.0, 0.0, 1.0)
    var moisture_factor := clampf((moisture - 0.10) * 1.9, 0.0, 1.0)
    var substrate_factor := 0.18 if soil.get("substrate") == "скала" else 1.0
    var shade := canopy_pressure_at(cell)
    return clampf((0.22 + fertility * 0.78) * moisture_factor
        * climate_factor * (1.0 - snow * 0.90)
        * (1.0 - clampf(shade * 0.36, 0.0, 0.80))
        * substrate_factor, 0.0, 1.0)


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
    # Физика меняется сразу; визуальное падение не производит ресурс.
    var before: Dictionary = object_at(id)
    if before.is_empty() or before["kind"] != "дерево":
        return {}
    if before["state"] not in ["целое", "сухостой"]:
        return {}
    var wood: int = before["wood_units"]
    var item: Dictionary = before.duplicate(true)
    item["wood_units"] = 0
    item["fallen_wood"] = int(item["fallen_wood"]) + wood
    item["state"] = "пень"
    _modify(id, item)
    tree_felled.emit(before)
    return {"id": id, "wood_units": wood, "state": "пень"}


func take_fallen_wood(id: int, amount: int) -> bool:
    var item: Dictionary = object_at(id)
    if item.is_empty() or amount <= 0             or amount > int(item.get("fallen_wood", 0)):
        return false
    item["fallen_wood"] = int(item["fallen_wood"]) - amount
    _modify(id, item)
    return true


func _spread_seeds(day: int, changed: Dictionary) -> int:
    # Один сезон расселения за год; выбор места не зависит от камеры.
    if day % 96 != 1 or _objects.size() >= MAX_OBJECTS:
        return 0
    var current_ids: Array = _objects.keys()
    current_ids.sort()
    var created := 0
    var directions: Array[Vector2i] = [
        Vector2i(GRID_STEP, 0), Vector2i(-GRID_STEP, 0),
        Vector2i(0, GRID_STEP), Vector2i(0, -GRID_STEP)
    ]
    for id in current_ids:
        var parent: Dictionary = _objects[id]
        if parent["kind"] != "дерево" or parent["state"] != "целое" \
                or int(parent["age_days"]) < 12 * 96 \
                or int(parent["health"]) < 650:
            continue
        var x: int = parent["x"]
        var y: int = parent["y"]
        var seed: int = world.config.seed + day * 17
        if _hash(x, y, seed) > 0.16:
            continue
        var direction_index := mini(3, int(_hash(x, y, seed + 1) * 4.0))
        var next: Vector2i = Vector2i(x, y) + directions[direction_index]
        if not world.config.contains_cell(next):
            continue
        var next_id: int = next.y * world.config.width + next.x + 1
        if _objects.has(next_id):
            continue
        var water_index: int = hydro.cell_index(next)
        if hydro.has_water(water_index) or hydro.flooded_at(water_index):
            continue
        if world.normal_at(next).y < 0.75:
            continue
        # Под плотной взрослой кроной молодняку не хватает света.
        if canopy_pressure_at(next) >= 1.10:
            continue
        var soil: Dictionary = surface.profile_at(next)
        if float(soil.get("growth_potential", 0.0)) < 0.20 \
                or float(soil.get("waterlogging", 0.0)) > 0.72:
            continue
        var child: Dictionary = {
            "id": next_id, "kind": "дерево",
            "species": parent["species"], "x": next.x, "y": next.y,
            "age_days": 0, "health": 800, "wood_units": 0,
            "fallen_wood": 0, "state": "целое", "radius": 0.08
        }
        _objects[next_id] = child
        _index(child)
        changed[world.config.chunk_of(next)] = true
        created += 1
        if _objects.size() >= MAX_OBJECTS:
            break
    return created


func _damage_from_events(hazards: Array[Dictionary],
        strikes: Array[Dictionary], changed: Dictionary) -> void:
    # Природные события поражают реальные деревья около эпицентра.
    # Удар вне экрана наносит тот же урон, что и видимый.
    var events: Array[Dictionary] = []
    for event in hazards:
        events.append({
            "cell": event.get("cell"),
            "radius": 5.0,
            "damage": roundi(float(event.get("severity", 0.0)) * 350.0)
        })
    for strike in strikes:
        events.append({
            "cell": strike.get("cell"),
            "radius": 2.5,
            "damage": roundi(float(strike.get("ignition_potential", 0.0)) * 700.0)
        })
    for event in events:
        if not (event["cell"] is Vector2i) or int(event["damage"]) <= 0:
            continue
        var center: Vector2i = event["cell"]
        for id in _objects.keys():
            var item: Dictionary = _objects[id]
            if item["kind"] != "дерево" or item["state"] != "целое":
                continue
            var cell := Vector2i(int(item["x"]), int(item["y"]))
            if Vector2(cell - center).length() > float(event["radius"]):
                continue
            item["health"] = maxi(0, int(item["health"]) - int(event["damage"]))
            if int(item["health"]) == 0:
                item["state"] = "сухостой"
                changed[world.config.chunk_of(cell)] = true
            _objects[id] = item


func advance_day(day: int, hazards: Array[Dictionary] = [],
        strikes: Array[Dictionary] = []) -> int:
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
        var competition := 0.0
        if item["kind"] == "дерево" and item["state"] == "целое":
            competition = canopy_pressure_at(cell, int(id))
            var young: bool = int(item["age_days"]) < 7 * 96
            stress += roundi(maxf(0.0, competition - 0.25)
                * (18.0 if young else 5.0))
        if stress > 0:
            item["health"] = maxi(0, int(item["health"]) - stress)
        elif int(item["health"]) < 1000:
            item["health"] = mini(1000, int(item["health"]) + 3)
        if int(item["health"]) == 0 and old_state == "целое":
            item["state"] = "сухостой"
        if item["kind"] == "дерево":
            if item["state"] == "целое" and item["age_days"] % 96 < 8:
                var annual_increment := 3 if int(item["age_days"]) < 60 * 96 else 1
                if competition > 0.75:
                    annual_increment = maxi(0, annual_increment - 2)
                item["wood_units"] = int(item["wood_units"]) + annual_increment
            elif item["state"] == "сухостой" and day % 96 < 8:
                item["wood_units"] = maxi(0, int(item["wood_units"]) - 1)
        _objects[id] = item
        updates += 1
        if old_state != str(item["state"]):
            changed[world.config.chunk_of(cell)] = true
    updates += _spread_seeds(day, changed)
    _damage_from_events(hazards, strikes, changed)
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
