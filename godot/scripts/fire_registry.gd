extends RefCounted
## Физические очаги огня: возгорание, топливо, перенос и тушение.
## Камера, частицы, шейдеры и пользовательский FPS здесь не участвуют.

const Terrain = preload("res://scripts/terrain.gd")
const FORMAT_VERSION := 1
const MAX_FIRES := 1024
const MAX_EVENTS_PER_DAY := 64

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var nature: RefCounted
var last_day := 0
var total_ignitions := 0
var last_events: Array[Dictionary] = []
var _burning: Dictionary = {}


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        weather: RefCounted, vegetation: RefCounted) -> void:
    world = map
    hydro = water
    surface = ground
    climate = weather
    nature = vegetation
    last_day = climate.day


func burning_count() -> int:
    return _burning.size()


func is_burning(id: int) -> bool:
    return _burning.has(id)


func burning_ids() -> Array[int]:
    # Последовательность не зависит от порядка вставки в Dictionary.
    var ids: Array[int] = []
    for id in _burning.keys():
        ids.append(int(id))
    ids.sort()
    return ids


func _flammability(cell: Vector2i) -> float:
    # Сырой грунт, снежный покров и затопление останавливают огонь.
    # Это условная модель горючести, а не декоративный шум.
    if not world.config.contains_cell(cell):
        return 0.0
    var index: int = hydro.cell_index(cell)
    if hydro.has_water(index) or hydro.flooded_at(index):
        return 0.0
    var moisture: float = surface.moisture_at_index(index)
    var snow: float = surface.snow_at_index(index)
    var rain: float = climate.precipitation_at_index(index)
    if snow >= 0.12 or moisture >= 0.82:
        return 0.0
    return clampf((0.78 - moisture) / 0.65, 0.0, 1.0) * \
        clampf(1.0 - rain / 1.1, 0.0, 1.0) * \
        clampf(1.0 - snow / 0.12, 0.0, 1.0)


func _fuel(item: Dictionary) -> int:
    # Древесный запас ограничивает время горения взрослого дерева.
    # Кустарники имеют небольшое собственное топливо без ресурса wood.
    if item.get("kind") == "кустарник":
        return 220
    return clampi(int(item.get("wood_units", 0)) * 6, 90, 900)


func _record(kind: String, id: int, cell: Vector2i) -> void:
    # Последние события нужны интерфейсу и тестам только один день.
    # После сохранения восстанавливается сам огонь, а не старая анимация.
    if last_events.size() >= MAX_EVENTS_PER_DAY:
        return
    last_events.append({
        "kind": kind, "id": id, "cell": cell, "day": last_day
    })


func _ignite(id: int, strength: float, forced: bool = false) -> bool:
    # Новое возгорание допускается лишь у физического дерева или куста,
    # имеющего запас горючего и достаточно сухую поверхность.
    if _burning.has(id) or _burning.size() >= MAX_FIRES:
        return false
    var item: Dictionary = nature.object_at(id)
    if item.is_empty() or item.get("kind") not in ["дерево", "кустарник"] \
            or item.get("state") not in ["целое", "сухостой"]:
        return false
    var cell := Vector2i(int(item["x"]), int(item["y"]))
    var dryness := _flammability(cell)
    if dryness < 0.20:
        return false
    var chance := clampf(strength * dryness * 0.7, 0.0, 0.95)
    if not forced and Terrain.hash2(cell.x, cell.y,
            world.config.world_seed + climate.day * 71 + 8201) >= chance:
        return false
    _burning[id] = {"fuel": _fuel(item), "since": last_day}
    nature.refresh_object_visual(id)
    total_ignitions += 1
    _record("возгорание", id, cell)
    return true


func _ignite_near(cell: Vector2i, strength: float,
        forced: bool = false) -> bool:
    # Выбираем ближайшую древесную сущность в районе молнии.
    # Пространственные чанки не дают сканировать всю карту.
    if not world.config.contains_cell(cell):
        return false
    var chunk: Vector2i = world.config.chunk_of(cell)
    var closest_id := -1
    var closest_distance := INF
    for dy in range(-1, 2):
        for dx in range(-1, 2):
            for id in nature._chunks.get(chunk + Vector2i(dx, dy), []):
                var item: Dictionary = nature.object_at(int(id))
                if item.get("kind") not in ["дерево", "кустарник"] \
                        or item.get("state") not in ["целое", "сухостой"]:
                    continue
                var distance := Vector2(cell).distance_squared_to(
                    Vector2(float(item["x"]), float(item["y"])))
                if distance > 6.25 or distance >= closest_distance:
                    continue
                closest_distance = distance
                closest_id = int(id)
    if closest_id < 0:
        return false
    return _ignite(closest_id, strength, forced)


func _spread_from(item: Dictionary, id: int) -> void:
    # Огонь ищет горючие объекты в радиусе четырёх клеток и переносится
    # преимущественно по ветру. Количество кандидатов ограничено чанками.
    if _burning.size() >= MAX_FIRES:
        return
    var origin := Vector2i(int(item["x"]), int(item["y"]))
    var index: int = hydro.cell_index(origin)
    var wind: Vector2 = climate.wind_direction_at_index(index)
    var gust: float = climate.wind_gust_at_index(index)
    var chunk: Vector2i = world.config.chunk_of(origin)
    var candidates: Array[int] = []
    for dy in range(-1, 2):
        for dx in range(-1, 2):
            for other_id in nature._chunks.get(chunk + Vector2i(dx, dy), []):
                candidates.append(int(other_id))
    candidates.sort()
    var attempts := 0
    for other_id in candidates:
        if other_id == id or _burning.has(other_id):
            continue
        var other: Dictionary = nature.object_at(other_id)
        if other.get("kind") not in ["дерево", "кустарник"] \
                or other.get("state") not in ["целое", "сухостой"]:
            continue
        var target := Vector2i(int(other["x"]), int(other["y"]))
        var offset := Vector2(target - origin)
        var distance: float = offset.length()
        if distance <= 0.0 or distance > 4.5:
            continue
        var aligned: float = wind.dot(offset.normalized())
        if aligned < -0.25:
            continue
        var dryness := _flammability(target)
        var probability := dryness * clampf(
            0.10 + gust / 80.0 + aligned * 0.25, 0.0, 0.9)
        if Terrain.hash2(target.x, target.y,
                world.config.world_seed + last_day * 67 + id) < probability:
            _ignite(other_id, 1.0, true)
            attempts += 1
        # Один очаг не создаёт больше двух новых очагов за сутки.
        if attempts >= 2:
            break


func advance_day(day: int, strikes: Array[Dictionary] = [],
        diagnostic_cell: Vector2i = Vector2i(-1, -1)) -> Array[Dictionary]:
    # Одна календарная дата обрабатывается один раз. Сначала горят
    # прежние очаги, потом учитываются молнии: удар не ускоряет сутки.
    if day <= last_day or day != climate.day or nature.last_day != day:
        return []
    last_day = day
    last_events.clear()
    for id in burning_ids():
        var item: Dictionary = nature.object_at(id)
        if item.is_empty():
            _burning.erase(id)
            continue
        var cell := Vector2i(int(item["x"]), int(item["y"]))
        var dryness := _flammability(cell)
        if dryness < 0.12:
            _burning.erase(id)
            nature.refresh_object_visual(id)
            _record("затухание", id, cell)
            continue
        # Топливо реально расходуется и влияет на древесину/здоровье.
        var fuel: Dictionary = _burning[id]
        var heat := clampi(roundi(80.0 + dryness * 135.0), 40, 220)
        nature.burn_object(id, heat, day)
        fuel["fuel"] = maxi(0, int(fuel["fuel"]) - heat)
        _record("горение", id, cell)
        if int(fuel["fuel"]) == 0:
            _burning.erase(id)
            _record("выгорание", id, cell)
            continue
        _burning[id] = fuel
        _spread_from(item, id)

    for strike in strikes:
        # Только реальные молнии с достаточным риском могут поджечь
        # растительность; гроза без удара не создаёт очаг.
        if strike.get("cell") is Vector2i:
            _ignite_near(strike["cell"],
                clampf(float(strike.get("ignition_potential", 0.0)), 0.0, 1.0))
    if world.config.contains_cell(diagnostic_cell):
        # Диагностика обходит случайность, но не требования сухости
        # и реального горючего объекта в указанной точке.
        _ignite_near(diagnostic_cell, 1.0, true)
    return last_events.duplicate(true)


func to_data() -> Dictionary:
    # Активные очаги имеют целочисленные поля для строгой загрузки.
    # Никакие transient FX/анимации в сохранение не попадают.
    var entries := []
    for id in burning_ids():
        var entry: Dictionary = _burning[id]
        entries.append([id, int(entry["fuel"]), int(entry["since"])])
    return {
        "version": FORMAT_VERSION,
        "day": last_day, "total_ignitions": total_ignitions,
        "fires": entries
    }


func load_data(data: Dictionary) -> bool:
    # Валидация полностью проходит до замены активных очагов.
    # Это защищает уже открытый мир от повреждённого JSON.
    if data.get("version") != FORMAT_VERSION:
        return false
    if not (data.get("day") is int or data.get("day") is float) \
            or not (data.get("total_ignitions") is int \
            or data.get("total_ignitions") is float):
        return false
    var day := int(data["day"])
    var total := int(data["total_ignitions"])
    if float(data["day"]) != float(day) or day < 0 \
            or day > climate.day or total < 0 or total > 100000000:
        return false
    if float(data["total_ignitions"]) != float(total):
        return false
    var raw: Variant = data.get("fires")
    if not (raw is Array) or raw.size() > MAX_FIRES:
        return false
    var parsed := {}
    for entry in raw:
        if not (entry is Array) or entry.size() != 3:
            return false
        for value in entry:
            if not (value is int or value is float) \
                    or not is_finite(float(value)) \
                    or float(value) != float(int(value)):
                return false
        var id := int(entry[0])
        var fuel := int(entry[1])
        var since := int(entry[2])
        if id <= 0 or parsed.has(id) or fuel <= 0 or fuel > 900 \
                or since < 0 or since > day:
            return false
        var item: Dictionary = nature.object_at(id)
        if item.is_empty() or item.get("kind") not in [
                "дерево", "кустарник"]:
            return false
        parsed[id] = {"fuel": fuel, "since": since}
    if parsed.size() > total:
        return false
    _burning = parsed
    last_day = day
    total_ignitions = total
    last_events.clear()
    return true
