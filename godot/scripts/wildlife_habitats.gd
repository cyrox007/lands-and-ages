extends RefCounted
## Экологические участки этапа 12.4: настоящая пища, пресная вода и укрытия.
## Модель использует готовые гидрологию, почвы, климат и лес этапов 10–11.

const SPECIES := {
    "олень": {"biomes": ["тайга", "умеренный лес", "влажный тёплый лес"],
        "food": 0.17, "water": 0.22, "shelter": 0.25, "density": 0.12},
    "заяц": {"biomes": ["степь", "холодная степь", "тайга", "умеренный лес",
        "тундра", "саванна"], "food": 0.11, "water": 0.10,
        "shelter": 0.04, "density": 0.27},
    "куропатка": {"biomes": ["степь", "холодная степь", "тундра",
        "тайга", "умеренный лес"], "food": 0.08, "water": 0.10,
        "shelter": 0.03, "density": 0.28},
    "кабан": {"biomes": ["умеренный лес", "влажный тёплый лес", "тайга"],
        "food": 0.20, "water": 0.28, "shelter": 0.15, "density": 0.10}
}
const SAMPLE_AXIS := 5
const WATER_RADIUS := 7
const WATER_DIRECTIONS := [
    Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
    Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, 1),
    Vector2i(1, -1), Vector2i(-1, -1)
]

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var nature: RefCounted
var fire: RefCounted
var revision := 0
var last_day := -1
var _zones: Dictionary = {}


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        weather: RefCounted, vegetation: RefCounted,
        burning: RefCounted = null) -> void:
    # Модель не владеет данными гидрологии и не создаёт второй лес.
    world = map
    hydro = water
    surface = ground
    climate = weather
    nature = vegetation
    fire = burning


func _fresh_water(cell: Vector2i) -> float:
    # Море солёное и не снабжает сухопутное стадо питьевой водой.
    # Проверяем доступную пресную воду в соседних клетках без
    # глобального сканирования всех рек на каждый игровой день.
    for radius in [1, 3, 5, WATER_RADIUS]:
        for direction in WATER_DIRECTIONS:
            var next: Vector2i = cell + direction * radius
            if not world.config.contains_cell(next):
                continue
            var i: int = next.y * world.config.width + next.x
            if hydro.has_water(i) and not hydro.ocean_at(i):
                return clampf(1.0 - float(radius - 1) / 9.0, 0.0, 1.0)
    return 0.0


func _sample(cell: Vector2i) -> Dictionary:
    # Пища определяется настоящим травяным покровом, а укрытие —
    # живыми деревьями. Снег, заболачивание и затопление ограничивают
    # пригодность: пустой участок не получает выдуманную кормовую базу.
    var i: int = cell.y * world.config.width + cell.x
    if hydro.has_water(i) or hydro.flooded_at(i):
        return {}
    var soil: Dictionary = surface.profile_at(cell)
    if soil.is_empty() or bool(soil["wetland"]):
        return {}
    var grass: float = nature.ground_cover_at(cell, fire)
    var shade: float = nature.canopy_pressure_at(cell)
    var water: float = _fresh_water(cell)
    var food := clampf(grass + clampf(shade / 3.0, 0.0, 0.65) * 0.18,
        0.0, 1.0)
    var shelter := clampf(shade / 2.0, 0.0, 1.0)
    return {
        "biome": climate.biome_at(cell, surface),
        "food": food, "water": water, "shelter": shelter,
        "snow": float(soil["snow"]), "temperature":
            climate.temperature_at_index(i)
    }


func _suitability(species: String, sample: Dictionary) -> float:
    # Для каждого вида применяем отдельные климатические и пищевые
    # требования. В непригодном биотопе вид отсутствует, даже если
    # соседний регион имеет много птиц или травоядных.
    var rule: Dictionary = SPECIES[species]
    if str(sample["biome"]) not in rule["biomes"]:
        return 0.0
    var food: float = float(sample["food"])
    var water: float = float(sample["water"])
    var shelter: float = float(sample["shelter"])
    if food < float(rule["food"]) or water < float(rule["water"]) \
            or shelter < float(rule["shelter"]):
        return 0.0
    var snow := clampf(1.0 - float(sample["snow"]) * 0.65, 0.0, 1.0)
    var thermal := clampf((float(sample["temperature"]) + 19.0) / 15.0,
        0.0, 1.0)
    return clampf((food * 0.60 + water * 0.25 + shelter * 0.15)
        * snow * thermal, 0.0, 1.0)


func rebuild(day: int) -> bool:
    # Фиксированная выборка внутри каждой природной области даёт
    # одинаковую карту независимо от порядка чанков и FPS.
    if day < 0 or day != climate.day:
        return false
    hydro.ensure_ready()
    surface.ensure_ready()
    climate.ensure_ready()
    var result := {}
    var dimensions: Vector2i = world.config.region_count()
    for ry in dimensions.y:
        for rx in dimensions.x:
            var region := Vector2i(rx, ry)
            var rect: Rect2i = world.config.region_rect(region)
            var aggregates := {}
            for species in SPECIES:
                aggregates[species] = {"sum": 0.0, "sites": 0,
                    "water_sites": 0, "food": 0.0}
            for sy in SAMPLE_AXIS:
                for sx in SAMPLE_AXIS:
                    var cell := Vector2i(
                        rect.position.x + clampi(roundi(
                            (float(sx) + 0.5) / SAMPLE_AXIS
                            * rect.size.x), 0, rect.size.x - 1),
                        rect.position.y + clampi(roundi(
                            (float(sy) + 0.5) / SAMPLE_AXIS
                            * rect.size.y), 0, rect.size.y - 1))
                    var sample: Dictionary = _sample(cell)
                    if sample.is_empty():
                        continue
                    for species in SPECIES:
                        var entry: Dictionary = aggregates[species]
                        var weight := _suitability(species, sample)
                        if weight <= 0.0:
                            continue
                        entry["sum"] = float(entry["sum"]) + weight
                        entry["sites"] = int(entry["sites"]) + 1
                        entry["food"] = float(entry["food"]) \
                            + float(sample["food"])
                        if float(sample["water"]) >= 0.1:
                            entry["water_sites"] = int(entry["water_sites"]) + 1
            var species_info := {}
            for species in SPECIES:
                var entry: Dictionary = aggregates[species]
                var sites: int = entry["sites"]
                var strength := float(entry["sum"]) / float(SAMPLE_AXIS * SAMPLE_AXIS)
                # Ёмкость выведена из реально пригодных участков;
                # отсутствие воды или пищи даёт ноль, а не минимум 1.
                var capacity := clampi(floori(
                    float(rect.size.x * rect.size.y) * strength
                    * float(SPECIES[species]["density"])), 0, 3000)
                species_info[species] = {
                    "capacity": capacity, "sites": sites,
                    "food": snappedf(float(entry["food"]) / maxf(1.0, float(sites)),
                        0.000001),
                    "water_sites": int(entry["water_sites"])
                }
            result["%d:%d" % [rx, ry]] = species_info
    _zones = result
    last_day = day
    revision += 1
    return true


func zone(region: Vector2i) -> Dictionary:
    # Возвращаем копию: популяции не могут подкрутить ёмкость среды.
    return (_zones.get("%d:%d" % [region.x, region.y], {}) as Dictionary).duplicate(true)


func _land_corridor(cell: Vector2i) -> bool:
    # Сухопутный переход существует только на реальной поверхности,
    # а не на карте абстрактных соседних регионов.
    if not world.config.contains_cell(cell):
        return false
    var i: int = cell.y * world.config.width + cell.x
    return not hydro.has_water(i) and not hydro.flooded_at(i) \
        and world.normal_at(cell).y >= 0.65 \
        and surface.waterlogging_at_index(i) <= 0.85


func connected_regions(from: Vector2i, to: Vector2i) -> bool:
    # Миграция разрешена только через общую сухую границу.
    # Стена гор, паводок или непрерывная река не создают телепортов.
    var difference: Vector2i = to - from
    if absi(difference.x) + absi(difference.y) != 1:
        return false
    var a: Rect2i = world.config.region_rect(from)
    var b: Rect2i = world.config.region_rect(to)
    if a.size.x <= 0 or a.size.y <= 0 or b.size.x <= 0 or b.size.y <= 0:
        return false
    if difference.x != 0:
        var y_start := maxi(a.position.y, b.position.y)
        var y_end := mini(a.end.y, b.end.y)
        var left := a.end.x - 1 if difference.x > 0 else b.end.x - 1
        for y in range(y_start, y_end):
            if _land_corridor(Vector2i(left, y)) \
                    and _land_corridor(Vector2i(left + 1, y)):
                return true
        return false
    var x_start := maxi(a.position.x, b.position.x)
    var x_end := mini(a.end.x, b.end.x)
    var top := a.end.y - 1 if difference.y > 0 else b.end.y - 1
    for x in range(x_start, x_end):
        if _land_corridor(Vector2i(x, top)) \
                and _land_corridor(Vector2i(x, top + 1)):
            return true
    return false


func to_data() -> Dictionary:
    # Среда полностью производна от физических моделей; в сохранении
    # достаточно дня и версии, сами зоны пересчитываются при загрузке.
    return {"version": 1, "day": last_day}
