extends SceneTree
## Проверка геологических провинций на разных seed и настоящей карте.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")
const Generation = preload("res://scripts/natural_resource_generation.gd")
const Geology = preload("res://scripts/natural_mineral_geology.gd")

const SEEDS := [1729, 1802, 1875, 1948]


func _initialize() -> void:
    # Ошибки порождают ненулевой код для самостоятельной CI-приёмки.
    var result := _check()
    print("STAGE12-GEOLOGY: успешно" if result else "STAGE12-GEOLOGY: ошибка")
    quit(0 if result else 1)


func _check() -> bool:
    # Каждая карта независима, а её геология — функция только seed,
    # рельефа и грунтов; ни день, ни камера не добавляют месторождений.
    var counts := {}
    var total_mineral_sources := 0
    for seed in SEEDS:
        var world = Map.new(Config.new(256, 192, seed))
        var hydro = Hydro.new(world)
        hydro.rebuild()
        var ground = Surface.new(world, hydro)
        ground.rebuild()
        var first = Resources.new(world)
        var second = Resources.new(world)
        var report: Dictionary = Generation.populate(
            world, hydro, ground, first)
        var replay: Dictionary = Generation.populate(
            world, hydro, ground, second)
        if report != replay or first.to_data() != second.to_data():
            push_error("Одинаковый seed даёт разные залежи")
            return false
        var regional := {}
        var positions: Array[Vector2i] = []
        for source in first.to_data()["sources"]:
            var kind: String = source["kind"]
            if kind not in ["железная руда", "медная руда",
                    "оловянная руда", "каменный уголь"]:
                continue
            var cell := Vector2i(int(source["x"]), int(source["y"]))
            var index: int = cell.y * world.config.width + cell.x
            if hydro.has_water(index) or bool(ground.profile_at(cell)["wetland"]):
                push_error("Минерал расположен в воде или болоте")
                return false
            for previous in positions:
                if cell.distance_squared_to(previous) < Generation.MIN_DISTANCE_SQUARED:
                    push_error("Минералы накладываются друг на друга")
                    return false
            positions.append(cell)
            var region: Vector2i = world.config.region_of(cell)
            var key := "%s:%d:%d" % [kind, region.x, region.y]
            if regional.has(key):
                push_error("В одном регионе дублирована редкая руда")
                return false
            regional[key] = true
            var found := false
            for rule in Generation.MINERALS:
                if rule["kind"] != kind:
                    continue
                var survey: Dictionary = Geology.prospect(
                    world, ground, cell, rule)
                if survey.is_empty() \
                        or int(survey["quality"]) != int(source["quality"]) \
                        or int(survey["units"]) != int(source["initial_units"]):
                    push_error("Месторождение не соответствует глубинной геологии")
                    return false
                found = true
            if not found:
                return false
            counts[kind] = int(counts.get(kind, 0)) + 1
            total_mineral_sources += 1
        print("STAGE12-GEO-SEED: ", JSON.stringify({
            "seed": seed, "deposits": report["sources"],
            "mineral_regions": report["mineral_regions"]
        }))
    # При нескольких seed должны существовать реальные природные залежи;
    # точные количества не зашиваем в генератор или экономический баланс.
    if total_mineral_sources < 3 or counts.size() < 2:
        push_error("Геологические области потеряли разнообразие видов")
        return false
    print("STAGE12-GEO-SUMMARY: ", JSON.stringify(counts))
    return true
