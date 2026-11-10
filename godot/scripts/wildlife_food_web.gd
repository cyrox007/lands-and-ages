extends RefCounted
## 12.6: хищники питаются только живой добычей из WildlifePopulations.
## Природные бедствия перемещают или сокращают существующие стада.

const Terrain = preload("res://scripts/terrain.gd")
const FORMAT_VERSION := 1
const MAX_PER_REGION := 24
const UPDATE_DAYS := 8
const DIRECTIONS := [
    Vector2i(-1, 0), Vector2i(1, 0),
    Vector2i(0, -1), Vector2i(0, 1)
]
const SPECIES := {
    # Волки могут охотиться на дикого тура, гусей и кур наряду
    # с оленем, кабаном и зайцем. Каждая добыча реальна, а
    # запас размножающегося стада сохраняет _huntable().
    "волк": {"prey": ["олень", "кабан", "заяц", "тур",
        "дикий гусь", "дикая курица"],
        "need": 3, "birth": 0.10, "death": 0.035},
    # Лисица питается не только зайцами, но и настоящей дикой
    # птицей из природных популяций; яйца/грызуны пока не моделируются.
    "лиса": {"prey": ["заяц", "дикая курица", "дикий гусь"],
        "need": 2, "birth": 0.16, "death": 0.045},
    "дикая кошка": {"prey": ["заяц", "дикая курица"],
        "need": 2, "birth": 0.13, "death": 0.035}
}

var world: RefCounted
var climate: RefCounted
var prey: RefCounted
var generated := false
var last_day := 0
var revision := 0
var _packs: Dictionary = {}
var _capacity: Dictionary = {}
var last_events := {
    "eaten": 0, "born": 0, "died": 0,
    "migrated": 0, "prey_fled": 0, "prey_lost": 0
}


func _init(map: RefCounted, weather: RefCounted,
        herbivores: RefCounted) -> void:
    # Предаторы работают с тем же живым реестром травоядных,
    # что сцена, сохранение и природный календарь.
    world = map
    climate = weather
    prey = herbivores
    last_day = weather.day


static func _key(region: Vector2i, kind: String) -> String:
    # Каждая стая относится к одной природной области и виду.
    return "%s:%d:%d" % [kind, region.x, region.y]


func _regions() -> Array[Vector2i]:
    # Стабильный обход исключает зависимость событий от камеры.
    var result: Array[Vector2i] = []
    var size: Vector2i = world.config.region_count()
    for y in range(size.y):
        for x in range(size.x):
            result.append(Vector2i(x, y))
    return result


func _limit(region: Vector2i, kind: String) -> int:
    # Ёмкость для хищников выводится из настоящих травоядных.
    # Растительный корм напрямую не становится мясом.
    var deer: int = prey.population_at(region, "олень")
    var boar: int = prey.population_at(region, "кабан")
    var aurochs: int = prey.population_at(region, "тур")
    var hare: int = prey.population_at(region, "заяц")
    var fowl: int = prey.population_at(region, "дикая курица")
    var geese: int = prey.population_at(region, "дикий гусь")
    if kind == "волк":
        # Тур и другие копытные определяют основу ёмкости стаи,
        # птица лишь немного расширяет доступную кормовую базу.
        return mini(MAX_PER_REGION,
            (deer * 2 + boar * 2 + aurochs * 2 + hare + geese + fowl / 2) / 14)
    # Ёмкость лис и кошек зависит от настоящей дикой птицы,
    # которой в малом ареале нельзя подкормить бесконечную стаю.
    if kind == "лиса":
        return mini(MAX_PER_REGION, (hare + fowl / 2 + geese / 3) / 5)
    if kind == "дикая кошка":
        return mini(MAX_PER_REGION, (hare + fowl / 2) / 9)
    return 0


func generate() -> bool:
    # Хищник не может возникнуть в пустом биотопе или без добычи.
    if generated or not prey.generated:
        return false
    _packs.clear()
    _capacity.clear()
    for region in _regions():
        for kind in SPECIES:
            var limit := _limit(region, kind)
            var key := _key(region, kind)
            _capacity[key] = limit
            if limit == 0:
                continue
            var chance := Terrain.hash2(region.x, region.y,
                world.config.world_seed + 67000 + kind.hash())
            _packs[key] = clampi(
                roundi(float(limit) * (0.40 + chance * 0.30)), 1, limit)
    generated = true
    last_day = climate.day
    revision += 1
    return true


func count_at(region: Vector2i, kind: String) -> int:
    # Запрос чужого вида или региона возвращает ноль.
    if not SPECIES.has(kind) or not world.config.region_rect(region).has_area():
        return 0
    return int(_packs.get(_key(region, kind), 0))


func total(kind: String = "") -> int:
    # Хищники не создают Node3D и считаются независимо от рендера.
    var sum := 0
    for region in _regions():
        for animal in SPECIES:
            if kind.is_empty() or animal == kind:
                sum += count_at(region, animal)
    return sum


func capture_predators(region: Vector2i, kind: String,
        amount: int) -> bool:
    # Отлов волков и диких кошек отнимает реальные особи из стаи.
    # Пустой ареал не является бесплатным источником собак и кошек.
    if not generated or not SPECIES.has(kind) or amount < 1 \
            or count_at(region, kind) < amount:
        return false
    var key := _key(region, kind)
    var remaining := count_at(region, kind) - amount
    if remaining == 0:
        _packs.erase(key)
    else:
        _packs[key] = remaining
    revision += 1
    return true


func _huntable(region: Vector2i, species: String) -> int:
    # Минимальное воспроизводящее ядро остаётся в природе.
    # Хищники не могут систематически съедать последних
    # оленей из ареала, если есть более массовая добыча.
    var count: int = prey.population_at(region, species)
    var capacity: int = prey.capacity_at(region, species)
    var minimum := 3 if species == "заяц" else 2
    var refuge := maxi(minimum, ceili(float(capacity) * 0.30))
    return maxi(0, count - refuge)


func _feed(region: Vector2i, kind: String, amount: int) -> int:
    # Выбираем действительную доступную добычу, а не первый вид
    # из постоянного списка. Давление охоты распределяется по
    # экологическому избытку разных видов в одном ареале.
    var taken := 0
    var options: Array = SPECIES[kind]["prey"]
    while taken < amount:
        var chosen := ""
        var best := -1.0
        for species in options:
            var available := _huntable(region, str(species))
            if available <= 0:
                continue
            # Сравнение с вместимостью учитывает разную плотность
            # животных, не превращая один вид в вечную добычу.
            var capacity: int = prey.capacity_at(region, str(species))
            var pressure := float(available) / float(maxi(1, capacity))
            if pressure > best:
                chosen = str(species)
                best = pressure
        if chosen.is_empty():
            break
        # Списываем конкретную живую особь; никакого условного
        # «мяса» при пустом ареале не появляется.
        if not prey.consume_prey(region, chosen, 1):
            break
        taken += 1
    return taken

func _forage(region: Vector2i, kind: String) -> int:
    # Кормовой резерв учитывает лишь настоящих живых особей,
    # доступных сверх минимума размножающегося стада.
    var amount := 0
    for species in SPECIES[kind]["prey"]:
        amount += _huntable(region, str(species))
    return amount


func _seek_food() -> int:
    # Уход от голода предшествует охоте и естественной смертности.
    # Маленькая стая не должна погибать мгновенно лишь потому,
    # что её текущие зайцы ушли в соседний пригодный регион.
    var before: Dictionary = _packs.duplicate()
    var next: Dictionary = before.duplicate()
    var moved := 0
    for region in _regions():
        for kind in SPECIES:
            var key := _key(region, kind)
            var count: int = int(before.get(key, 0))
            if count <= 0:
                continue
            var needed := maxi(1, ceili(float(count) /
                float(SPECIES[kind]["need"])))
            var local_food := _forage(region, kind)
            if local_food >= needed:
                continue
            var best := Vector2i(-1, -1)
            var best_surplus := local_food - needed
            for direction in DIRECTIONS:
                var neighbor: Vector2i = region + direction
                var vacancy := _limit(neighbor, kind) \
                    - int(next.get(_key(neighbor, kind), 0))
                if vacancy <= 0 or not prey.can_cross(region, neighbor):
                    continue
                var food := _forage(neighbor, kind)
                var already: int = int(next.get(_key(neighbor, kind), 0))
                var demand := ceili(float(already) /
                    float(SPECIES[kind]["need"]))
                var surplus := food - demand
                if surplus <= best_surplus:
                    continue
                best = neighbor
                best_surplus = surplus
            if best.x < 0 or int(next.get(key, 0)) <= 0:
                continue
            var target := _key(best, kind)
            next[key] = int(next[key]) - 1
            next[target] = int(next.get(target, 0)) + 1
            moved += 1
    if moved > 0:
        _packs = next
    return moved


func _advance_packs(day: int) -> Dictionary:
    # Сначала охота, затем рождаемость и смертность, затем миграция.
    # Итог по каждому виду остаётся в проверяемых числовых пределах.
    var eaten := 0
    var born := 0
    var died := 0
    var migrated := _seek_food()
    var next_packs: Dictionary = _packs.duplicate()
    for region in _regions():
        for kind in SPECIES:
            var key := _key(region, kind)
            var current := int(next_packs.get(key, 0))
            var limit := _limit(region, kind)
            _capacity[key] = limit
            if current <= 0:
                continue
            var rule: Dictionary = SPECIES[kind]
            var need := maxi(1, ceili(float(current) /
                float(rule["need"])))
            var consumed := _feed(region, kind, need)
            eaten += consumed
            var supported := mini(current, consumed * int(rule["need"]))
            var shortage := current - supported
            # Неудачная охота повышает риск смерти, но для
            # одиночной лисы не означает гарантированную гибель
            # после первого голодного восьмидневного цикла.
            var expected_starvation := float(shortage) * 0.32
            var starvation := floori(expected_starvation)
            var risk := Terrain.hash2(region.x + day, region.y,
                world.config.world_seed + 63179 + kind.hash())
            if risk < expected_starvation - float(starvation):
                starvation += 1
            var natural := floori(float(current) * float(rule["death"]))
            var losses := mini(current, starvation + natural)
            var space := maxf(0.0, 1.0 - float(current) /
                float(maxi(1, limit)))
            var expected := float(current - losses) \
                * float(rule["birth"]) * space
            var extra := floori(expected)
            var chance := Terrain.hash2(region.x + day, region.y,
                world.config.world_seed + 81000 + kind.hash())
            if chance < expected - float(extra):
                extra += 1
            if consumed == 0:
                extra = 0
            var new_count := clampi(current - losses + extra,
                0, MAX_PER_REGION)
            born += maxi(0, new_count - current + losses)
            died += losses
            if new_count == 0:
                next_packs.erase(key)
            else:
                next_packs[key] = new_count

    # Уходим только через проходимые границы, если соседний ареал
    # может прокормить переселяемых хищников настоящей добычей.
    for region in _regions():
        for kind in SPECIES:
            var key := _key(region, kind)
            var current := int(next_packs.get(key, 0))
            var limit := _limit(region, kind)
            if current <= 1 or current < limit:
                continue
            var best := Vector2i(-1, -1)
            var vacancy := 0
            for direction in DIRECTIONS:
                var neighbor: Vector2i = region + direction
                var space := _limit(neighbor, kind) - int(
                    next_packs.get(_key(neighbor, kind), 0))
                if space <= vacancy or not prey.can_cross(region, neighbor):
                    continue
                best = neighbor
                vacancy = space
            if best.x < 0:
                continue
            var moving := mini(2, mini(current, vacancy))
            next_packs[key] = current - moving
            var dest := _key(best, kind)
            next_packs[dest] = int(next_packs.get(dest, 0)) + moving
            migrated += moving
    _packs = next_packs
    revision += 1
    return {"eaten": eaten, "born": born, "died": died, "migrated": migrated}


func _flee(hazards: Array) -> Dictionary:
    # Настоящие катастрофы вызывают попытку покинуть регион,
    # но не мгновенную телепортацию через море или появление стаи.
    var moved := 0
    var lost := 0
    for event in hazards:
        if not (event is Dictionary) or not (event.get("cell") is Vector2i):
            continue
        var severity := float(event.get("severity", 0.0))
        var cell: Vector2i = event["cell"]
        if not is_finite(severity) or severity < 0.50 \
                or not world.config.contains_cell(cell):
            continue
        var region: Vector2i = world.config.region_of(cell)
        for kind in SPECIES:
            var key := _key(region, kind)
            var current := count_at(region, kind)
            if current <= 0:
                continue
            var neighbor_best := Vector2i(-1, -1)
            var available := 0
            for direction in DIRECTIONS:
                var dest: Vector2i = region + direction
                var capacity := _limit(dest, kind) - count_at(dest, kind)
                if capacity <= available or not prey.can_cross(region, dest):
                    continue
                neighbor_best = dest
                available = capacity
            if neighbor_best.x >= 0:
                var traveling := mini(current, mini(2, available))
                _packs[key] = current - traveling
                var target := _key(neighbor_best, kind)
                _packs[target] = count_at(neighbor_best, kind) + traveling
                moved += traveling
            elif severity >= 0.85:
                _packs[key] = current - 1
                lost += 1
    if moved > 0 or lost > 0:
        revision += 1
    return {"migrated": moved, "died": lost}


func advance_day(day: int, hazards: Array = []) -> bool:
    # Сначала обновляются сами травоядные, затем реальные бедствия,
    # после чего хищники охотятся на оставшиеся живые популяции.
    if not generated or not prey.generated \
            or day != last_day + 1 or day != climate.day \
            or prey.last_day != day:
        return false
    last_day = day
    var prey_hazards: Dictionary = prey.react_hazards(hazards)
    var predator_hazards: Dictionary = _flee(hazards)
    var report := {
        "eaten": 0, "born": 0,
        "died": int(predator_hazards["died"]),
        "migrated": int(predator_hazards["migrated"]),
        "prey_fled": int(prey_hazards["moved"]),
        "prey_lost": int(prey_hazards["lost"])
    }
    if day % UPDATE_DAYS == 0:
        var step: Dictionary = _advance_packs(day)
        for key in ["eaten", "born", "died", "migrated"]:
            report[key] = int(report[key]) + int(step[key])
    last_events = report
    return true


func summary() -> Dictionary:
    # Диагностика не получает ссылок на изменяемые группы хищников.
    return {"day": last_day, "wolf": total("волк"), "fox": total("лиса"),
        "events": last_events.duplicate(true), "revision": revision}


func to_data() -> Dictionary:
    # Стабильный порядок нужен для восстановления и воспроизводимости.
    var entries: Array = []
    for region in _regions():
        for species in SPECIES:
            var amount := count_at(region, species)
            var cap := int(_capacity.get(_key(region, species), 0))
            if amount == 0 and cap == 0:
                continue
            entries.append({"x": region.x, "y": region.y, "species": species,
                "count": amount, "capacity": cap})
    return {"version": FORMAT_VERSION, "day": last_day,
        "generated": generated, "entries": entries}


func load_data(data: Dictionary) -> bool:
    # Восстановление атомарно: при повреждении ни одна стая
    # не изменяется и травоядные не пересоздаются.
    if not prey.generated or data.get("version") != FORMAT_VERSION \
            or data.get("generated") != true or data.get("day") != climate.day \
            or not (data.get("entries") is Array):
        return false
    var entries: Array = data["entries"]
    if entries.size() > 4096 * SPECIES.size():
        return false
    var restored := {}
    var limits := {}
    for item in entries:
        if not (item is Dictionary) or not SPECIES.has(item.get("species")):
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
        var key := _key(region, str(item["species"]))
        if limits.has(key):
            return false
        limits[key] = cap
        if count > 0:
            restored[key] = count
    _packs = restored
    _capacity = limits
    last_day = climate.day
    generated = true
    revision += 1
    return true
