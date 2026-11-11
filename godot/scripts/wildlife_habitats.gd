extends RefCounted
## Биотопы дикой фауны: пища, питьевая вода и укрытия берутся
## из уже существующей гидрологии, почв, климата и растительности.
## Ни животных, ни еды, ни воды этот слой не создаёт.

const Terrain = preload("res://scripts/terrain.gd")
const SPECIES := {
    "олень": {"food": "растительная", "water": 0.25,
        "cover": 0.25, "biomes": ["лес", "опушка", "луг", "пойма"]},
    "заяц": {"food": "растительная", "water": 0.12,
        "cover": 0.20, "biomes": ["опушка", "луг", "лес", "степь"]},
    "кабан": {"food": "растительная", "water": 0.35,
        "cover": 0.35, "biomes": ["лес", "пойма", "болото", "опушка"]},
    # Исторические дикие предки домашних видов, не создаваемые зданиями.
    "тур": {"food": "растительная", "water": 0.20,
        "cover": 0.10, "biomes": ["луг", "опушка", "пойма", "лес"]},
    "дикая курица": {"food": "растительная", "water": 0.08,
        "cover": 0.08, "biomes": ["лес", "опушка", "луг", "степь"]},
    "дикий гусь": {"food": "растительная", "water": 0.20,
        "cover": 0.05, "biomes": ["пойма", "луг", "болото", "опушка"]},
    "волк": {"food": "добыча", "water": 0.22,
        "cover": 0.18, "biomes": ["лес", "опушка", "степь", "луг"]},
    "лиса": {"food": "добыча", "water": 0.12,
        "cover": 0.18, "biomes": ["лес", "опушка", "луг", "степь"]},
    "дикая кошка": {"food": "добыча", "water": 0.12,
        "cover": 0.15, "biomes": ["лес", "опушка", "луг", "степь"]}
}
const SAMPLE_STEP := 4

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var nature: RefCounted


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        weather: RefCounted, vegetation: RefCounted) -> void:
    # Используем те же объекты, что природный симулятор и WorldSave.
    # Снимок биотопа не дублирует их состояние.
    world = map
    hydro = water
    surface = ground
    climate = weather
    nature = vegetation


func _water(cell: Vector2i, radius: int = 5) -> float:
    # Доступность питьевой воды определяется только настоящими
    # водными клетками. Близость к озеру не превращает сушу в воду.
    var best := 0.0
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            var neighbor := cell + Vector2i(dx, dy)
            if not world.config.contains_cell(neighbor):
                continue
            var index: int = hydro.cell_index(neighbor)
            if not hydro.has_water(index):
                continue
            var distance := sqrt(float(dx * dx + dy * dy))
            best = maxf(best, clampf(
                1.0 - distance / float(radius + 1), 0.0, 1.0))
    return best


func profile_at(cell: Vector2i) -> Dictionary:
    # Нельзя селить наземную фауну в открытой воде, под водой
    # во время паводка или на слишком крутом склоне.
    if not world.config.contains_cell(cell):
        return {}
    var index: int = hydro.cell_index(cell)
    if hydro.has_water(index) or hydro.flooded_at(index):
        return {}
    var slope: float = 1.0 - float(world.normal_at(cell).y)
    if slope > 0.43:
        return {}
    var ground: Dictionary = surface.profile_at(cell)
    if ground.is_empty():
        return {}
    var temperature: float = climate.temperature_at_index(index)
    var moisture: float = float(ground.get("moisture", 0.0))
    var fertility: float = float(ground.get("fertility", 0.0))
    var snow: float = float(ground.get("snow", 0.0))
    var grass: float = nature.ground_cover_at(cell)
    var canopy: float = nature.canopy_pressure_at(cell)
    var cover := clampf(canopy / 2.0 + grass * 0.35, 0.0, 1.0)
    var food := clampf(grass * 0.70 + fertility * 0.20
        + minf(canopy, 1.0) * 0.10, 0.0, 1.0)
    # Снег и мороз понижают доступность корма, но не удаляют
    # почву или растительность из исходных природных моделей.
    food *= clampf(1.0 - snow * 0.78, 0.0, 1.0)
    var water := _water(cell)
    var wetland: bool = bool(ground.get("wetland", false))
    var biome := "луг"
    if wetland:
        biome = "болото"
    elif water > 0.60 and moisture > 0.52:
        biome = "пойма"
    elif canopy >= 0.72:
        biome = "лес"
    elif canopy >= 0.23:
        biome = "опушка"
    elif moisture < 0.27:
        biome = "степь"
    if temperature < -8.0 or snow > 0.85:
        biome = "тундра"
    if ground.get("substrate") == "скала" and grass < 0.15:
        biome = "скалы"
    return {
        "biome": biome, "food": snappedf(food, 0.000001),
        "water": snappedf(water, 0.000001),
        "cover": snappedf(cover, 0.000001),
        "temperature": snappedf(temperature, 0.000001),
        "snow": snappedf(snow, 0.000001),
        "moisture": snappedf(moisture, 0.000001),
        "slope": snappedf(slope, 0.000001)
    }


func suitability(cell: Vector2i, species: String) -> float:
    # Вид не появляется автоматически. Возвращаем пригодность
    # для будущей миграции и размножения реальной популяции.
    var rule: Dictionary = SPECIES.get(species, {})
    var habitat: Dictionary = profile_at(cell)
    if rule.is_empty() or habitat.is_empty() \
            or habitat["biome"] not in rule["biomes"]:
        return 0.0
    if float(habitat["water"]) < float(rule["water"]) \
            or float(habitat["cover"]) < float(rule["cover"]):
        return 0.0
    var food: float = float(habitat["food"])
    if rule["food"] == "добыча":
        # Хищникам не выдаём мясо из травы. Пока нет реестра
        # добычи (12.5–12.6), пригодность для них не доказана.
        return 0.0
    return snappedf(clampf(food * 0.72
        + float(habitat["cover"]) * 0.16
        + float(habitat["water"]) * 0.12, 0.0, 1.0), 0.000001)


func region_report(region: Vector2i) -> Dictionary:
    # Регионы считаются по стабильной мировой сетке, не по камере.
    # Шаг выборки ограничивает затраты на поиск водных соседей.
    var rect: Rect2i = world.config.region_rect(region)
    if not rect.has_area():
        return {}
    var biomes := {}
    var suitable := {}
    var samples := 0
    var food_sum := 0.0
    var water_sum := 0.0
    for y in range(rect.position.y, rect.end.y, SAMPLE_STEP):
        for x in range(rect.position.x, rect.end.x, SAMPLE_STEP):
            var cell := Vector2i(x, y)
            var habitat: Dictionary = profile_at(cell)
            if habitat.is_empty():
                continue
            samples += 1
            var kind: String = habitat["biome"]
            biomes[kind] = int(biomes.get(kind, 0)) + 1
            food_sum += float(habitat["food"])
            water_sum += float(habitat["water"])
            for species in SPECIES:
                if suitability(cell, species) > 0.20:
                    suitable[species] = int(suitable.get(species, 0)) + 1
    return {
        "region": [region.x, region.y], "samples": samples,
        "biomes": biomes, "suitable": suitable,
        "mean_food": snappedf(food_sum / float(maxi(1, samples)), 0.000001),
        "mean_water": snappedf(water_sum / float(maxi(1, samples)), 0.000001)
    }
