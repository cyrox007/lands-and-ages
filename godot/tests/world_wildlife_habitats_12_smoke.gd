extends SceneTree
## Приёмка биотопов на живом мире: источник воды не возникает
## в модели фауны, а хищники не получают фиктивную добычу.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Habitats = preload("res://scripts/wildlife_habitats.gd")


func _initialize() -> void:
    # Сигнатура и ненулевой код возврата обязательны для CI.
    var passed := _check()
    print("STAGE12-HABITATS: успешно" if passed else "STAGE12-HABITATS: ошибка")
    quit(0 if passed else 1)


func _check() -> bool:
    # Повторная генерация на том же seed обязана дать те же
    # региональные отчёты без отдельного источника случайности.
    var biome_kinds := {}
    var food_regions := 0
    var dry_regions := 0
    for seed in [1729, 1802]:
        var world = Map.new(Config.new(256, 192, seed))
        var hydro = Hydro.new(world)
        hydro.rebuild()
        var climate = Climate.new(world, hydro)
        climate.rebuild()
        var surface = Surface.new(world, hydro)
        surface.rebuild()
        var nature = Nature.new(world, hydro, surface, climate)
        nature.generate()
        var habitat = Habitats.new(world, hydro, surface, climate, nature)
        if not habitat.profile_at(Vector2i(-1, -1)).is_empty() \
                or habitat.suitability(Vector2i(-1, -1), "олень") != 0.0 \
                or habitat.suitability(Vector2i(0, 0), "несуществующий вид") != 0.0:
            push_error("Некорректная клетка или вид допускаются к заселению")
            return false
        var regions: Vector2i = world.config.region_count()
        var signature := []
        for y in range(regions.y):
            for x in range(regions.x):
                var report: Dictionary = habitat.region_report(Vector2i(x, y))
                if report.is_empty():
                    return false
                signature.append(report)
                if float(report["mean_food"]) > 0.10:
                    food_regions += 1
                if float(report["mean_water"]) < 0.05:
                    dry_regions += 1
                for kind in report["biomes"]:
                    biome_kinds[kind] = true
        var repeat := []
        for y in range(regions.y):
            for x in range(regions.x):
                repeat.append(habitat.region_report(Vector2i(x, y)))
        if signature != repeat:
            push_error("Отчёты биотопов меняются без изменения природы")
            return false
        # Проверяем на уровне отдельных клеток: открытая вода
        # не может стать наземным биотопом даже в пойменной области.
        for y in range(0, world.config.height, 13):
            for x in range(0, world.config.width, 13):
                var cell := Vector2i(x, y)
                var index: int = hydro.cell_index(cell)
                var profile: Dictionary = habitat.profile_at(cell)
                if (hydro.has_water(index) or hydro.flooded_at(index)) \
                        and not profile.is_empty():
                    push_error("Наземный биотоп оказался в воде")
                    return false
                if profile.is_empty():
                    continue
                if float(profile["food"]) < 0.0 \
                        or float(profile["food"]) > 1.0 \
                        or float(profile["water"]) < 0.0 \
                        or float(profile["water"]) > 1.0:
                    push_error("Неверный диапазон природных ресурсов")
                    return false
                if habitat.suitability(cell, "волк") != 0.0:
                    push_error("Хищник получил вымышленную добычу")
                    return false
        print("STAGE12-HABITAT-SEED: ", JSON.stringify({
            "seed": seed, "regions": signature.size(),
            "biomes": biome_kinds.keys()
        }))
    if biome_kinds.size() < 3 or food_regions < 2:
        push_error("Природные биотопы не имеют достаточного разнообразия")
        return false
    print("STAGE12-HABITAT-SUMMARY: ", JSON.stringify({
        "biomes": biome_kinds.keys(), "food_regions": food_regions,
        "dry_regions": dry_regions
    }))
    return true
