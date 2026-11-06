extends RefCounted
## Физические очаги огня: возгорание, топливо, перенос и тушение.
## Камера, частицы, шейдеры и пользовательский FPS здесь не участвуют.

const Terrain = preload("res://scripts/terrain.gd")
const FORMAT_VERSION := 4
const MAX_FIRES := 1024
const MAX_SCORCHED_CELLS := 4096
const MAX_EMBERS := 512
const MAX_LITTER_FUEL := 360
const ASH_RECOVERY_PER_DAY := 12
const SOIL_HEAL_PER_DAY := 4
const MAX_SOIL_SCARS := 4096
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
var _scorched: Dictionary = {}
var _embers: Dictionary = {}
var _soil_damage: Dictionary = {}


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


func smolder_count() -> int:
    return _embers.size()


func is_smoldering(cell: Vector2i) -> bool:
    # Тлеющий слой привязан к физической клетке, а не к дереву или FX.
    if not world.config.contains_cell(cell):
        return false
    return _embers.has(hydro.cell_index(cell))


func smolder_in_chunk(chunk: Vector2i) -> Array[Dictionary]:
    # Рендеру передаются лишь активные клетки в видимом чанке.
    # Во всём мире остаётся ограниченное число записей подстилки.
    var result: Array[Dictionary] = []
    var rect: Rect2i = world.config.chunk_rect(chunk)
    for y in range(rect.position.y, rect.end.y):
        for x in range(rect.position.x, rect.end.x):
            var cell := Vector2i(x, y)
            if not is_smoldering(cell):
                continue
            var fuel: int = int(_embers[hydro.cell_index(cell)]["fuel"])
            result.append({"cell": cell, "heat": float(fuel) / MAX_LITTER_FUEL})
    return result


func soil_scar_count() -> int:
    return _soil_damage.size()


func soil_damage_at(cell: Vector2i) -> float:
    # Обожжённая почва хранится отдельно от золы: дождь может
    # смыть пепел, но не восстанавливает плодородие мгновенно.
    if not world.config.contains_cell(cell):
        return 0.0
    var index: int = hydro.cell_index(cell)
    if not _soil_damage.has(index):
        return 0.0
    return float(_soil_damage[index]["damage"]) / 1000.0


func scorched_count() -> int:
    return _scorched.size()


func scorched_at(cell: Vector2i) -> float:
    # Огарок грунта — физическое число от нуля до единицы,
    # сохраняемое между запусками и независимое от камеры.
    if not world.config.contains_cell(cell):
        return 0.0
    var i: int = hydro.cell_index(cell)
    if not _scorched.has(i):
        return 0.0
    return float(_scorched[i]["ash"]) / 1000.0


func scorched_in_chunk(chunk: Vector2i) -> Array[Dictionary]:
    # Рендер опрашивает только клетки одного видимого чанка,
    # не перебирая все следы пожаров на огромной карте.
    var result: Array[Dictionary] = []
    var rect: Rect2i = world.config.chunk_rect(chunk)
    for y in range(rect.position.y, rect.end.y):
        for x in range(rect.position.x, rect.end.x):
            var cell := Vector2i(x, y)
            var intensity := scorched_at(cell)
            if intensity <= 0.08:
                continue
            result.append({"cell": cell, "ash": intensity})
    return result


func _scorch(cell: Vector2i, heat: int, changed: Dictionary) -> void:
    # Угар появляется только после расхода реального топлива.
    # Одна клетка содержит один конечный запас пепла, без дублей.
    if not world.config.contains_cell(cell):
        return
    var index: int = hydro.cell_index(cell)
    if not _scorched.has(index) and _scorched.size() >= MAX_SCORCHED_CELLS:
        return
    var previous: int = int(_scorched.get(index, {}).get("ash", 0))
    _scorched[index] = {
        "ash": mini(1000, previous + maxi(1, heat * 4)),
        "last_burn": last_day
    }
    # Потеря почвенного плодородия не перемещается вместе с золой.
    # Не создаём бесконечные записи, ограничиваем карту повреждений.
    if _soil_damage.has(index) or _soil_damage.size() < MAX_SOIL_SCARS:
        var old_damage: int = int(_soil_damage.get(index, {}).get(
            "damage", 0))
        _soil_damage[index] = {
            "damage": mini(1000, old_damage + maxi(1, heat * 2)),
            "last_burn": last_day
        }
    changed[world.config.chunk_of(cell)] = true


func _recover_ground(changed: Dictionary) -> void:
    # Зола уходит только с течением физических суток; камера, кадры
    # и загрузка сами по себе не меняют состояние участка.
    var indices: Array[int] = []
    for key in _scorched.keys():
        indices.append(int(key))
    indices.sort()
    for index in indices:
        var data: Dictionary = _scorched[index]
        if int(data["last_burn"]) >= last_day:
            continue
        var previous: int = int(data["ash"])
        var updated := maxi(0, previous - ASH_RECOVERY_PER_DAY)
        if updated == 0:
            _scorched.erase(index)
        else:
            data["ash"] = updated
            _scorched[index] = data
        var cell := Vector2i(index % world.config.width,
            index / world.config.width)
        changed[world.config.chunk_of(cell)] = true


func _recover_soil(changed: Dictionary) -> void:
    # Восстановление плодородия идёт медленнее естественной убыли
    # золы. Даже если дождь смыл пепел, физический ожог остаётся.
    var indices: Array[int] = []
    for key in _soil_damage.keys():
        indices.append(int(key))
    indices.sort()
    for index in indices:
        var scar: Dictionary = _soil_damage[index]
        if int(scar["last_burn"]) >= last_day:
            continue
        var healed := maxi(0, int(scar["damage"]) - SOIL_HEAL_PER_DAY)
        if healed == 0:
            _soil_damage.erase(index)
        else:
            scar["damage"] = healed
            _soil_damage[index] = scar
        var cell := Vector2i(index % world.config.width,
            index / world.config.width)
        changed[world.config.chunk_of(cell)] = true


func _wash_ash(changed: Dictionary) -> void:
    # Дождевой сток переносит уже существующую золу вниз по суше.
    # Вода и затопленные клетки пока не принимают осадок: отдельная
    # модель речной взвеси не должна появляться как побочный эффект.
    var outgoing := {}
    var incoming := {}
    var source_dates := {}
    var indices: Array[int] = []
    for key in _scorched.keys():
        indices.append(int(key))
    indices.sort()

    for index in indices:
        var runoff: float = surface.runoff_at_index(index)
        if runoff < 0.35:
            continue
        var cell := Vector2i(index % world.config.width,
            index / world.config.width)
        var origin_height: float = world.height_at(
            Vector2(cell) + Vector2(0.5, 0.5))
        if not is_finite(origin_height):
            continue

        # Берём единственный наиболее низкий соседний участок.
        # Обход всегда в одном порядке: одинаковый seed и дождь
        # дают одинаковые результаты вне зависимости от FPS.
        var destination := -1
        var lowest := origin_height - 0.02
        for offset in [
                Vector2i(1, 0), Vector2i(0, 1),
                Vector2i(-1, 0), Vector2i(0, -1)]:
            var next: Vector2i = cell + offset
            if not world.config.contains_cell(next):
                continue
            var target_index: int = hydro.cell_index(next)
            if hydro.has_water(target_index) or hydro.flooded_at(target_index):
                continue
            var height: float = world.height_at(
                Vector2(next) + Vector2(0.5, 0.5))
            if is_finite(height) and height < lowest:
                destination = target_index
                lowest = height
        if destination < 0:
            continue

        # Перенос в один проход не может увеличить массу золы.
        # Входящие порции учитываем заранее, чтобы два соседа
        # не переполнили одну принимающую клетку.
        var existing := int(_scorched.get(destination, {}).get("ash", 0))
        var capacity := 1000 - existing - int(incoming.get(destination, 0))
        if capacity <= 0:
            continue
        if not _scorched.has(destination) \
                and _scorched.size() + incoming.size() >= MAX_SCORCHED_CELLS:
            continue
        var request := mini(int(_scorched[index]["ash"]),
            clampi(roundi(runoff * 65.0), 0, 160))
        var amount := mini(request, maxi(0, capacity))
        if amount <= 0:
            continue
        outgoing[index] = amount
        incoming[destination] = int(incoming.get(destination, 0)) + amount
        source_dates[destination] = maxi(
            int(source_dates.get(destination, 0)),
            int(_scorched[index]["last_burn"]))
        changed[world.config.chunk_of(cell)] = true
        var target_cell := Vector2i(destination % world.config.width,
            destination / world.config.width)
        changed[world.config.chunk_of(target_cell)] = true
        _record("зольный сток", -1, cell)

    # Все исходящие порции списываются до входящих. Зола,
    # перенесённая сегодня, не сможет переместиться второй раз
    # в рамках тех же физических суток.
    for index in outgoing.keys():
        var entry: Dictionary = _scorched[index]
        entry["ash"] = int(entry["ash"]) - int(outgoing[index])
        if int(entry["ash"]) <= 0:
            _scorched.erase(index)
        else:
            _scorched[index] = entry
    for index in incoming.keys():
        var entry: Dictionary = _scorched.get(index, {})
        entry["ash"] = int(entry.get("ash", 0)) + int(incoming[index])
        entry["last_burn"] = maxi(int(entry.get("last_burn", 0)),
            int(source_dates[index]))
        _scorched[index] = entry


static func litter_spread_chance(dryness: float,
        gust: float, wind_alignment: float) -> float:
    # Ветер поднимает вероятность по потоку. Встречный поток
    # не распространяет тление против ветра, а мокрый грунт
    # даёт ровно нулевую вероятность.
    if dryness <= 0.0 or wind_alignment < -0.25:
        return 0.0
    return clampf(dryness * (0.08 + clampf(gust, 0.0, 60.0) / 90.0
        + maxf(0.0, wind_alignment) * 0.28), 0.0, 0.90)


func _ignite_litter(cell: Vector2i, changed: Dictionary) -> bool:
    # Запас подстилки появляется из реального плодородия и лесного
    # полога только при первом воспламенении сухой клетки. Сгоревший
    # участок с пеплом не получает бесконечные порции топлива.
    if not world.config.contains_cell(cell):
        return false
    var index: int = hydro.cell_index(cell)
    if _embers.has(index) or _embers.size() >= MAX_EMBERS \
            or _flammability(cell) < 0.20 or scorched_at(cell) > 0.15:
        return false
    var soil: Dictionary = surface.profile_at(
        cell, soil_damage_at(cell))
    if soil.is_empty() or soil.get("substrate", "") == "скала":
        return false
    var fertility: float = clampf(float(soil.get("fertility", 0.0)),
        0.0, 1.0)
    var canopy: float = nature.canopy_pressure_at(cell)
    var cover: float = clampf(fertility * 0.35 + canopy * 0.40, 0.0, 1.0)
    if cover < 0.15:
        return false
    _embers[index] = {
        "fuel": clampi(roundi(60.0 + cover * 285.0),
            60, MAX_LITTER_FUEL),
        "since": last_day
    }
    changed[world.config.chunk_of(cell)] = true
    _record("подстилка загорелась", -1, cell)
    return true


func _spread_litter(cell: Vector2i, source_index: int,
        changed: Dictionary) -> void:
    # Один тлеющий участок способен передать огонь максимум одной
    # соседней клетке за сутки. Детерминированный хеш исключает
    # зависимость результата от FPS, порядка рендера и чанков.
    if _embers.size() >= MAX_EMBERS:
        return
    var wind: Vector2 = climate.wind_direction_at_index(source_index)
    var gust: float = climate.wind_gust_at_index(source_index)
    for offset in [
            Vector2i(1, 0), Vector2i(0, 1),
            Vector2i(-1, 0), Vector2i(0, -1)]:
        var next: Vector2i = cell + offset
        if not world.config.contains_cell(next):
            continue
        var probability := litter_spread_chance(_flammability(next),
            gust, wind.dot(Vector2(offset)))
        if Terrain.hash2(next.x, next.y, world.config.world_seed
                + last_day * 79 + source_index * 13) >= probability:
            continue
        if _ignite_litter(next, changed):
            return


func _advance_litter(changed: Dictionary) -> void:
    # Обрабатываем снимок индексов, чтобы заново зажжённая соседняя
    # клетка начала тлеть только на следующий день. Дождь и снег
    # полностью гасят жар, но не обнуляют уже образовавшийся пепел.
    var indices: Array[int] = []
    for key in _embers.keys():
        indices.append(int(key))
    indices.sort()
    for index in indices:
        if not _embers.has(index):
            continue
        var cell := Vector2i(index % world.config.width,
            index / world.config.width)
        var dryness := _flammability(cell)
        if dryness < 0.12:
            _embers.erase(index)
            changed[world.config.chunk_of(cell)] = true
            _record("тление потушено", -1, cell)
            continue
        var state: Dictionary = _embers[index]
        var heat := clampi(roundi(20.0 + dryness * 65.0), 20, 85)
        state["fuel"] = maxi(0, int(state["fuel"]) - heat)
        _scorch(cell, heat, changed)
        _record("тление", -1, cell)
        if int(state["fuel"]) == 0:
            _embers.erase(index)
            changed[world.config.chunk_of(cell)] = true
            _record("угли остыли", -1, cell)
            continue
        _embers[index] = state
        _spread_litter(cell, index, changed)


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
        clampf(1.0 - snow / 0.12, 0.0, 1.0) * \
        (1.0 - scorched_at(cell) * 0.65)


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


func advance_day(day: int, strikes: Array = [],
        diagnostic_cell: Vector2i = Vector2i(-1, -1)) -> Array[Dictionary]:
    # Одна календарная дата обрабатывается один раз. Сначала горят
    # прежние очаги, потом учитываются молнии: удар не ускоряет сутки.
    if day <= last_day or day != climate.day or nature.last_day != day:
        return []
    last_day = day
    last_events.clear()
    # Восстановление земли идёт до нового выгорания; новый пепел
    # не исчезает в тот же физический день, когда образовался.
    var ground_changed := {}
    _recover_ground(ground_changed)
    _recover_soil(ground_changed)
    # Сначала естественная убыль золы, затем дождевой перенос.
    # Масса при переносе остаётся на суше без нового источника пепла.
    _wash_ash(ground_changed)
    _advance_litter(ground_changed)
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
        if nature.burn_object(id, heat, day):
            # До появления золы подхватываем сухую лесную подстилку,
            # затем её запас расходуется независимо от живого ствола.
            _ignite_litter(cell, ground_changed)
            _scorch(cell, heat, ground_changed)
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
    # Одна рассылка изменений на день не создаёт отдельные узлы
    # или дорогие сигналы для каждой частицы золы.
    nature.refresh_ground_visuals(ground_changed)
    return last_events.duplicate(true)


func to_data() -> Dictionary:
    # Активные очаги имеют целочисленные поля для строгой загрузки.
    # Никакие transient FX/анимации в сохранение не попадают.
    var entries := []
    for id in burning_ids():
        var entry: Dictionary = _burning[id]
        entries.append([id, int(entry["fuel"]), int(entry["since"])])
    var ash_entries := []
    var indices: Array[int] = []
    for index in _scorched.keys():
        indices.append(int(index))
    indices.sort()
    for index in indices:
        var ash: Dictionary = _scorched[index]
        ash_entries.append([index, int(ash["ash"]), int(ash["last_burn"])])
    var ember_entries := []
    var ember_indices: Array[int] = []
    for index in _embers.keys():
        ember_indices.append(int(index))
    ember_indices.sort()
    for index in ember_indices:
        var ember: Dictionary = _embers[index]
        ember_entries.append([index, int(ember["fuel"]), int(ember["since"])])
    var scar_entries := []
    var scar_indices: Array[int] = []
    for index in _soil_damage.keys():
        scar_indices.append(int(index))
    scar_indices.sort()
    for index in scar_indices:
        var scar: Dictionary = _soil_damage[index]
        scar_entries.append([index, int(scar["damage"]),
            int(scar["last_burn"])])
    return {
        "version": FORMAT_VERSION,
        "day": last_day, "total_ignitions": total_ignitions,
        "fires": entries, "scorched": ash_entries,
        "embers": ember_entries, "soil_damage": scar_entries
    }


func load_data(data: Dictionary) -> bool:
    # Валидация полностью проходит до замены активных очагов.
    # Это защищает уже открытый мир от повреждённого JSON.
    # Версия F1 содержала только очаги. Её читаем без пепла,
    # чтобы не терять ранние миры после обновления игры.
    var raw_version: Variant = data.get("version")
    if not (raw_version is int or raw_version is float) \
            or not is_finite(float(raw_version)):
        return false
    var version := int(raw_version)
    # JSON восстанавливает 1–4 как вещественные числа; проверяем
    # значение явно, иначе Array.has() сравнивает типы слишком строго.
    if float(version) != float(raw_version) \
            or version not in [1, 2, 3, FORMAT_VERSION]:
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
    # Физический след проверяется целиком до изменения действующего
    # реестра: битые индексы, даты и дубли не портят текущую карту.
    var parsed_scorched := {}
    if version >= 2:
        var marks: Variant = data.get("scorched")
        if not (marks is Array) or marks.size() > MAX_SCORCHED_CELLS:
            return false
        for mark in marks:
            if not (mark is Array) or mark.size() != 3:
                return false
            for value in mark:
                if not (value is int or value is float) \
                        or not is_finite(float(value)) \
                        or float(value) != float(int(value)):
                    return false
            var index := int(mark[0])
            var ash := int(mark[1])
            var burned_on := int(mark[2])
            if index < 0 or index >= world.config.width * world.config.height \
                    or parsed_scorched.has(index) or ash <= 0 or ash > 1000 \
                    or burned_on < 0 or burned_on > day:
                return false
            parsed_scorched[index] = {
                "ash": ash, "last_burn": burned_on
            }
    # Тление — самостоятельный сохраняемый реестр. Старые v1/v2
    # не содержали углей и продолжают загружаться с пустым слоем.
    var parsed_embers := {}
    if version >= 3:
        var raw_embers: Variant = data.get("embers")
        if not (raw_embers is Array) or raw_embers.size() > MAX_EMBERS:
            return false
        for mark in raw_embers:
            if not (mark is Array) or mark.size() != 3:
                return false
            for value in mark:
                if not (value is int or value is float) \
                        or not is_finite(float(value)) \
                        or float(value) != float(int(value)):
                    return false
            var cell_index := int(mark[0])
            var fuel := int(mark[1])
            var since := int(mark[2])
            if cell_index < 0 \
                    or cell_index >= world.config.width * world.config.height \
                    or parsed_embers.has(cell_index) or fuel <= 0 \
                    or fuel > MAX_LITTER_FUEL or since < 0 or since > day:
                return false
            parsed_embers[cell_index] = {
                "fuel": fuel, "since": since
            }
    # Старый JSON v1–v3 не имел самостоятельной почвенной травмы.
    # Повреждённые новые записи полностью отвергаются до записи
    # в реестр, включая дубли, нецелые числа и будущие даты.
    var parsed_soil := {}
    if version == FORMAT_VERSION:
        var raw_soil: Variant = data.get("soil_damage")
        if not (raw_soil is Array) or raw_soil.size() > MAX_SOIL_SCARS:
            return false
        for record in raw_soil:
            if not (record is Array) or record.size() != 3:
                return false
            for value in record:
                if not (value is int or value is float) \
                        or not is_finite(float(value)) \
                        or float(value) != float(int(value)):
                    return false
            var index := int(record[0])
            var damage := int(record[1])
            var burn_day := int(record[2])
            if index < 0 or index >= world.config.width * world.config.height \
                    or parsed_soil.has(index) or damage <= 0 \
                    or damage > 1000 or burn_day < 0 or burn_day > day:
                return false
            parsed_soil[index] = {
                "damage": damage, "last_burn": burn_day
            }
    _burning = parsed
    _scorched = parsed_scorched
    _embers = parsed_embers
    _soil_damage = parsed_soil
    last_day = day
    total_ignitions = total
    last_events.clear()
    return true
