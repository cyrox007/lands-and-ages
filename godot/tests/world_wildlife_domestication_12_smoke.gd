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


func _choose_site(state: Dictionary, kind: String) -> Vector2i:
    # Хозяйство выбираем рядом с реальными предками данного вида.
    # Нельзя требовать собрать всю фауну на одном изолированном
    # острове: у каждого поселения собственная доступная география.
    var map: RefCounted = state["world"]
    var ground: RefCounted = state["surface"]
    var water: RefCounted = state["hydro"]
    var biotopes: RefCounted = state["habitats"]
    var rule: Dictionary = Domestic.LINEAGES[kind]
    var source: RefCounted = state["food_web"] \
        if rule["predator"] else state["wildlife"]
    var ancestor: String = str(rule["ancestor"])
    var regions: Vector2i = map.config.region_count()
    for ry in range(regions.y):
        for rx in range(regions.x):
            var region := Vector2i(rx, ry)
            var count: int = source.count_at(region, ancestor) \
                if rule["predator"] else source.population_at(region, ancestor)
            if count < 1:
                continue
            var bounds: Rect2i = map.config.region_rect(region)
            for y in range(bounds.position.y, bounds.end.y, 4):
                for x in range(bounds.position.x, bounds.end.x, 4):
                    var cell := Vector2i(x, y)
                    if not Paths.walkable(map, water, ground, cell):
                        continue
                    if not bool(rule["predator"]):
                        var habitat: Dictionary = biotopes.profile_at(cell)
                        if habitat.is_empty() or float(habitat["food"]) < 0.15 \
                                or float(habitat["water"]) < 0.10:
                            continue
                    var available := 0
                    for sy in range(regions.y):
                        for sx in range(regions.x):
                            var other := Vector2i(sx, sy)
                            var living: int = source.count_at(other, ancestor) \
                                if rule["predator"] else source.population_at(
                                    other, ancestor)
                            if living < 1:
                                continue
                            var route: Dictionary = Access.entry(map, water,
                                ground, cell, other)
                            if not route.is_empty():
                                available += living
                    # Для племенного стада требуются двое живых
                    # основателей, потенциально из двух разных стай.
                    if available >= 2:
                        return cell
    return Vector2i(-1, -1)

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
            if n < 1:
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
    var origins := {}
    var cattle_born := false
    for kind in Domestic.LINEAGES:
        var site: Vector2i = _choose_site(state, kind)
        if site.x < 0:
            push_error("Нет достижимой пары предков: " + kind)
            return false
        # Каждый вид проверяем на физически доступном пастбище
        # или участке отлова, используя ОДНИ И ТЕ ЖЕ дикие
        # популяции без повторного вызова generate().
        var farm = Domestic.new(state["world"], state["hydro"],
            state["surface"], state["climate"], state["wildlife"],
            state["food_web"], state["harvest"])
        var hunt = Harvest.new(state["world"], state["hydro"],
            state["surface"], state["climate"], state["wildlife"])
        state["domestic"] = farm
        state["harvest"] = hunt
        farm.harvest = hunt
        if not farm.activate(site) or not hunt.activate(site):
            return false
        if farm.total(kind) != 0 or farm.total(kind, true) != 0:
            push_error("Пустое хозяйство породило домашнее животное")
            return false
        var rule: Dictionary = Domestic.LINEAGES[kind]
        var source: RefCounted = state["food_web"] \
            if rule["predator"] else state["wildlife"]
        var ancestor: String = str(rule["ancestor"])
        var total_taken := 0
        var capture_sources: Array = []
        for expedition in range(4):
            if total_taken >= 2:
                break
            var place: Dictionary = _target(state, kind)
            if place.is_empty():
                break
            var region: Vector2i = place["region"]
            var initial: int = source.count_at(region, ancestor) \
                if rule["predator"] else source.population_at(region, ancestor)
            var amount := mini(2 - total_taken, initial)
            if not farm.order_capture(region, kind, amount):
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
            if not finished or taken != amount:
                push_error("Живой предок не списан: " + kind)
                return false
            total_taken += taken
            capture_sources.append([region.x, region.y, taken])
        var record: Dictionary = farm.summary()["herds"].get(kind, {})
        if total_taken != 2 or record.is_empty() \
                or int(record["founders"]) != 2 \
                or record["ancestors"] != [ancestor] \
                or record["origin"] != capture_sources:
            push_error("Неверное происхождение %s; поймано %d" % [
                kind, total_taken])
            return false
        origins[kind] = {"sources": capture_sources,
            "ancestor": ancestor, "captured": total_taken}

        # Свой снимок каждой линии нельзя заменить чужим видом
        # или раздуть домашнее поголовье вручную.
        var data: Dictionary = farm.to_data()
        var clone = Domestic.new(state["world"], state["hydro"],
            state["surface"], state["climate"],
            state["wildlife"], state["food_web"], hunt)
        if not clone.load_data(data) or clone.to_data() != data:
            push_error("Родословная изменилась при загрузке: " + kind)
            return false
        var invalid: Dictionary = data.duplicate(true)
        invalid["herds"][kind]["ancestors"] = ["олень"]
        if clone.load_data(invalid) or clone.to_data() != data:
            push_error("Предок подменён при загрузке: " + kind)
            return false
        invalid = data.duplicate(true)
        invalid["herds"][kind]["domestic"] = 100
        if clone.load_data(invalid) or clone.to_data() != data:
            push_error("Домашняя особь появилась без поколений")
            return false

        if bool(rule["predator"]):
            # Для собак и кошек без настоящего мяса не разрешается
            # размножение, даже если волки и дикие кошки пойманы.
            for day in range(100):
                if not _tick(state):
                    return false
            if farm.total(kind, true) > 0:
                push_error("Хищная домашняя линия размножилась без мяса")
                return false
        elif kind == "корова":
            # Несколько поколений из исходных туров должны привести
            # к домашним потомкам, но не мгновенно после отлова.
            for day in range(120):
                if not _tick(state):
                    return false
            if farm.total(kind, true) <= 0:
                push_error("Туры не дали потомства на пригодном пастбище")
                return false
            cattle_born = true

    if not cattle_born or origins.size() != Domestic.LINEAGES.size():
        return false
    print("STAGE12-DOMESTIC-REPORT: ", JSON.stringify({
        "day": state["climate"].day,
        "origins": origins, "cow_offspring": cattle_born
    }))
    return true
