extends RefCounted
## Природные объекты не являются частью грунта и не зависят от камеры.

signal objects_changed(chunks: Array[Vector2i], revision: int)
signal tree_felled(previous: Dictionary)
signal tree_struck(previous: Dictionary, cut_progress: int)

const Terrain = preload("res://scripts/terrain.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")
const FORMAT_VERSION := 4
const DEADWOOD_FALL_DAYS := 2 * 96
const DEADWOOD_VARIATION_DAYS := 96
const LOG_DECAY_INTERVAL_DAYS := 96
const SHRUB_DECAY_DAYS := 96
const STUMP_DECAY_DAYS := 6 * 96
const CUT_THRESHOLD := 1000
const GRID_STEP := 3
const MAX_OBJECTS := 200000
const MAX_VISIBLE_WINDFALL_RECORDS := 64
const TREE_SPECIES := ["сосна", "ель", "берёза", "дуб"]

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var last_day := 0
var revision := 0
var generated := false
# Переходы только последнего дня для анимации после фоновой физики.
# События не сериализуются: дерево и его упавший ствол уже сохранены.
var last_windfalls: Array[Dictionary] = []

var _objects: Dictionary = {}
var _chunks: Dictionary = {}


func _init(map: RefCounted, water: RefCounted,
        ground: RefCounted, weather: RefCounted) -> void:
    world = map
    hydro = water
    surface = ground
    climate = weather
    last_day = weather.day


static func _hash(x: int, y: int, world_seed: int) -> float:
    return Terrain.hash2(x, y, world_seed)


func _index(object: Dictionary) -> void:
    var cell := Vector2i(int(object["x"]), int(object["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)
    if not _chunks.has(chunk):
        _chunks[chunk] = []
    _chunks[chunk].append(int(object["id"]))


func _remove_object(id: int, item: Dictionary,
        changed: Dictionary) -> void:
    var cell := Vector2i(int(item["x"]), int(item["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)
    var ids: Array = _chunks.get(chunk, [])
    ids.erase(id)
    if ids.is_empty():
        _chunks.erase(chunk)
    else:
        _chunks[chunk] = ids
    _objects.erase(id)
    changed[chunk] = true


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
            var normal: Vector3 = world.normal_at(cell)
            var slope := 1.0 - normal.y
            if slope > 0.42:
                continue
            var soil: Dictionary = surface.profile_at(cell)
            var moisture: float = float(soil.get("moisture", 0.0))
            var growth: float = float(soil.get("growth_potential", 0.0))
            var temperature: float = climate.temperature_at_index(index)
            var cluster := _hash(int(float(x) / 21.0), int(float(y) / 21.0), config.world_seed + 3001)
            var chance := _hash(x, y, config.world_seed + 3002)
            var kind := ""
            var species := ""
            var density := clampf(growth * 0.48 + moisture * 0.19 +
                cluster * 0.30 - slope * 0.75, 0.0, 0.80)
            if soil.get("substrate") == "скала":
                density *= 0.18
            if chance < density:
                kind = "дерево"
                species = _species(temperature, moisture,
                    _hash(x, y, config.world_seed + 3003))
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
                age = 2 * 96 + int(_hash(x, y, config.world_seed + 3004) * 38.0 * 96.0)
                stock = maxi(1, int(float(age) / 96.0) * 3)
            elif kind == "кустарник":
                age = int(_hash(x, y, config.world_seed + 3004) * 10.0 * 96.0)
            var id: int = y * int(config.width) + x + 1
            var item := {
                "id": id, "kind": kind, "species": species,
                "x": x, "y": y, "age_days": age,
                "health": 1000, "wood_units": stock, "fallen_wood": 0,
                "cut_progress": 0,
                "dead_since_day": -1, "fallen_since_day": -1,
                "fall_angle_deg": -1,
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
                if Geometry.hits_log(point, radius, item, world.config):
                    return true
                var support := footprint_radius(item)
                if support <= 0.0:
                    continue
                var origin := Vector2(float(item["x"]) + 0.5,
                    float(item["y"]) + 0.5)
                if origin.distance_to(point) < support + radius:
                    return true
    return false


# Будущие рабочие получают точки подхода из физики, а не из рендера.
# Наличие точки не доказывает существование маршрута к ней.
func interaction_points(id: int, clearance: float = 0.28) -> Array[Vector2]:
    var points: Array[Vector2] = []
    if not is_finite(clearance) or clearance < 0.08:
        return points
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
        var cell: Vector2i = world.config.cell_at(point)
        var index: int = hydro.cell_index(cell)
        if hydro.has_water(index) or hydro.flooded_at(index):
            continue
        if world.normal_at(cell).y < 0.76 \
                or surface.waterlogging_at_index(index) > 0.85:
            continue
        if intersects_solid(point, 0.08, id):
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


func ground_cover_at(cell: Vector2i,
        fire: RefCounted = null) -> float:
    # Массовая трава не получает миллион отдельных ID.
    # Её плотность определяется сохранёнными почвой, погодой и деревьями.
    if not world.config.contains_cell(cell):
        return 0.0
    var index: int = hydro.cell_index(cell)
    if hydro.has_water(index) or hydro.flooded_at(index):
        return 0.0
    # Выгоревшая земля медленно восстанавливает плодородие.
    # Старые вызовы без FireRegistry используют обычную почву.
    var damage: float = float(fire.soil_damage_at(cell)) if fire != null else 0.0
    var soil: Dictionary = surface.profile_at(cell, damage)
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


func resource_stock(id: int) -> Dictionary:
    # Единый интерфейс запасов без искусственных ресурсов камней и грунта.
    # Другие типы сырья смогут добавлять свои записи в resources.
    var item: Dictionary = object_at(id)
    if item.is_empty():
        return {}
    var resources := {}
    if item["kind"] == "дерево":
        resources["wood"] = {
            "standing": int(item["wood_units"]),
            "fallen": int(item["fallen_wood"]),
            "available": int(item["fallen_wood"]),
            "unit": "условные единицы"
        }
    return {
        "object_id": id,
        "kind": str(item["kind"]),
        "state": str(item["state"]),
        "resources": resources
    }


func take_raw_resource(id: int, resource: String, amount: int) -> bool:
    # Только физически лежащая древесина доступна для будущего вывоза.
    if resource != "wood":
        return false
    return take_fallen_wood(id, amount)


func _modify(id: int, item: Dictionary) -> void:
    _objects[id] = item
    var changed := {world.config.chunk_of(
        Vector2i(int(item["x"]), int(item["y"]))): true}
    _mark_changes(changed)


func hit_tree(id: int, power: int = 250) -> Dictionary:
    # Удары влияют только на физическое состояние дерева.
    if power <= 0 or power > CUT_THRESHOLD:
        return {}
    var previous: Dictionary = object_at(id)
    if previous.is_empty() or previous.get("kind") != "дерево" \
            or previous.get("state") not in ["целое", "сухостой"]:
        return {}
    var progress := mini(CUT_THRESHOLD,
        int(previous.get("cut_progress", 0)) + power)
    if progress >= CUT_THRESHOLD:
        var result: Dictionary = fell_tree(id)
        if result.is_empty():
            return {}
        result["felled"] = true
        result["cut_progress"] = CUT_THRESHOLD
        return result
    var updated := previous.duplicate(true)
    updated["cut_progress"] = progress
    _modify(id, updated)
    tree_struck.emit(previous, progress)
    return {
        "id": id, "felled": false,
        "cut_progress": progress, "wood_units": 0
    }


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
    item["cut_progress"] = 0
    item["dead_since_day"] = -1
    item["fallen_since_day"] = climate.day
    # Ручная рубка сохраняет прежнее детерминированное направление.
    item["fall_angle_deg"] = -1
    _modify(id, item)
    tree_felled.emit(before)
    return {"id": id, "wood_units": wood, "state": "пень"}


func take_fallen_wood(id: int, amount: int) -> bool:
    # Забрать можно только фактически лежащий ресурс. Угол бревна
    # относится к его геометрии и не должен оставаться у пустого пня.
    var item: Dictionary = object_at(id)
    if item.is_empty() or amount <= 0 \
            or amount > int(item.get("fallen_wood", 0)):
        return false
    item["fallen_wood"] = int(item["fallen_wood"]) - amount
    if int(item["fallen_wood"]) == 0:
        # Полный сбор убирает бревно из физики и коллизий. Валидатор
        # JSON v4 принимает угол только при ненулевой лежащей древесине.
        item["fall_angle_deg"] = -1
    _modify(id, item)
    return true


func refresh_ground_visuals(changed: Dictionary) -> void:
    # Физический реестр пожаров передаёт набор затронутых чанков.
    # Одного сигнала за сутки достаточно для золы, травы и обновления
    # визуального мира, даже если сгорели десятки растений.
    _mark_changes(changed)


func refresh_object_visual(id: int) -> void:
    # Возгорание или тушение может менять только видимость огня,
    # а не здоровье. Уведомляем рендер о чанке без порчи объекта.
    var item: Dictionary = object_at(id)
    if item.is_empty():
        return
    _mark_changes({world.config.chunk_of(Vector2i(
        int(item["x"]), int(item["y"]))): true})


func burn_object(id: int, heat: int, day: int) -> bool:
    # Горение меняет существующий объект, а не создаёт временное
    # дерево или вторую запись ресурсов. Все чанки получают сигнал.
    if heat <= 0 or heat > 1000 or day != climate.day:
        return false
    var item: Dictionary = object_at(id)
    if item.is_empty() or item["kind"] not in ["дерево", "кустарник"] \
            or item["state"] not in ["целое", "сухостой"]:
        return false
    var previous_health := int(item["health"])
    var previous_wood := int(item["wood_units"])
    item["health"] = maxi(0, previous_health - heat)
    if item["kind"] == "дерево":
        # Сгорает часть существующей древесины: новое дерево или
        # запас брёвен не появляется. Это реальная потеря топлива.
        item["wood_units"] = maxi(0,
            previous_wood - mini(previous_wood,
                maxi(1, floori(float(heat) / 100.0))))
    if int(item["health"]) == 0 and item["state"] == "целое":
        item["state"] = "сухостой"
        item["dead_since_day"] = day
    if int(item["health"]) == previous_health \
            and int(item["wood_units"]) == previous_wood:
        return false
    _modify(id, item)
    return true


func _spread_seeds(day: int, changed: Dictionary,
        fire: RefCounted = null) -> int:
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
        var world_seed: int = world.config.world_seed + day * 17
        if _hash(x, y, world_seed) > 0.16:
            continue
        var direction_index := mini(3, int(_hash(x, y, world_seed + 1) * 4.0))
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
        # Молодые деревья не расселяются на свежей выгоревшей
        # почве так же успешно, как на ещё плодородном участке.
        var damage: float = float(fire.soil_damage_at(next)) if fire != null else 0.0
        var soil: Dictionary = surface.profile_at(next, damage)
        if float(soil.get("growth_potential", 0.0)) < 0.20 \
                or float(soil.get("waterlogging", 0.0)) > 0.72:
            continue
        var child: Dictionary = {
            "id": next_id, "kind": "дерево",
            "species": parent["species"], "x": next.x, "y": next.y,
            "age_days": 0, "health": 800, "wood_units": 0,
            "fallen_wood": 0, "state": "целое", "radius": 0.08,
            "cut_progress": 0, "dead_since_day": -1,
            "fallen_since_day": -1, "fall_angle_deg": -1
        }
        _objects[next_id] = child
        _index(child)
        changed[world.config.chunk_of(next)] = true
        created += 1
        if _objects.size() >= MAX_OBJECTS:
            break
    return created


static func hurricane_direction(offset: Vector2,
        prevailing: Vector2, clockwise: bool) -> Vector2:
    # В центре потоку не хватает радиуса вращения — берём
    # направление фронта. На периферии преобладает касательный
    # ветер, плавно смешанный с переносом всего урагана.
    var front := prevailing.normalized()
    if front.length_squared() < 0.000001:
        front = Vector2.RIGHT
    if offset.length_squared() < 1.0:
        return front
    var tangent := Vector2(-offset.y, offset.x).normalized()
    if clockwise:
        tangent = -tangent
    return (tangent * 0.83 + front * 0.17).normalized()


static func tornado_track_offset(offset: Vector2,
        prevailing: Vector2) -> Vector2:
    # Смещение относительно изогнутой оси следа. Ось тянется
    # по направлению фронта, а боковой ход плавно изгибается.
    # Физика дерева и тесты используют одну траекторию.
    var front := prevailing.normalized()
    if front.length_squared() < 0.000001:
        front = Vector2.RIGHT
    var along := offset.dot(front)
    var across := offset.cross(front)
    return Vector2(along, across - sin(along * 0.45) * 0.9)


static func tornado_reaches(offset: Vector2, prevailing: Vector2) -> bool:
    # Узкий коридор не превращает смерч в круговой ураган.
    # За границами пути повреждений нет даже при силе 1.0.
    var track := tornado_track_offset(offset, prevailing)
    return track.x >= -1.5 and track.x <= 11.5 \
        and absf(track.y) <= 2.2


static func tornado_direction(offset: Vector2, prevailing: Vector2,
        clockwise: bool) -> Vector2:
    # Стоящее на оси дерево падает вдоль движения вихря. По краям
    # добавляется касательный поток вокруг локальной оси следа.
    var front := prevailing.normalized()
    if front.length_squared() < 0.000001:
        front = Vector2.RIGHT
    var track := tornado_track_offset(offset, front)
    if absf(track.y) < 0.15:
        return front
    var side := Vector2(-front.y, front.x)
    var radial := side * track.y
    var tangent := Vector2(-radial.y, radial.x).normalized()
    if clockwise:
        tangent = -tangent
    return (front * 0.28 + tangent * 0.72).normalized()


static func dust_reaches(offset: Vector2, direction: Vector2) -> bool:
    # Воздушный перенос повторяет две последовательные полосы грунта
    # длиной около шести клеток. Поперечные кусты не повреждаются.
    if direction.length_squared() < 0.000001:
        return false
    var wind := direction.normalized()
    var along := offset.dot(wind)
    var across := absf(offset.cross(wind))
    return along >= -1.0 and along <= 7.0 and across <= 1.8


static func squall_reaches(offset: Vector2, direction: Vector2) -> bool:
    # Смещение относительно эпицентра проецируем по ветру и поперёк.
    # Порыв повреждает длинную узкую полосу, включая небольшой тыл,
    # но не соседний лес за её боковой границей.
    var along := offset.dot(direction)
    var across := absf(offset.cross(direction))
    return along >= -2.0 and along <= 9.0 and across <= 2.5


func _damage_from_events(hazards: Array[Dictionary],
        strikes: Array[Dictionary], changed: Dictionary) -> void:
    # Природные события изменяют физический лес независимо от камеры.
    # Повреждения затрагивают только чанки около эпицентра: полный обход
    # всех объектов для каждого события не масштабируется на большой карте.
    var events: Array[Dictionary] = []
    for event in hazards:
        var kind := str(event.get("kind", ""))
        # Геологические изменения уже записаны в WorldMap.
        # Реагируем только на реально сдвинутые вершины, чтобы
        # не повалить дерево при несостоявшемся бедствии.
        if kind in ["оползень", "обвал", "землетрясение"]:
            if int(event.get("vertices", 0)) > 0 \
                    and event.get("cell") is Vector2i:
                var impact_radius := 7.0 if kind == "землетрясение" else (
                    6.0 if kind == "оползень" else 5.0)
                _apply_landscape_damage(kind,
                    Vector2(event["cell"]) + Vector2(0.5, 0.5),
                    impact_radius, clampf(float(event.get("severity", 0.0)),
                        0.0, 1.0), climate.day, changed)
            continue
        # Пыль по-прежнему переносится в Surface, но открытые
        # кустарники на её следе могут получать физический урон.
        # Стволы и камни от самой пыли не повреждаются.
        var dust := kind == "пыльная буря"
        var squall := kind == "шквал"
        var hurricane := kind == "ураган"
        var tornado := kind == "смерч"
        var force := clampf(float(event.get("severity", 0.0)), 0.0, 1.0)
        events.append({
            "kind": kind,
            "cell": event.get("cell"),
            # Большой ураган охватывает несколько природных чанков.
            # Шквал, наоборот, остаётся вытянутой узкой полосой.
            "radius": 14.0 if hurricane else (13.0 if tornado else
                (9.0 if squall else (7.5 if dust else 5.0))),
            "severity": force,
            "damage": roundi(force * (850.0 if tornado else (
                720.0 if hurricane else (500.0 if squall else
                (280.0 if dust else 350.0)))))
        })
    for strike in strikes:
        # Прямой электрический удар повреждает растения даже под ливнем.
        # Влажность уменьшает риск *пожара*, но не силу разряда.
        # FireRegistry по-прежнему отдельно обрабатывает ignition_potential.
        var strength := clampf(float(strike.get("strength", 0.0)), 0.0, 1.0)
        events.append({
            "kind": "молния",
            "cell": strike.get("cell"),
            "radius": 2.5,
            "severity": strength,
            "damage": roundi(strength * 700.0)
        })

    for event in events:
        if not (event["cell"] is Vector2i) or int(event["damage"]) <= 0:
            continue
        var center: Vector2i = event["cell"]
        if not world.config.contains_cell(center):
            continue
        var radius: float = float(event["radius"])
        var is_squall := str(event["kind"]) == "шквал"
        var is_dust := str(event["kind"]) == "пыльная буря"
        var dust_direction := Vector2.ZERO
        if is_dust:
            # Используем климат того же дня, что перенёс грунт.
            dust_direction = climate.wind_direction_at_index(
                hydro.cell_index(center))
        var is_hurricane := str(event["kind"]) == "ураган"
        var is_tornado := str(event["kind"]) == "смерч"
        var tornado_front := Vector2.RIGHT
        var tornado_clockwise := false
        if is_tornado:
            # Вращение зависит от seed и дня, а не от порядка вызовов.
            tornado_front = climate.wind_direction_at_index(
                hydro.cell_index(center))
            tornado_clockwise = Terrain.hash2(center.x, center.y,
                world.config.world_seed + climate.day * 43 + 6139) < 0.5
        var hurricane_front := Vector2.RIGHT
        var hurricane_clockwise := false
        if is_hurricane:
            # Одинаковая сторона вращения для всех клеток данного
            # события определяется координатами центра, днём и seed.
            hurricane_front = climate.wind_direction_at_index(
                hydro.cell_index(center))
            hurricane_clockwise = Terrain.hash2(center.x, center.y,
                world.config.world_seed + climate.day * 41 + 9421) < 0.5
        var squall_direction := Vector2.RIGHT
        if is_squall:
            # Направление берём в эпицентре из физического климата.
            squall_direction = climate.wind_direction_at_index(
                hydro.cell_index(center))
        var center_chunk: Vector2i = world.config.chunk_of(center)
        var reach := ceili(radius / float(world.config.chunk_size)) + 1
        var affected_ids: Array[int] = []
        for cy in range(center_chunk.y - reach, center_chunk.y + reach + 1):
            for cx in range(center_chunk.x - reach, center_chunk.x + reach + 1):
                for id in _chunks.get(Vector2i(cx, cy), []):
                    affected_ids.append(int(id))
        # Упорядочиваем обработку для одинаковых результатов на всех клиентах.
        affected_ids.sort()
        for id in affected_ids:
            var item: Dictionary = _objects[id]
            if item["kind"] not in ["дерево", "кустарник"] \
                    or item["state"] != "целое":
                continue
            if item["kind"] == "кустарник" and str(event["kind"]) not in [
                    "шторм", "шквал", "ураган", "смерч", "пыльная буря",
                    "молния"]:
                # Точный разряд бьёт и по кустарнику рядом с эпицентром,
                # но остальные типы бедствий сохраняют прежние правила.
                continue
            var cell := Vector2i(int(item["x"]), int(item["y"]))
            var offset := Vector2(cell - center)
            var distance := offset.length()
            if distance > radius:
                continue
            if is_squall and not squall_reaches(offset, squall_direction):
                # Соседние деревья вне полосы порыва не повреждаются.
                continue
            if is_tornado and not tornado_reaches(offset, tornado_front):
                # Вне узкого извилистого следа лес остаётся нетронутым.
                continue
            if is_dust and (item["kind"] != "кустарник" \
                    or not dust_reaches(offset, dust_direction)):
                # От пыли деревья, камни и кусты вне следа не страдают.
                continue

            # Выбор упавших деревьев по seed и суткам не зависит
            # от камеры, FPS и порядка обработки чанков.
            var severity: float = float(event["severity"])
            var damage: int = int(event["damage"])
            if is_tornado:
                # В центре полосы ветер сильнее; к краям следа
                # повреждение снижается без квадратной отсечки урона.
                var track := tornado_track_offset(offset, tornado_front)
                var vortex_falloff := 0.25 + 0.75 * (
                    1.0 - absf(track.y) / 2.2)
                severity *= vortex_falloff
                damage = roundi(float(damage) * vortex_falloff)
            if is_hurricane:
                # Максимальный ущерб внутри урагана и постепенное
                # затухание у внешней границы — без резкого кольца.
                var falloff := 0.15 + 0.85 * (1.0 - distance / radius)
                severity *= falloff
                damage = roundi(float(damage) * falloff)
            if item["kind"] == "кустарник":
                # Кратковременная пыль сушит листву, сильный ветер
                # способен погубить куст. Нет валки ствола или древесины:
                # куст сохраняет только здоровье и дату гибели.
                var shrub_damage := damage if str(event["kind"]) == "молния" else (
                    roundi(severity * (
                    280.0 if is_dust else (1150.0 if is_tornado else (
                    1050.0 if is_hurricane else (
                    850.0 if is_squall else 520.0))))))
                if shrub_damage <= 0:
                    continue
                item["health"] = maxi(0, int(item["health"]) - shrub_damage)
                if int(item["health"]) == 0:
                    item["state"] = "сухостой"
                    item["dead_since_day"] = climate.day
                _objects[id] = item
                changed[world.config.chunk_of(cell)] = true
                continue

            var windfall := str(event["kind"]) in [
                "шторм", "шквал", "ураган", "смерч"]
            var threshold := 0.25 if is_tornado else (
                0.28 if is_hurricane else (0.45 if is_squall else 0.55))
            windfall = windfall and severity >= threshold
            if windfall:
                var factor := 1.6 if is_tornado else (
                    1.4 if is_hurricane else (2.2 if is_squall else 2.0))
                var maximum := 0.99 if is_tornado else (
                    0.98 if is_hurricane else (0.95 if is_squall else 0.85))
                var chance := clampf((severity - threshold) * factor,
                    0.0, maximum)
                windfall = Terrain.hash2(cell.x, cell.y,
                    world.config.world_seed + climate.day * 31 + 3173) < chance

            # До перехода сохраняем ровно то дерево, которое было
            # видно перед падением. Визуализация получит его после
            # завершения рабочего потока, но не изменит физический лес.
            var before: Dictionary = item.duplicate(true) if windfall else {}
            item["health"] = maxi(0, int(item["health"]) - damage)
            if windfall:
                # Древесина переходит из стоящего ствола в лежащий ресурс.
                # Дата падения и коллизии следуют за состоянием, не за FX.
                item["fallen_wood"] = int(item["fallen_wood"]) + int(item["wood_units"])
                item["wood_units"] = 0
                item["state"] = "пень"
                item["health"] = 0
                item["cut_progress"] = 0
                item["dead_since_day"] = -1
                item["fallen_since_day"] = climate.day
                # Поваленный ствол лежит по направлению физического
                # потока воздуха в своей клетке, а не по случайному ID.
                var wind_index: int = hydro.cell_index(cell)
                var direction: Vector2 = climate.wind_direction_at_index(wind_index)
                if is_hurricane:
                    # При урагане направление ствола определяется
                    # касательным ветром вокруг центра, не случайным ID.
                    direction = hurricane_direction(offset,
                        hurricane_front, hurricane_clockwise)
                elif is_tornado:
                    # Направление валки учитывает изгиб траектории
                    # и локальное закручивание смерча.
                    direction = tornado_direction(offset,
                        tornado_front, tornado_clockwise)
                item["fall_angle_deg"] = posmod(roundi(rad_to_deg(
                    atan2(-direction.y, direction.x))), 360)
                if last_windfalls.size() < MAX_VISIBLE_WINDFALL_RECORDS:
                    # Только исходные данные и угол, без сцен и GPU.
                    last_windfalls.append({
                        "before": before,
                        "fall_angle_deg": int(item["fall_angle_deg"]),
                        "cell": cell
                    })
            elif int(item["health"]) == 0:
                # Не поваленное погибшее дерево остаётся сухостоем.
                item["state"] = "сухостой"
                item["dead_since_day"] = climate.day

            _objects[id] = item
            # Даже неполное повреждение меняет здоровье/вид кроны.
            # Сообщаем рендереру и системе коллизий об изменённом чанке.
            changed[world.config.chunk_of(cell)] = true


func _apply_landscape_damage(kind: String, center: Vector2,
        radius: float, severity: float, day: int,
        changed: Dictionary) -> Dictionary:
    # Физическое воздействие затрагивает только соседние чанки.
    # Деревья теряют устойчивость, кусты — здоровье, а валуны остаются
    # тем же конечным объектом и перемещаются по вертикали вместе с
    # WorldMap. Никаких записей о временных GPU-эффектах не создаём.
    var summary := {
        "trees_felled": 0, "trees_damaged": 0,
        "shrubs_damaged": 0, "boulders_rebased": 0
    }
    if not generated or kind not in [
            "оползень", "обвал", "землетрясение", "кратер",
            "поднятие", "просадка"]:
        return summary
    if not is_finite(center.x) or not is_finite(center.y) \
            or not world.config.contains_point(center) \
            or not is_finite(radius) or radius <= 0.0 \
            or not is_finite(severity) or severity <= 0.0 \
            or severity > 1.0 or day < 0 or day > climate.day:
        return summary

    var origin_cell: Vector2i = world.config.cell_at(center)
    var origin_chunk: Vector2i = world.config.chunk_of(origin_cell)
    var reach := ceili(radius / float(world.config.chunk_size)) + 1
    var affected_ids: Array[int] = []
    for cy in range(origin_chunk.y - reach, origin_chunk.y + reach + 1):
        for cx in range(origin_chunk.x - reach, origin_chunk.x + reach + 1):
            for id in _chunks.get(Vector2i(cx, cy), []):
                affected_ids.append(int(id))
    # Сортировка не позволяет изменению порядка чанков влиять на исход.
    affected_ids.sort()
    for id in affected_ids:
        var item: Dictionary = _objects[id]
        var cell := Vector2i(int(item["x"]), int(item["y"]))
        var position := Vector2(cell) + Vector2(0.5, 0.5)
        var distance := position.distance_to(center)
        if distance >= radius or not is_finite(world.height_at(position)):
            continue
        var chunk: Vector2i = world.config.chunk_of(cell)
        var pressure := severity * (1.0 - distance / radius)

        # Даже неразрушенный валун должен занять новую физическую
        # высоту. Его ID, масса и местоположение в клетке неизменны.
        changed[chunk] = true
        if item["kind"] == "валун":
            summary["boulders_rebased"] += 1
            continue
        if item["kind"] == "кустарник":
            if item["state"] != "целое":
                continue
            var shrub_damage := roundi(pressure * 1250.0)
            if shrub_damage <= 0:
                continue
            item["health"] = maxi(0, int(item["health"]) - shrub_damage)
            if int(item["health"]) == 0:
                item["state"] = "сухостой"
                item["dead_since_day"] = day
            _objects[id] = item
            summary["shrubs_damaged"] += 1
            continue
        if item["kind"] != "дерево" or item["state"] == "пень":
            continue

        # Обрушение корней переводит реальную древесину из стоящего
        # дерева в лежащий ствол. Для слабого толчка остаётся только
        # повреждение дерева, без появления второго ресурса.
        var damage := roundi(pressure * 1150.0)
        if damage <= 0:
            continue
        if pressure >= 0.35:
            var direction := Vector2.ZERO
            if kind == "кратер":
                direction = position - center
            else:
                var normal: Vector3 = world.normal_at(cell)
                direction = Vector2(normal.x, normal.z)
            if direction.length_squared() < 0.0001:
                var angle := Terrain.hash2(cell.x, cell.y,
                    world.config.world_seed + day * 29 + 1177) * TAU
                direction = Vector2(cos(angle), sin(angle))
            direction = direction.normalized()
            item["fallen_wood"] = int(item["fallen_wood"]) + int(item["wood_units"])
            item["wood_units"] = 0
            item["state"] = "пень"
            item["health"] = 0
            item["cut_progress"] = 0
            item["dead_since_day"] = -1
            item["fallen_since_day"] = day
            item["fall_angle_deg"] = posmod(roundi(rad_to_deg(
                atan2(-direction.y, direction.x))), 360) \
                if int(item["fallen_wood"]) > 0 else -1
            summary["trees_felled"] += 1
        else:
            item["health"] = maxi(0, int(item["health"]) - damage)
            if int(item["health"]) == 0:
                item["state"] = "сухостой"
                item["dead_since_day"] = day
            summary["trees_damaged"] += 1
        _objects[id] = item
    return summary


func apply_landscape_impact(kind: String, center: Vector2,
        radius: float, severity: float, day: int) -> Dictionary:
    # Ручная деформация в игровой сцене проходит по тому же пути,
    # что суточная стихийная физика; самостоятельные записи о
    # высотах, объектах или ресурсах здесь не вводятся.
    var changed := {}
    var summary := _apply_landscape_damage(
        kind, center, radius, severity, day, changed)
    _mark_changes(changed)
    return summary


func advance_day(day: int, hazards: Array[Dictionary] = [],
        strikes: Array[Dictionary] = [],
        fire: RefCounted = null) -> int:
    if not generated or day <= last_day or day != climate.day:
        return 0
    # Транзитные анимации относятся только к завершённому дню.
    # Не повторяем падения после сохранения или последующего тика.
    last_windfalls.clear()
    var changed := {}
    var updates := 0
    for id in _objects.keys():
        # Восемь очередей: не проверяем всю экосистему в каждом такте.
        if posmod(day - int(id), 8) != 0:
            continue
        var item: Dictionary = _objects[id]
        if item["kind"] == "валун":
            continue
        if item["kind"] == "дерево" and item["state"] == "пень":
            # Старые брёвна разлагаются, а пустой пень со временем исчезает.
            var fallen_day: int = int(item.get("fallen_since_day", day))
            if day >= fallen_day + LOG_DECAY_INTERVAL_DAYS \
                    and posmod(day - int(id), LOG_DECAY_INTERVAL_DAYS) == 0 \
                    and int(item["fallen_wood"]) > 0:
                item["fallen_wood"] = int(item["fallen_wood"]) - 1
                _objects[id] = item
                changed[world.config.chunk_of(Vector2i(
                    int(item["x"]), int(item["y"])))] = true
                updates += 1
            if day >= fallen_day + STUMP_DECAY_DAYS \
                    and int(item["fallen_wood"]) == 0:
                _remove_object(int(id), item, changed)
                updates += 1
            continue
        var cell := Vector2i(int(item["x"]), int(item["y"]))
        if item["kind"] == "кустарник" and item["state"] == "сухостой" \
                and day - int(item.get("dead_since_day", day)) >= SHRUB_DECAY_DAYS:
            _remove_object(int(id), item, changed)
            updates += 1
            continue
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
        # После физического пожара корни и микрофлора восстанавливаются
        # по суточному слою почвенного ожога, а не по дымовым частицам.
        var soil_scar: float = float(fire.soil_damage_at(cell)) if fire != null else 0.0
        if soil_scar > 0.0 and item["state"] == "целое":
            var sensitivity := 13.0 if int(item["age_days"]) < 7 * 96 else 6.0
            stress += roundi(soil_scar * sensitivity)
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
            item["dead_since_day"] = day
        if item["kind"] == "дерево":
            if item["state"] == "целое" and item["age_days"] % 96 < 8:
                var annual_increment := 3 if int(item["age_days"]) < 60 * 96 else 1
                if competition > 0.75:
                    annual_increment = maxi(0, annual_increment - 2)
                # Утрата плодородия сокращает годовой прирост древесины,
                # но не отбирает уже существующие брёвна из запаса.
                if soil_scar > 0.40:
                    annual_increment = maxi(0, annual_increment - 1)
                item["wood_units"] = int(item["wood_units"]) + annual_increment
            elif item["state"] == "сухостой":
                if day % 96 < 8:
                    item["wood_units"] = maxi(0, int(item["wood_units"]) - 1)
                # Сухостой через несколько лет естественно падает.
                # Переносим оставшийся запас, не создавая новый ресурс.
                var death_day: int = int(item.get("dead_since_day", day))
                var variation := posmod(int(id) * 23 +
                    int(world.config.world_seed), DEADWOOD_VARIATION_DAYS)
                if day - death_day >= DEADWOOD_FALL_DAYS + variation:
                    item["fallen_wood"] = int(item["fallen_wood"]) + \
                        int(item["wood_units"])
                    item["wood_units"] = 0
                    item["state"] = "пень"
                    item["cut_progress"] = 0
                    item["dead_since_day"] = -1
                    item["fallen_since_day"] = day
                    # Естественное падение сухостоя не является ветровалом.
                    item["fall_angle_deg"] = -1
        _objects[id] = item
        updates += 1
        if old_state != str(item["state"]):
            changed[world.config.chunk_of(cell)] = true
    updates += _spread_seeds(day, changed, fire)
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
            int(entry["fallen_wood"]), str(entry["state"]),
            int(entry.get("cut_progress", 0)),
            int(entry.get("dead_since_day", -1)),
            int(entry.get("fallen_since_day", -1)),
            int(entry.get("fall_angle_deg", -1))
        ])
    return {
        "version": FORMAT_VERSION, "generated": generated,
        "last_day": last_day, "objects": items
    }


func load_data(data: Dictionary) -> bool:
    var version: Variant = data.get("version")
    # JSON reads numbers as floats; Array membership compares their types too.
    if not (version is int or version is float) \
            or (version != 1 and version != 2 and version != 3 \
                and version != FORMAT_VERSION) \
            or not (data.get("generated") is bool) \
            or not (data.get("objects") is Array):
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
        var item_size := 10 if version == 1 else (
            11 if version == 2 else (13 if version == 3 else 14))
        if not (raw is Array) or raw.size() != item_size:
            return false
        for number in [0, 3, 4, 5, 6, 7, 8]:
            if not (raw[number] is int or raw[number] is float) \
                        or not is_finite(float(raw[number])) \
                        or float(raw[number]) != float(int(raw[number])):
                return false
        var cut_progress := 0
        if version >= 2:
            if not (raw[10] is int or raw[10] is float):
                return false
            if not is_finite(float(raw[10])) \
                    or float(raw[10]) != float(int(raw[10])):
                return false
            cut_progress = int(raw[10])
            if cut_progress < 0 or cut_progress >= CUT_THRESHOLD:
                return false
        var dead_since_day := -1
        var fallen_since_day := -1
        if version >= 3:
            for field in [11, 12]:
                if not (raw[field] is int or raw[field] is float) \
                        or not is_finite(float(raw[field])) \
                        or float(raw[field]) != float(int(raw[field])):
                    return false
            dead_since_day = int(raw[11])
            fallen_since_day = int(raw[12])
            if dead_since_day < -1 or dead_since_day > int(day) \
                    or fallen_since_day < -1 \
                    or fallen_since_day > int(day):
                return false
        var fall_angle_deg := -1
        if version == FORMAT_VERSION:
            # Новый угол — целое число градусов. Это исключает дрейф
            # координат бревна из-за точности JSON и изменений FPS.
            var angle_value: Variant = raw[13]
            if not (angle_value is int or angle_value is float) \
                    or not is_finite(float(angle_value)) \
                    or float(angle_value) != float(int(angle_value)):
                return false
            fall_angle_deg = int(angle_value)
            if fall_angle_deg < -1 or fall_angle_deg >= 360:
                return false
        var id := int(raw[0])
        var x := int(raw[3])
        var y := int(raw[4])
        var cell := Vector2i(x, y)
        if id != y * world.config.width + x + 1 \
                or not world.config.contains_cell(cell) or restored.has(id):
            return false
        if not (raw[1] is String) or not (raw[2] is String) \
                or not (raw[9] is String):
            return false
        var kind: String = raw[1]
        if kind not in ["дерево", "кустарник", "валун"] \
                or (kind == "дерево" and raw[2] not in TREE_SPECIES) \
                or raw[9] not in ["целое", "сухостой", "пень"]:
            return false
        if cut_progress > 0 and (kind != "дерево" or raw[9] == "пень"):
            return false
        if version < 3:
            # Только форматы 1–2 не содержали дату гибели/валки: отсчёт
            # естественного распада начинается с момента загрузки.
            if raw[9] == "сухостой":
                dead_since_day = int(day)
            elif raw[9] == "пень":
                fallen_since_day = int(day)
        elif (raw[9] == "целое" and (
                dead_since_day != -1 or fallen_since_day != -1)) \
                or (raw[9] == "сухостой" and (
                dead_since_day < 0 or fallen_since_day != -1)) \
                or (raw[9] == "пень" and (
                dead_since_day != -1 or fallen_since_day < 0)):
            return false
        # Направление допустимо лишь у лежащего ствола. У живых
        # деревьев, сухостоя, кустарников и пустых пней его нет.
        if fall_angle_deg >= 0 and (kind != "дерево" \
                or raw[9] != "пень" or int(raw[8]) <= 0):
            return false
        if int(raw[5]) < 0 or int(raw[5]) > 100000000 \
                or int(raw[6]) < 0 or int(raw[6]) > 1000 \
                or int(raw[7]) < 0 or int(raw[7]) > 10000000 \
                or int(raw[8]) < 0 or int(raw[8]) > 10000000:
            return false
        var item := {
            "id": id, "kind": kind, "species": String(raw[2]),
            "x": x, "y": y, "age_days": int(raw[5]),
            "health": int(raw[6]), "wood_units": int(raw[7]),
            "fallen_wood": int(raw[8]), "state": String(raw[9]),
            "cut_progress": cut_progress,
            "dead_since_day": dead_since_day,
            "fallen_since_day": fallen_since_day,
            "fall_angle_deg": fall_angle_deg,
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
    last_windfalls.clear()
    generated = bool(data["generated"])
    last_day = int(day)
    revision += 1
    return true
