extends RefCounted
## Детерминированные дикие популяции этапа 12.5 по природным регионам.
## Животные не представлены множеством Godot Node3D и не создаются зданиями.

const Terrain = preload("res://scripts/terrain.gd")
const Habitats = preload("res://scripts/wildlife_habitats.gd")
const VERSION := 1
const MAX_GROUPS := 5000
const MAX_GROUP_ANIMALS := 3000
const MAX_TOTAL_ANIMALS := 250000

var world: RefCounted
var habitat: RefCounted
var last_day := 0
var generated := false
var _groups: Dictionary = {}
var last_births := 0
var last_deaths := 0
var last_migrated := 0
var revision := 0


func _init(map: RefCounted, environment: RefCounted) -> void:
    # Оставляем одну ссылку на физические биотопы: популяции не могут
    # создавать собственные воду, траву или деревья при расчёте.
    world = map
    habitat = environment
    last_day = environment.climate.day


static func _id(region: Vector2i, species: String) -> String:
    # Ключ не зависит от размера чанка и числа открытых камер.
    return "%d:%d|%s" % [region.x, region.y, species]


func generate() -> bool:
    # Первичная фауна формируется единожды на основании уже существующей
    # ёмкости и seed, без минимального гарантированного числа животных.
    if generated or not habitat.rebuild(habitat.climate.day):
        return false
    var next := {}
    var regions: Vector2i = world.config.region_count()
    for y in regions.y:
        for x in regions.x:
            var region := Vector2i(x, y)
            var zones: Dictionary = habitat.zone(region)
            for species in Habitats.SPECIES:
                var capacity: int = int(zones[species]["capacity"])
                if capacity < 6 or int(zones[species]["water_sites"]) == 0:
                    continue
                var value := Terrain.hash2(x, y,
                    world.config.world_seed + 9821 + species.hash())
                # Часть подходящих ареалов незаселённая: наличие пищи
                # ещё не гарантирует миграцию дикого животного туда.
                if value < 0.17:
                    continue
                var total := clampi(floori(float(capacity)
                    * (0.24 + value * 0.36)), 1, capacity)
                var young := total / 4
                var senior := total / 9
                var adult := total - young - senior
                if adult < 1:
                    continue
                next[_id(region, species)] = {
                    "region": [x, y], "species": species,
                    "young": young, "adult": adult, "senior": senior
                }
    if next.size() > MAX_GROUPS:
        return false
    _groups = next
    generated = true
    last_day = habitat.climate.day
    revision += 1
    return true


func _count(group: Dictionary) -> int:
    # Общая численность — сумма возрастных классов, а не счётчик
    # объектов в визуальной сцене и не наследие предыдущего кадра.
    return int(group["young"]) + int(group["adult"]) + int(group["senior"])


func total() -> int:
    # Суммируем только физически существующие региональные группы.
    var amount := 0
    for group in _groups.values():
        amount += _count(group)
    return amount


func by_species() -> Dictionary:
    # Агрегаты нужны для игрового HUD и проверки сохранения массы
    # при миграциях без перебора отдельных особей.
    var result := {}
    for species in Habitats.SPECIES:
        result[species] = 0
    for group in _groups.values():
        var species: String = group["species"]
        result[species] = int(result[species]) + _count(group)
    return result


func _daily_change(group: Dictionary, day: int,
        capacity: int, food: float) -> Dictionary:
    # Старение только переносит существующих особей между классами.
    # Рождения требуют живых взрослых и доступного корма/воды.
    var result: Dictionary = group.duplicate(true)
    var young: int = result["young"]
    var adult: int = result["adult"]
    var senior: int = result["senior"]
    # В возрастных когортах нет сотен отдельных Node3D. Для малых
    # групп детерминированная вероятность переносит отдельных особей,
    # не обнуляя взросление и старение из-за целочисленного деления.
    var coords: Array = group["region"]
    var rx: int = int(coords[0])
    var ry: int = int(coords[1])
    var seed: int = world.config.world_seed + str(group["species"]).hash()
    var maturation_rate := float(young) / 96.0
    var mature := floori(maturation_rate)
    if Terrain.hash2(rx + day * 11, ry + day * 7, seed + 304) \
            < maturation_rate - float(mature):
        mature += 1
    var aging_rate := float(adult) / float(9 * 96)
    var aging := floori(aging_rate)
    if Terrain.hash2(rx + day * 13, ry + day * 19, seed + 508) \
            < aging_rate - float(aging):
        aging += 1
    mature = mini(mature, young)
    aging = mini(aging, adult)
    young -= mature
    adult += mature - aging
    senior += aging
    var existing := young + adult + senior
    var overcrowded := maxi(0, existing - capacity)
    var starvation := mini(existing, ceili(float(overcrowded) * 0.08))
    var cold := 0
    if food < 0.15 and existing > 0:
        cold = maxi(1, existing / 120)
    var deaths := mini(senior, senior / 165 + cold)
    senior -= deaths
    var remaining := maxi(0, starvation + cold - deaths)
    var young_deaths := mini(young, remaining)
    young -= young_deaths
    remaining -= young_deaths
    var adult_deaths := mini(adult, remaining)
    adult -= adult_deaths
    deaths += young_deaths + adult_deaths
    var births := 0
    if day % 96 < 48 and adult > 1 and capacity > existing \
            and food >= 0.13:
        # Вероятность привязана к числу взрослых, корму и виду.
        # Даже малые группы способны дать молодняк, но только при
        # наличии свободной кормовой ёмкости и сезонного окна.
        var denominator := 22 if group["species"] == "куропатка" else (
            32 if group["species"] == "заяц" else 65)
        var potential := float(adult) * food / float(denominator)
        births = floori(potential)
        if Terrain.hash2(rx + day * 17, ry + day * 31, seed + 822) \
                < potential - float(births):
            births += 1
        births = mini(births, maxi(0, capacity - existing))
    young += births
    result["young"] = young
    result["adult"] = adult
    result["senior"] = senior
    return {"group": result, "births": births, "deaths": deaths}


func advance_day(day: int) -> bool:
    # Нельзя пропускать промежуточные сутки: крупный скачок календаря
    # не должен терять рождаемость, смерти и миграционные перемещения.
    if not generated or day != last_day + 1 \
            or day != habitat.climate.day or not habitat.rebuild(day):
        return false
    var birth_count := 0
    var death_count := 0
    var moved_count := 0
    var updated := {}
    var ids := _groups.keys()
    ids.sort()
    for id in ids:
        var group: Dictionary = _groups[id]
        var region := Vector2i(int(group["region"][0]), int(group["region"][1]))
        var species: String = group["species"]
        var zone: Dictionary = habitat.zone(region)[species]
        var change: Dictionary = _daily_change(group, day,
            int(zone["capacity"]), float(zone["food"]))
        updated[id] = change["group"]
        birth_count += int(change["births"])
        death_count += int(change["deaths"])

    # Миграцию рассчитываем по исходному снимку дня и потом
    # применяем отдельно: нельзя переселить одну особь дважды.
    var movements: Array = []
    # Резервируем свободные места до переселения: несколько соседей
    # не могут независимо заполнить один и тот же регион сверх лимита.
    var incoming := {}
    var bounds: Vector2i = world.config.region_count()
    for id in ids:
        var group: Dictionary = updated[id]
        var region := Vector2i(int(group["region"][0]), int(group["region"][1]))
        var species: String = group["species"]
        var current: int = _count(group)
        if int(group["adult"]) < 3 or current < 8:
            continue
        var origin: Dictionary = habitat.zone(region)[species]
        var origin_cap: int = int(origin["capacity"])
        var best_score := -1.0
        var destination := Vector2i(-1, -1)
        for delta in [Vector2i(1, 0), Vector2i(0, 1),
                Vector2i(-1, 0), Vector2i(0, -1)]:
            var neighbor: Vector2i = region + delta
            if neighbor.x < 0 or neighbor.y < 0 \
                    or neighbor.x >= bounds.x or neighbor.y >= bounds.y:
                continue
            var target: Dictionary = habitat.zone(neighbor)[species]
            var target_cap: int = int(target["capacity"])
            var neighbor_id := _id(neighbor, species)
            var used := _count(updated.get(neighbor_id, {
                "young": 0, "adult": 0, "senior": 0
            }))
            used += int(incoming.get(neighbor_id, 0))
            if target_cap <= 0 or int(target["water_sites"]) == 0 \
                    or used >= target_cap:
                continue
            var score := float(target_cap - used) / float(target_cap)
            if score > best_score:
                best_score = score
                destination = neighbor
        if destination.x < 0:
            continue
        # Только взрослые могут перейти в соседний пригодный ареал;
        # пустой регион заселяется исключительно реальными мигрантами.
        var count := mini(int(group["adult"]) / 7, 4)
        if current > origin_cap:
            count = mini(int(group["adult"]) / 4, 8)
        if count <= 0:
            continue
        var target_id := _id(destination, species)
        var target_zone: Dictionary = habitat.zone(destination)[species]
        var existing: int = _count(updated.get(target_id, {
            "young": 0, "adult": 0, "senior": 0
        }))
        count = mini(count, int(target_zone["capacity"]) - existing
            - int(incoming.get(target_id, 0)))
        if count > 0:
            incoming[target_id] = int(incoming.get(target_id, 0)) + count
            movements.append({"from": id, "to": target_id, "count": count,
                "region": [destination.x, destination.y], "species": species})
    for movement in movements:
        var from_id: String = movement["from"]
        var to_id: String = movement["to"]
        var count: int = mini(int(movement["count"]),
            int(updated[from_id]["adult"]))
        if count <= 0:
            continue
        var target: Dictionary = updated.get(to_id, {
            "region": movement["region"], "species": movement["species"],
            "young": 0, "adult": 0, "senior": 0
        })
        updated[from_id]["adult"] -= count
        target["adult"] = int(target["adult"]) + count
        updated[to_id] = target
        moved_count += count
    # Удаление исчезнувших групп не порождает новых особей.
    var alive := {}
    for id in updated:
        if _count(updated[id]) > 0:
            alive[id] = updated[id]
    if alive.size() > MAX_GROUPS:
        return false
    _groups = alive
    last_births = birth_count
    last_deaths = death_count
    last_migrated = moved_count
    last_day = day
    revision += 1
    return true


func to_data() -> Dictionary:
    # Порядок групп стабилен для одинакового seed и игровых событий.
    var ids := _groups.keys()
    ids.sort()
    var entries: Array = []
    for id in ids:
        entries.append((_groups[id] as Dictionary).duplicate(true))
    return {"version": VERSION, "generated": generated,
        "last_day": last_day, "groups": entries}


func load_data(data: Dictionary) -> bool:
    # Сначала валидируем все группы, затем заменяем реестр целиком.
    # Негативные/дробные числа и несуществующие виды не импортируются.
    if data.get("version") != VERSION \
            or not (data.get("generated") is bool) \
            or not (data.get("groups") is Array) \
            or data.get("last_day") != habitat.climate.day:
        return false
    var entries: Array = data["groups"]
    if entries.size() > MAX_GROUPS or not bool(data["generated"]) \
            and not entries.is_empty():
        return false
    var result := {}
    var count_total := 0
    var regions: Vector2i = world.config.region_count()
    for item in entries:
        if not (item is Dictionary) \
                or str(item.get("species", "")) not in Habitats.SPECIES \
                or not (item.get("region") is Array) \
                or item["region"].size() != 2:
            return false
        var coords: Array = item["region"]
        for number in coords:
            if not (number is int or number is float) \
                    or not is_finite(float(number)) \
                    or float(number) != float(int(number)):
                return false
        var region := Vector2i(int(coords[0]), int(coords[1]))
        if region.x < 0 or region.y < 0 \
                or region.x >= regions.x or region.y >= regions.y:
            return false
        for key in ["young", "adult", "senior"]:
            var number: Variant = item.get(key)
            if not (number is int or number is float) \
                    or not is_finite(float(number)) \
                    or float(number) != float(int(number)) \
                    or number < 0 or number > MAX_GROUP_ANIMALS:
                return false
        var total_group := _count(item)
        if total_group <= 0 or total_group > MAX_GROUP_ANIMALS:
            return false
        var key := _id(region, str(item["species"]))
        if result.has(key):
            return false
        result[key] = {
            "region": [region.x, region.y], "species": str(item["species"]),
            "young": int(item["young"]), "adult": int(item["adult"]),
            "senior": int(item["senior"])
        }
        count_total += total_group
        if count_total > MAX_TOTAL_ANIMALS:
            return false
    _groups = result
    generated = bool(data["generated"])
    last_day = int(data["last_day"])
    revision += 1
    return true
