extends SceneTree
## 12.8: домашний скот и питомцы появляются только из пойманных
## диких предков с учётом родословной и реальных поставок.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")
const Harvest = preload("res://scripts/wildlife_harvest.gd")
const Domestic = preload("res://scripts/wildlife_domestication.gd")
const Access = preload("res://scripts/wildlife_region_access.gd")
const Paths = preload("res://scripts/world_resource_path.gd")
const Habitats = preload("res://scripts/wildlife_habitats.gd")


func _initialize() -> void:
    # Профильный CI получает код 1 при поддельном животном,
    # недоступном источнике, ошибке родословной или потере сохранения.
    var ok := _check()
    print("STAGE12-DOMESTIC: успешно" if ok else "STAGE12-DOMESTIC: ошибка")
    quit(0 if ok else 1)


func _world() -> Dictionary:
    # Все предки генерируются один раз физическими реестрами природы.
    var world = Map.new(Config.new(256, 192, 1729))
    var water = Hydro.new(world)
    water.rebuild()
    var ground = Surface.new(world, water)
    ground.rebuild()
    var climate = Climate.new(world, water)
    climate.rebuild()
    climate.set_day(1)
    ground.advance_climate_day(climate)
    water.apply_rainfall_map(ground.runoff_map())
    var nature = Nature.new(world, water, ground, climate)
    nature.generate()
    var wildlife = Wildlife.new(world, water, ground, climate, nature)
    wildlife.generate()
    var predators = FoodWeb.new(world, climate, wildlife)
    predators.generate()
    var hunt = Harvest.new(world, water, ground, climate, wildlife)
    var farm = Domestic.new(world, water, ground, climate,
        wildlife, predators, hunt)
    var habitats = Habitats.new(world, water, ground, climate, nature)
    return {"world": world, "hydro": water, "surface": ground,
        "climate": climate, "nature": nature, "wildlife": wildlife,
        "food_web": predators, "harvest": hunt,
        "domestic": farm, "habitats": habitats}


func _choose_site(state: Dictionary) -> Vector2i:
    # Выбираем настоящее пастбище с кормом и водой, а не просто
    # незанятую клетку, чтобы проверить хотя бы травоядную линию.
    var map: RefCounted = state["world"]
    var ground: RefCounted = state["surface"]
    var water: RefCounted = state["hydro"]
    var biotopes: RefCounted = state["habitats"]
    var best := Vector2i(-1, -1)
    var best_score := -1.0
    for y in range(2, map.config.height, 4):
        for x in range(2, map.config.width, 4):
            var cell := Vector2i(x, y)
            if not Paths.walkable(map, water, ground, cell):
                continue
            var profile: Dictionary = biotopes.profile_at(cell)
            if profile.is_empty():
                continue
            var food: float = float(profile["food"])
            var drink: float = float(profile["water"])
            if food < 0.15 or drink < 0.10:
                continue
            var score := food + drink
            if score > best_score:
                best_score = score
                best = cell
    return best


func _target(state: Dictionary, kind: String) -> Dictionary:
    # Для каждой линии проверяем именно её диких предков и
    # настоящий сухопутный маршрут, а не условную запись в каталоге.
    var rule: Dictionary = Domestic.LINEAGES[kind]
    var best := {}
    var shortest := 1000000
    var sizes: Vector2i = state["world"].config.region_count()
    for y in range(sizes.y):
        for x in range(sizes.x):
            var region := Vector2i(x, y)
            var source: RefCounted = state["food_web"] \
                if rule["predator"] else state["wildlife"]
            var n: int = source.count_at(region, rule["ancestor"]) \
                if rule["predator"] else source.population_at(
                    region, rule["ancestor"])
            if n < 2:
                continue
            var route: Dictionary = Access.entry(state["world"], state["hydro"],
                state["surface"], state["domestic"].site, region)
            if route.is_empty() or int(route["steps"]) >= shortest:
                continue
            shortest = int(route["steps"])
            best = {"region": region, "steps": shortest}
    return best


func _tick(state: Dictionary) -> bool:
    # Изолированный тест отлова перемещает календарь по суткам.
    # Полная сезонная физика мира отдельно проверяется в 12.10.
    state["climate"].set_day(state["climate"].day + 1)
    var day: int = state["climate"].day
    return state["harvest"].advance_day(day) \
        and state["domestic"].advance_day(day)


func _check() -> bool:
    var state: Dictionary = _world()
    var site: Vector2i = _choose_site(state)
    if site.x < 0:
        push_error("Нет настоящего пастбища с пищей и водой")
        return false
    var farm: RefCounted = state["domestic"]
    var hunt: RefCounted = state["harvest"]
    if not farm.activate(site) or not hunt.activate(site):
        return false
    for kind in Domestic.LINEAGES:
        if farm.total(kind) != 0 or farm.total(kind, true) != 0:
            push_error("Домашние животные возникли из пустой постройки")
            return false

    var origins := {}
    for kind in Domestic.LINEAGES:
        var place: Dictionary = _target(state, kind)
        if place.is_empty():
            push_error("Не найден реальный предок: " + kind)
            return false
        var rule: Dictionary = Domestic.LINEAGES[kind]
        var source: RefCounted = state["food_web"] \
            if rule["predator"] else state["wildlife"]
        var region: Vector2i = place["region"]
        var ancestor: String = str(rule["ancestor"])
        var initial: int = source.count_at(region, ancestor) \
            if rule["predator"] else source.population_at(region, ancestor)
        if not farm.order_capture(region, kind, 2):
            push_error("Нельзя начать отлов: " + kind)
            return false
        if farm.total(kind) != 0:
            push_error("Предки появились до приезда отловщика")
            return false
        var taken := 0
        var finished := false
        for step in range(140):
            var before: int = source.count_at(region, ancestor) \
                if rule["predator"] else source.population_at(region, ancestor)
            if not _tick(state):
                return false
            var after: int = source.count_at(region, ancestor) \
                if rule["predator"] else source.population_at(region, ancestor)
            taken += before - after
            if farm.summary()["pending"].is_empty():
                finished = true
                break
        var record: Dictionary = farm.summary()["herds"].get(kind, {})
        var final_count: int = source.count_at(region, ancestor) \
            if rule["predator"] else source.population_at(region, ancestor)
        if not finished or taken != 2 or initial - final_count != 2 \
                or record.is_empty() or int(record["founders"]) != 2 \
                or record["ancestors"] != [ancestor]:
            push_error("Не сохранён исходный предок: " + kind)
            return false
        origins[kind] = {"region": [region.x, region.y],
            "ancestor": ancestor, "captured": taken}

    # Сохранение должно содержать происхождение всех пяти линий.
    # Поддельная домашняя собака из оленя не может пройти импорт.
    var saved: Dictionary = farm.to_data()
    var clone = Domestic.new(state["world"], state["hydro"],
        state["surface"], state["climate"],
        state["wildlife"], state["food_web"], hunt)
    if not clone.load_data(saved) or clone.to_data() != saved:
        push_error("Происхождение исчезло при загрузке")
        return false
    var invalid: Dictionary = saved.duplicate(true)
    invalid["herds"]["собака"]["ancestors"] = ["олень"]
    if clone.load_data(invalid) or clone.to_data() != saved:
        push_error("Допущена подмена волка оленем в родословной")
        return false
    invalid = saved.duplicate(true)
    invalid["herds"]["корова"]["domestic"] = 100
    if clone.load_data(invalid) or clone.to_data() != saved:
        push_error("В сохранении возник бесплатный скот")
        return false
    if not hunt.summary()["products"].is_empty() \
            or farm.total("собака", true) > 0 \
            or farm.total("кошка", true) > 0:
        push_error("Хищник одомашнен без кормового мяса")
        return false

    # Дальнейшие поколения коров возникают из реальных родителей,
    # но их нельзя получить мгновенно от простой постройки участка.
    var generations_before: int = int(saved["herds"]["корова"]["generations"])
    for i in range(120):
        if not _tick(state):
            return false
    var cattle: Dictionary = farm.summary()["herds"]["корова"]
    if int(cattle["generations"]) <= generations_before \
            or farm.total("корова", true) <= 0 \
            or farm.total("собака", true) > 0:
        push_error("Нет домашних потомков после поколений и корма")
        return false
    print("STAGE12-DOMESTIC-REPORT: ", JSON.stringify({
        "day": farm.last_day, "site": [site.x, site.y],
        "origins": origins, "cattle": cattle,
        "dogs": farm.summary()["herds"]["собака"]
    }))
    return true
