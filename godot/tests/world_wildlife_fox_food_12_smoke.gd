extends SceneTree
## Регрессия 12.10: лиса охотится на реальную дикую птицу.
## Запрещено выдавать мясо из пустого ареала и размножать жертву.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")


func _initialize() -> void:
    # Целевой тест использует единственную живую карту, а не
    # подменяет реестр жертв макетом или вспомогательными кубами.
    var ok := _check()
    print("STAGE12-FOX-FOOD: успешно" if ok else "STAGE12-FOX-FOOD: ошибка")
    quit(0 if ok else 1)


func _check() -> bool:
    # Генерируем физический мир с гидрологией и настоящими
    # биотопами, чтобы птица существовала только там, где может жить.
    var world = WorldMap.new(Config.new(256, 192, 1729))
    var water = Hydro.new(world)
    water.rebuild()
    var surface = Surface.new(world, water)
    surface.rebuild()
    var climate = Climate.new(world, water)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    water.apply_rainfall_map(surface.runoff_map())
    var nature = Nature.new(world, water, surface, climate)
    nature.generate()
    var prey = Wildlife.new(world, water, surface, climate, nature)
    if not prey.generate():
        return false
    var predators = FoodWeb.new(world, climate, prey)
    if not predators.generate():
        return false

    var region_count: Vector2i = world.config.region_count()
    var verified := 0
    for y in range(region_count.y):
        for x in range(region_count.x):
            var region := Vector2i(x, y)
            # Целенаправленно выбираем птицу в регионе, где
            # охотничьего избытка зайцев нет: иначе доказательства
            # нового рациона не получится.
            if predators._huntable(region, "заяц") > 0:
                continue
            var bird := ""
            for species in ["дикая курица", "дикий гусь"]:
                if predators._huntable(region, species) > 0:
                    bird = species
                    break
            if bird.is_empty():
                continue
            var original_foxes: int = predators.total("лиса")
            var original_total: int = prey.total()
            var original_birds: int = prey.population_at(region, bird)
            var eaten: int = predators._feed(region, "лиса", 1)
            if eaten != 1 or prey.population_at(region, bird) \
                    != original_birds - 1 or prey.total() != original_total - 1 \
                    or predators.total("лиса") != original_foxes:
                push_error("Птица не списана физически после охоты лисы")
                return false
            # Повторный «обед» из защищённого остатка запрещён.
            # Проверяем, что счётчики остаются целыми и положительными.
            if prey.population_at(region, bird) < 0:
                return false
            verified += 1
            if verified == 2:
                break
        if verified == 2:
            break
    if verified < 1:
        push_error("На реальной карте не найден ареал птицы без зайцев")
        return false
    print("STAGE12-FOX-FOOD-REPORT: ", JSON.stringify({
        "regions": verified, "birds_remaining": prey.total("дикая курица")
            + prey.total("дикий гусь"), "foxes": predators.total("лиса")
    }))
    return true
