extends SceneTree
## 12.7: охота отнимает живого зверя, перевозка доставляет настоящую
## тушу, разделка создаёт материалы, употребление пищи их расходует.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const Harvest = preload("res://scripts/wildlife_harvest.gd")
const Access = preload("res://scripts/wildlife_region_access.gd")
const Paths = preload("res://scripts/world_resource_path.gd")


func _initialize() -> void:
    # Отдельный код возврата делает проверку обязательной для CI.
    var success := _test()
    print("STAGE12-HARVEST: успешно" if success else "STAGE12-HARVEST: ошибка")
    quit(0 if success else 1)


func _world() -> Dictionary:
    # Настоящая природная карта и единственные реестры живых животных.
    var world = Map.new(Config.new(256, 192, 1729))
    var hydro = Hydro.new(world)
    hydro.rebuild()
    var surface = Surface.new(world, hydro)
    surface.rebuild()
    var climate = Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature = Nature.new(world, hydro, surface, climate)
    nature.generate()
    var fauna = Wildlife.new(world, hydro, surface, climate, nature)
    fauna.generate()
    var predators = FoodWeb.new(world, climate, fauna)
    predators.generate()
    var harvest = Harvest.new(world, hydro, surface, climate, fauna)
    var weather = Weather.new(world, climate, surface, hydro)
    var natural = Natural.new(world, hydro, surface, climate)
    var disasters = Disasters.new(world, hydro, surface, climate)
    var fire = Fire.new(world, hydro, surface, climate, nature)
    var runner = Runner.new(world, hydro, surface, climate,
        weather, natural, disasters, nature, fire)
    return {"world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "wildlife": fauna,
        "food_web": predators, "harvest": harvest, "weather": weather,
        "natural": natural, "disasters": disasters, "fire": fire,
        "runner": runner}


func _day(state: Dictionary) -> bool:
    # Порядок совпадает с игровой сценой: после полного климата
    # сначала живут популяции и хищники, затем работают охотники.
    state["runner"].run_day()
    var day: int = state["climate"].day
    var fauna: RefCounted = state["wildlife"]
    var pred: RefCounted = state["food_web"]
    if not fauna.advance_day(day) or not pred.advance_day(
            day, state["runner"].last_result["hazards"]):
        return false
    return state["harvest"].advance_day(day)


func _site(state: Dictionary, species: String) -> Dictionary:
    # Проверяем, что ареал содержит живых животных и к нему
    # действительно можно попасть с пригодной наземной клетки.
    var world: RefCounted = state["world"]
    var hydro: RefCounted = state["hydro"]
    var surface: RefCounted = state["surface"]
    var fauna: RefCounted = state["wildlife"]
    var regions: Vector2i = world.config.region_count()
    for y in range(regions.y):
        for x in range(regions.x):
            var region := Vector2i(x, y)
            if fauna.population_at(region, species) < 2:
                continue
            var bounds: Rect2i = world.config.region_rect(region)
            for sy in range(bounds.position.y, bounds.end.y, 4):
                for sx in range(bounds.position.x, bounds.end.x, 4):
                    var cell := Vector2i(sx, sy)
                    if not Paths.walkable(world, hydro, surface, cell):
                        continue
                    var route: Dictionary = Access.entry(
                        world, hydro, surface, cell, region)
                    if not route.is_empty():
                        return {"region": region, "site": cell}
    return {}


func _test() -> bool:
    var state := _world()
    var place: Dictionary = _site(state, "олень")
    if place.is_empty():
        push_error("Нет пригодного ареала реального оленя")
        return false
    var hunt: RefCounted = state["harvest"]
    if not hunt.activate(place["site"]):
        return false
    var region: Vector2i = place["region"]
    var wildlife: RefCounted = state["wildlife"]
    if hunt.butcher("олень", 1) or hunt.consume_food(1):
        push_error("Пища возникла без добытого зверя")
        return false
    if not hunt.order_hunt(region, "олень", 1):
        return false
    if wildlife.population_at(region, "олень") < 1 \
            or not hunt.summary()["carcasses"].is_empty():
        push_error("Добыча произошло до прихода охотника")
        return false
    var killed := 0
    var completed := false
    for i in range(50):
        state["runner"].run_day()
        var day: int = state["climate"].day
        wildlife.advance_day(day)
        state["food_web"].advance_day(day,
            state["runner"].last_result["hazards"])
        var before: int = wildlife.population_at(region, "олень")
        hunt.advance_day(day)
        var after: int = wildlife.population_at(region, "олень")
        if after < before:
            killed += before - after
        if hunt.summary()["order"].is_empty():
            completed = true
            break
    if not completed or killed != 1 \
            or int(hunt.summary()["carcasses"].get("олень", 0)) != 1:
        push_error("Охотничья партия не прибыла из существующего стада")
        return false
    if not hunt.butcher("олень", 1) or hunt.butcher("олень", 1):
        push_error("Одну и ту же тушу разделали дважды")
        return false
    var products: Dictionary = hunt.summary()["products"]
    if products != Harvest.YIELDS["олень"]:
        push_error("Материалы не соответствуют реальной туше")
        return false
    if not hunt.consume_food(2):
        return false
    if int(hunt.summary()["products"]["мясо"]) != 4 \
            or int(hunt.summary()["consumed_meat"]) != 2:
        push_error("Пища не списалась со склада при употреблении")
        return false
    var snapshot: Dictionary = Save.capture(state)
    if snapshot.is_empty() or not snapshot.has("harvest"):
        push_error("WorldSave не содержит последствия охоты")
        return false
    var loaded: Dictionary = Save.restore(snapshot)
    if loaded.is_empty() \
            or loaded["harvest"].to_data() != hunt.to_data() \
            or loaded["wildlife"].to_data() != wildlife.to_data():
        push_error("WorldSave продублировал добычу или туши")
        return false
    var bad: Dictionary = snapshot.duplicate(true)
    bad["harvest"]["products"]["мясо"] = Harvest.MAX_STOCK + 1
    if not Save.restore(bad).is_empty():
        push_error("WorldSave принял поддельные товары")
        return false
    var without: Dictionary = snapshot.duplicate(true)
    without.erase("harvest")
    var old: Dictionary = Save.restore(without)
    if old.is_empty() or old["harvest"].site.x >= 0:
        push_error("Старое сохранение создаёт бесплатную охоту")
        return false
    print("STAGE12-HARVEST-REPORT: ", JSON.stringify({
        "day": hunt.last_day, "killed": killed,
        "products": hunt.summary()["products"],
        "consumed_meat": hunt.eaten_meat
    }))
    return true
