extends RefCounted
## 12.5: численность диких травоядных по природным регионам.
## Популяции не являются узлами сцены и не создают пищу из воздуха.

const Terrain = preload("res://scripts/terrain.gd")
const Habitats = preload("res://scripts/wildlife_habitats.gd")
const Paths = preload("res://scripts/world_resource_path.gd")

const FORMAT_VERSION := 2
const MAX_REGIONS := 4096
const MAX_PER_REGION := 512
const MAX_MIGRANTS := 6
const UPDATE_DAYS := 8
const HABITAT_DAYS := 24
const DIRECTIONS := [
    Vector2i(-1, 0), Vector2i(1, 0),
    Vector2i(0, -1), Vector2i(0, 1)
]
const SPECIES := {
    "олень": {"space": 0.38, "birth": 0.11, "mortality": 0.018},
    "заяц": {"space": 0.90, "birth": 0.24, "mortality": 0.045},
    "кабан": {"space": 0.32, "birth": 0.13, "mortality": 0.025},
    "тур": {"space": 0.30, "birth": 0.10, "mortality": 0.025},
    "дикая курица": {"space": 0.65, "birth": 0.20, "mortality": 0.055},
    "дикий гусь": {"space": 0.38, "birth": 0.16, "mortality": 0.035}
}

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var nature: RefCounted
var habitats: RefCounted
var generated := false
var last_day := 0
var revision := 0
var _counts: Dictionary = {}
var _ages: Dictionary = {} # Когорты [молодые, взрослые, старые] по тем же ключам.
var _capacity: Dictionary = {}
var last_events := {"born": 0, "died": 0, "migrated": 0}


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        weather: RefCounted, vegetation: RefCounted) -> void:
    # Ссылки принадлежат физическому миру. Ни воды, ни травы,
    # ни животных создание объекта автоматически не добавляет.
    world = map
    hydro = water
    surface = ground
    climate = weather
    nature = vegetation
    habitats = Habitats.new(map, water, ground, weather, vegetation)
    last_day = weather.day


static func _key(region: Vector2i, species: String) -> String:
    # Ключ стабилен между запусками и хранит не координаты животного,
    # а регион его действующей популяции.
    return "%s:%d:%d" % [species, region.x, region.y]



static func _initial_ages(count: int) -> Array:
    # Для новой карты задаём компактное детерминированное соотношение возрастов.
    # Те же правила восстанавливают старые сохранения, в которых есть только count.
    var young := count / 4
    var old := count / 10
    return [young, count - young - old, old]


func age_at(region: Vector2i, species: String) -> Array:
    # Внешнему коду выдаём копию, чтобы UI и охота не могли изменить реестр.
    if not SPECIES.has(species) or not world.config.region_rect(region).has_area():
        return [0, 0, 0]
    var key := _key(region, species)
    return (_ages.get(key, [0, 0, 0]) as Array).duplicate()


static func _take_age(groups: Dictionary, key: String,
        amount: int, old_first: bool = false) -> Array:
    # При гибели в первую очередь теряем старых особей, при охоте —
    # взрослых. Это перераспределяет только уже существующую численность.
    var current: Array = (groups.get(key, [0, 0, 0]) as Array).duplicate()
    var removed := [0, 0, 0]
    var remaining := amount
    var order := [2, 1, 0] if old_first else [1, 2, 0]
    for index in order:
        var taken := mini(remaining, int(current[index]))
        current[index] = int(current[index]) - taken
        removed[index] = taken
        remaining -= taken
    if remaining != 0:
        push_error("Возрастные когорты не совпадают с численностью: " + key)
        return []
    if int(current[0]) + int(current[1]) + int(current[2]) == 0:
        groups.erase(key)
    else:
        groups[key] = current
    return removed


static func _add_age(groups: Dictionary, key: String, additions: Array) -> void:
    # Возраст сохраняется при переносе между регионами — миграция
    # не превращает старых животных в молодняк.
    var current: Array = (groups.get(key, [0, 0, 0]) as Array).duplicate()
    for index in range(3):
        current[index] = int(current[index]) + int(additions[index])
    groups[key] = current


static func _age_survivors(groups: Array, births: int, deaths: int) -> Array:
    # Старение идёт только в действующем восьмидневном цикле популяций.
    # Изменение возрастов не должно менять ранее проверенный прирост стада.
    var result: Array = groups.duplicate()
    var grown := int(result[0]) / 3
    var aged := int(result[1]) / 12
    result[0] = int(result[0]) - grown
    result[1] = int(result[1]) + grown - aged
    result[2] = int(result[2]) + aged
    # Смертность уже рассчитана общей экологией; снимаем те же
    # особи в порядке старые → взрослые → молодые, без двойного расхода.
    var remaining := deaths
    for index in [2, 1, 0]:
        var lost := mini(remaining, int(result[index]))
        result[index] = int(result[index]) - lost
        remaining -= lost
    result[0] = int(result[0]) + births
    return result


func _regions() -> Array[Vector2i]:
    # Обход всегда в одном порядке, независимо от камеры и чанков.
    var result: Array[Vector2i] = []
    var sizes: Vector2i = world.config.region_count()
    for y in range(sizes.y):
        for x in range(sizes.x):
            result.append(Vector2i(x, y))
    return result


func _survey() -> Dictionary:
    # Вместимость выводим из площади реально пригодных биотопов.
    # При исчезновении питьевой воды или корма вместимость падает.
    var result := {}
    for region in _regions():
        var report: Dictionary = habitats.region_report(region)
        if report.is_empty():
            continue
        var available: Dictionary = report["suitable"]
        for species in SPECIES:
            var suitable: int = int(available.get(species, 0))
            var factor: float = float(SPECIES[species]["space"])
            result[_key(region, species)] = clampi(
                roundi(float(suitable) * factor), 0, MAX_PER_REGION)
    return result


func generate() -> bool:
    # Начальные стада допустимы только там, где география уже
    # подтверждает корм, воду и укрытие. Никаких хищников без добычи.
    if generated or not nature.generated:
        return false
    var sizes: Vector2i = world.config.region_count()
    if sizes.x * sizes.y > MAX_REGIONS:
        return false
    _capacity = _survey()
    _counts.clear()
    _ages.clear()
    for region in _regions():
        for species in SPECIES:
            var key := _key(region, species)
            var limit: int = int(_capacity.get(key, 0))
            if limit <= 0:
                continue
            var chance := Terrain.hash2(region.x, region.y,
                world.config.world_seed + 35000 + species.hash())
            # Небольшая естественная исходная численность оставляет
            # свободное пространство для последующего размножения.
            _counts[key] = clampi(roundi(float(limit)
                * (0.43 + chance * 0.24)), 1, limit)
            _ages[key] = _initial_ages(int(_counts[key]))
    last_day = climate.day
    generated = true
    revision += 1
    return true


func population_at(region: Vector2i, species: String) -> int:
    # Несуществующие виды и внешние координаты не попадают
    # в реестр животных из ошибочного или чужого запроса.
    if not SPECIES.has(species) or not world.config.region_rect(region).has_area():
        return 0
    return int(_counts.get(_key(region, species), 0))


func capacity_at(region: Vector2i, species: String) -> int:
    # Вместимость — ограничение территории, не ресурс на складе.
    if not SPECIES.has(species) or not world.config.region_rect(region).has_area():
        return 0
    return int(_capacity.get(_key(region, species), 0))


func total(species: String = "") -> int:
    # Подсчёт по реестру, без создания тысяч NPC на карте.
    var count := 0
    for region in _regions():
        if species.is_empty():
            for kind in SPECIES:
                count += population_at(region, kind)
        else:
            count += population_at(region, species)
    return count


func _round_expected(expected: float, region: Vector2i,
        species: String, day: int, salt: int) -> int:
    # Для малых стад дробные ожидаемые рождения и смерти
    # проверяем стабильным хешем, не глобальным RandomNumberGenerator.
    var whole := floori(expected)
    var fraction := expected - float(whole)
    var random := Terrain.hash2(region.x + day, region.y,
        world.config.world_seed + species.hash() + salt)
    return whole + (1 if random < fraction else 0)


func _border_open(a: Vector2i, b: Vector2i) -> bool:
    # Граница соседних регионов должна иметь хотя бы один реальный
    # проход по суше. Через море и паводок популяция не переносится.
    var first: Rect2i = world.config.region_rect(a)
    var second: Rect2i = world.config.region_rect(b)
    if not first.has_area() or not second.has_area():
        return false
    if absi(a.x - b.x) + absi(a.y - b.y) != 1:
        return false
    if a.y == b.y:
        var edge: int = maxi(first.position.x, second.position.x)
        var low: int = maxi(first.position.y, second.position.y)
        var high: int = mini(first.end.y, second.end.y)
        for y in range(low, high, 2):
            if Paths.walkable(world, hydro, surface, Vector2i(edge - 1, y)) \
                    and Paths.walkable(world, hydro, surface, Vector2i(edge, y)):
                return true
    else:
        var edge: int = maxi(first.position.y, second.position.y)
        var low: int = maxi(first.position.x, second.position.x)
        var high: int = mini(first.end.x, second.end.x)
        for x in range(low, high, 2):
            if Paths.walkable(world, hydro, surface, Vector2i(x, edge - 1)) \
                    and Paths.walkable(world, hydro, surface, Vector2i(x, edge)):
                return true
    return false


func consume_prey(region: Vector2i, species: String, amount: int) -> bool:
    # Хищник обязан забрать существующих животных из исходного реестра.
    # Если животных не хватает, никакой добычи не возникает.
    if not generated or not SPECIES.has(species) or amount <= 0:
        return false
    var existing := population_at(region, species)
    if amount > existing:
        return false
    var key := _key(region, species)
    # Убираем реально существующие возрастные группы вместе с добычей.
    if _take_age(_ages, key, amount).is_empty():
        return false
    if amount == existing:
        _counts.erase(key)
    else:
        _counts[key] = existing - amount
    revision += 1
    return true


func can_cross(source: Vector2i, destination: Vector2i) -> bool:
    # Все миграции и эвакуации используют один реальный переход:
    # нельзя перемещать стада через затопленные границы.
    return _border_open(source, destination)


func react_hazards(hazards: Array) -> Dictionary:
    # Стихийное событие берём только из настоящей физики.
    # На сильную опасность стада уходят к свободной кормовой базе;
    # если безопасного перехода нет, возможна потеря особей.
    var moved := 0
    var lost := 0
    if not generated:
        return {"moved": moved, "lost": lost}
    for event in hazards:
        if not (event is Dictionary) or not (event.get("cell") is Vector2i):
            continue
        var kind := str(event.get("kind", ""))
        if kind not in ["шторм", "шквал", "ураган", "смерч",
                "паводок", "лавина", "сель", "оползень", "обвал",
                "землетрясение", "пожар"]:
            continue
        var power: float = float(event.get("severity", 0.0))
        var cell: Vector2i = event["cell"]
        if not is_finite(power) or power <= 0.0 \
                or not world.config.contains_cell(cell):
            continue
        var region: Vector2i = world.config.region_of(cell)
        for species in SPECIES:
            var key := _key(region, species)
            var count := population_at(region, species)
            if count <= 0:
                continue
            var risk := clampf(power, 0.0, 1.0)
            var fleeing := mini(count, maxi(1, roundi(float(count) * risk * 0.19)))
            var best := Vector2i(-1, -1)
            var available := 0
            for direction in DIRECTIONS:
                var neighbor: Vector2i = region + direction
                var vacancy := capacity_at(neighbor, species) \
                    - population_at(neighbor, species)
                if vacancy <= available or not can_cross(region, neighbor):
                    continue
                best = neighbor
                available = vacancy
            if best.x >= 0:
                var transferred := mini(fleeing, available)
                # Мигрирующие животные сохраняют возрастную группу.
                var cohorts := _take_age(_ages, key, transferred)
                if cohorts.is_empty():
                    continue
                _counts[key] = count - transferred
                var dest := _key(best, species)
                _add_age(_ages, dest, cohorts)
                _counts[dest] = population_at(best, species) + transferred
                moved += transferred
            elif risk >= 0.80:
                # Стихийное событие без безопасного выхода наносит урон,
                # но не уничтожает целый регион по одному событию.
                var casualties := mini(count, maxi(1,
                    roundi(float(count) * 0.06 * risk)))
                # Бедствие расходует старых особей первыми и не меняет
                # общий баланс уже рассчитанных потерь.
                if _take_age(_ages, key, casualties, true).is_empty():
                    continue
                _counts[key] = count - casualties
                lost += casualties
    if moved > 0 or lost > 0:
        revision += 1
        last_events["migrated"] = int(last_events["migrated"]) + moved
        last_events["died"] = int(last_events["died"]) + lost
    return {"moved": moved, "lost": lost}


func _change_population(day: int) -> Dictionary:
    # Рождение ограничено свободной кормовой ёмкостью. Смертность
    # растёт от перенаселения и исчезновения доступных биотопов.
    var born := 0
    var died := 0
    var next_counts: Dictionary = _counts.duplicate()
    var next_ages: Dictionary = _ages.duplicate(true)
    for region in _regions():
        for species in SPECIES:
            var key := _key(region, species)
            var current: int = int(next_counts.get(key, 0))
            if current <= 0:
                continue
            var limit: int = int(_capacity.get(key, 0))
            var rule: Dictionary = SPECIES[species]
            var space := maxf(0.0, 1.0 - float(current) / float(maxi(1, limit)))
            var births := _round_expected(float(current)
                * float(rule["birth"]) * space, region, species, day, 9127)
            var losses := _round_expected(float(current)
                * float(rule["mortality"]) + maxf(0.0,
                float(current - limit)) * 0.24,
                region, species, day, 12791)
            losses = mini(current, losses)
            var target := clampi(current + births - losses, 0, MAX_PER_REGION)
            var actual_births := maxi(0, target - current + losses)
            born += actual_births
            died += losses
            # Структура возрастов учитывает ровно те рождения и смерти,
            # которые уже применяет прежняя модель численности.
            var groups: Array = next_ages.get(key, _initial_ages(current))
            var aged := _age_survivors(groups, actual_births, losses)
            if target == 0:
                next_counts.erase(key)
                next_ages.erase(key)
            else:
                next_counts[key] = target
                next_ages[key] = aged

    # Сначала вычисляем общий результат размножения и смертности,
    # затем переносим существующих животных, не создавая новых.
    var migrated := 0
    for region in _regions():
        for species in SPECIES:
            var key := _key(region, species)
            var current: int = int(next_counts.get(key, 0))
            var limit: int = int(_capacity.get(key, 0))
            if current < 2 or (limit >= 2 and current < maxi(2, ceili(float(limit) * 0.58))):
                continue
            var best := Vector2i(-1, -1)
            var best_space := 0
            for direction in DIRECTIONS:
                var neighbor: Vector2i = region + direction
                var neighbor_limit := capacity_at(neighbor, species)
                var neighbor_count := int(next_counts.get(
                    _key(neighbor, species), 0))
                var space := neighbor_limit - neighbor_count
                if space <= best_space:
                    continue
                # Не гоняем животных между одинаково заполненными
                # территориями без экологического выигрыша.
                if float(neighbor_count) / float(maxi(1, neighbor_limit)) \
                        >= float(current) / float(maxi(1, limit)) - 0.10:
                    continue
                if not _border_open(region, neighbor):
                    continue
                best = neighbor
                best_space = space
            if best.x < 0:
                continue
            var transferred := mini(MAX_MIGRANTS, mini(
                maxi(1, current / 10), mini(current, best_space)))
            # При миграции переносим существующие возрастные когорты
            # вместе с числом животных, не создавая новые группы.
            var transferred_ages := _take_age(next_ages, key, transferred)
            if transferred_ages.is_empty():
                continue
            next_counts[key] = current - transferred
            var dest := _key(best, species)
            _add_age(next_ages, dest, transferred_ages)
            next_counts[dest] = int(next_counts.get(dest, 0)) + transferred
            migrated += transferred
    _ages = next_ages
    _counts = next_counts
    revision += 1
    return {"born": born, "died": died, "migrated": migrated}


func advance_day(day: int) -> bool:
    # Вызывающий код обязан передать один завершённый физический
    # день; скачок без климатических шагов исказил бы сезонный корм.
    if not generated or day != last_day + 1 or day != climate.day:
        return false
    last_day = day
    last_events = {"born": 0, "died": 0, "migrated": 0}
    if day % HABITAT_DAYS == 0:
        _capacity = _survey()
    if day % UPDATE_DAYS == 0:
        last_events = _change_population(day)
    return true


func summary() -> Dictionary:
    # Возвращаем итог без раскрытия изменяемого внутреннего словаря.
    var numbers := {}
    for species in SPECIES:
        numbers[species] = total(species)
    return {"day": last_day, "population": numbers,
        "events": last_events.duplicate(true), "revision": revision}


func to_data() -> Dictionary:
    # Сохраняем вместе с численностью действующую экологическую
    # ёмкость: загрузка в середине сезона не меняет траекторию роста.
    var entries: Array = []
    for region in _regions():
        for species in SPECIES:
            var key := _key(region, species)
            var amount := int(_counts.get(key, 0))
            var limit := int(_capacity.get(key, 0))
            if amount == 0 and limit == 0:
                continue
            # Когорты сериализуются вместе с прежними полями count/capacity.
            # Старые потребители численности не должны менять API.
            entries.append({"x": region.x, "y": region.y,
                "species": species, "count": amount, "capacity": limit,
                "ages": age_at(region, species)})
    return {"version": FORMAT_VERSION, "last_day": last_day,
        "generated": generated, "entries": entries}


func load_data(data: Dictionary) -> bool:
    # Валидируем снимок целиком, прежде чем менять живые популяции.
    # Старые миры без раздела обрабатывает WorldSave отдельно.
    # Версия 1 совместима: в ней были только общие количества животных.
    if data.get("version") not in [1, FORMAT_VERSION] \
            or data.get("generated") != true \
            or data.get("last_day") != climate.day \
            or not (data.get("entries") is Array):
        return false
    var entries: Array = data["entries"]
    if entries.size() > MAX_REGIONS * SPECIES.size():
        return false
    var restored := {}
    var restored_ages := {}
    var limits := {}
    for item in entries:
        if not (item is Dictionary):
            return false
        var species: Variant = item.get("species")
        if not (species is String) or not SPECIES.has(species):
            return false
        for field in ["x", "y", "count", "capacity"]:
            var value: Variant = item.get(field)
            if not (value is int or value is float) \
                    or not is_finite(float(value)) \
                    or float(value) != float(int(value)):
                return false
        var region := Vector2i(int(item["x"]), int(item["y"]))
        if not world.config.region_rect(region).has_area():
            return false
        var count := int(item["count"])
        var cap := int(item["capacity"])
        if count < 0 or count > MAX_PER_REGION \
                or cap < 0 or cap > MAX_PER_REGION \
                or (count == 0 and cap == 0):
            return false
        var key := _key(region, species)
        if limits.has(key):
            return false
        # В новых снимках сумма когорт строго равна общей численности.
        # Невалидный массив отклоняется до изменений живого мира.
        var ages := _initial_ages(count)
        if data["version"] == FORMAT_VERSION:
            var raw_ages: Variant = item.get("ages")
            if not (raw_ages is Array) or raw_ages.size() != 3:
                return false
            ages = []
            for value in raw_ages:
                if not (value is int or value is float) \
                        or not is_finite(float(value)) \
                        or float(value) != float(int(value)) \
                        or int(value) < 0:
                    return false
                ages.append(int(value))
            if int(ages[0]) + int(ages[1]) + int(ages[2]) != count:
                return false
        if count > 0:
            restored[key] = count
            restored_ages[key] = ages
        limits[key] = cap
    _counts = restored
    _ages = restored_ages
    _capacity = limits
    last_day = climate.day
    generated = true
    revision += 1
    return true
