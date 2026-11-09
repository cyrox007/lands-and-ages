extends RefCounted
## 12.7: охота приводит к реальной туше и учтённым материалам.
## Мясо и шкуры не возникают без вычитания живого животного.

const Paths = preload("res://scripts/world_resource_path.gd")
const Access = preload("res://scripts/wildlife_region_access.gd")
const FORMAT_VERSION := 1
const STEPS_PER_DAY := 8
const MAX_BATCH := 8
const MAX_STOCK := 100000
const YIELDS := {
    "олень": {"мясо": 6, "шкура": 2, "кости": 2},
    "заяц": {"мясо": 2, "шкура": 1, "кости": 1},
    "кабан": {"мясо": 8, "шкура": 2, "кости": 3},
    "тур": {"мясо": 12, "шкура": 3, "кости": 4},
    "дикая курица": {"мясо": 2, "перо": 2, "кости": 1},
    "дикий гусь": {"мясо": 3, "перо": 3, "кости": 1}
}

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var wildlife: RefCounted
var site := Vector2i(-1, -1)
var last_day := 0
var _carcasses: Dictionary = {}
var _products: Dictionary = {}
var _order: Dictionary = {}
var eaten_meat := 0
var last_event := "Охотничий участок не организован"


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        weather: RefCounted, animals: RefCounted) -> void:
    # Используем те же живые региональные стада, что экологическая
    # симуляция и хищники. Вторых копий животных нет.
    world = map
    hydro = water
    surface = ground
    climate = weather
    wildlife = animals
    last_day = weather.day


func activate(cell: Vector2i) -> bool:
    # Строительная площадка или лагерь не могут находиться на воде.
    # Создание участка не даёт ни мяса, ни бесплатных охотников.
    if site.x >= 0 or not Paths.walkable(world, hydro, surface, cell):
        return false
    site = cell
    last_event = "Участок готов к физическим охотничьим вылазкам"
    return true


func order_hunt(region: Vector2i, species: String, amount: int) -> bool:
    # Выбираем существующих животных и проверяем доступность ареала.
    # До фактического прихода охотника стадо остаётся неизменным.
    if site.x < 0 or not _order.is_empty() \
            or not YIELDS.has(species) or amount < 1 \
            or amount > MAX_BATCH or not wildlife.generated \
            or wildlife.population_at(region, species) < amount:
        return false
    var route: Dictionary = Access.entry(world, hydro, surface, site, region)
    if route.is_empty():
        last_event = "До выбранного ареала нет сухопутного прохода"
        return false
    var target: Vector2i = route["cell"]
    _order = {
        "species": species, "amount": amount,
        "region": [region.x, region.y],
        "target": [target.x, target.y], "position": [site.x, site.y],
        "phase": "туда", "killed": false
    }
    last_event = "Охота началась: " + species
    return true


func advance_day(day: int) -> bool:
    # Отсутствие пропущенных суток обязательно для физического мира.
    # Навигация проверяется снова на каждом дне при паводках.
    if day != last_day + 1 or day != climate.day:
        return false
    last_day = day
    if _order.is_empty():
        return true
    var point: Array = _order["position"]
    var current := Vector2i(int(point[0]), int(point[1]))
    var destination := site
    if _order["phase"] == "туда":
        var pair: Array = _order["target"]
        destination = Vector2i(int(pair[0]), int(pair[1]))
    if current != destination:
        var path: Array[Vector2i] = Paths.find(
            world, hydro, surface, current, destination)
        if path.is_empty():
            last_event = "Охота задержана: сухопутный путь перекрыт"
            return true
        var steps := mini(STEPS_PER_DAY, path.size())
        current = path[steps - 1]
        _order["position"] = [current.x, current.y]
        if current != destination:
            return true
    if _order["phase"] == "туда":
        var region: Array = _order["region"]
        var area := Vector2i(int(region[0]), int(region[1]))
        var kind: String = _order["species"]
        var amount: int = _order["amount"]
        if not wildlife.consume_prey(area, kind, amount):
            last_event = "Животные покинули ареал до прихода охотников"
            _order.clear()
            return true
        # Туши ещё находятся в пути: на складе они появятся
        # только после возврата, не при регистрации добычи.
        _order["phase"] = "обратно"
        _order["killed"] = true
        last_event = "Добыча подтверждена; охотники возвращаются"
        return true
    var kind: String = _order["species"]
    var amount: int = _order["amount"]
    _carcasses[kind] = int(_carcasses.get(kind, 0)) + amount
    _order.clear()
    last_event = "Получены настоящие туши: " + kind
    return true


func butcher(species: String, amount: int) -> bool:
    # Разделка атомарна: один и тот же зверь даёт продукты
    # ровно один раз, и после списания туша больше недоступна.
    if site.x < 0 or not YIELDS.has(species) \
            or amount < 1 or amount > MAX_BATCH \
            or int(_carcasses.get(species, 0)) < amount:
        return false
    var recipe: Dictionary = YIELDS[species]
    for material in recipe:
        var new_amount := int(_products.get(material, 0)) \
            + int(recipe[material]) * amount
        if new_amount > MAX_STOCK:
            return false
    _carcasses[species] = int(_carcasses[species]) - amount
    if _carcasses[species] == 0:
        _carcasses.erase(species)
    for material in yield:
        _products[material] = int(_products.get(material, 0)) \
            + int(yield[material]) * amount
    last_event = "Разделано туш: %d (%s)" % [amount, species]
    return true


func consume_food(amount: int) -> bool:
    # Пища исчезает со склада при использовании. Это реальный
    # расход продукта, а не бесплатное насыщение населения.
    if amount < 1 or int(_products.get("мясо", 0)) < amount:
        return false
    _products["мясо"] = int(_products["мясо"]) - amount
    if _products["мясо"] == 0:
        _products.erase("мясо")
    eaten_meat += amount
    last_event = "Израсходовано мясо: %d" % amount
    return true


func summary() -> Dictionary:
    # UI и тесты получают копию, чтобы не менять склад напрямую.
    return {"day": last_day, "site": site,
        "carcasses": _carcasses.duplicate(true),
        "products": _products.duplicate(true),
        "order": _order.duplicate(true),
        "consumed_meat": eaten_meat, "event": last_event}


func to_data() -> Dictionary:
    # Снимок хранит материал и реальные туши отдельно от стада.
    return {"version": FORMAT_VERSION, "last_day": last_day,
        "site": [site.x, site.y],
        "carcasses": _carcasses.duplicate(true),
        "products": _products.duplicate(true),
        "order": _order.duplicate(true),
        "consumed_meat": eaten_meat, "last_event": last_event}


func load_data(data: Dictionary) -> bool:
    # При повреждённом сохранении ничего не присваиваем.
    # Старые файлы без этого слоя обрабатывает WorldSave.
    if data.get("version") != FORMAT_VERSION \
            or data.get("last_day") != climate.day \
            or not (data.get("site") is Array) \
            or not (data.get("carcasses") is Dictionary) \
            or not (data.get("products") is Dictionary) \
            or not (data.get("order") is Dictionary) \
            or not (data.get("last_event") is String):
        return false
    var location: Array = data["site"]
    if location.size() != 2:
        return false
    for value in location:
        if not (value is int or value is float) \
                or not is_finite(float(value)) \
                or float(value) != float(int(value)):
            return false
    var cell := Vector2i(int(location[0]), int(location[1]))
    if not world.config.contains_cell(cell):
        return false
    var allowed_products := {}
    for recipe in YIELDS.values():
        for item in recipe:
            allowed_products[item] = true
    for section in ["carcasses", "products"]:
        for key in data[section]:
            var value: Variant = data[section][key]
            var valid := YIELDS.has(key) if section == "carcasses" \
                else allowed_products.has(key)
            if not valid or not (value is int or value is float) \
                    or not is_finite(float(value)) \
                    or float(value) != float(int(value)) \
                    or value < 1 or value > MAX_STOCK:
                return false
    var eaten: Variant = data.get("consumed_meat")
    if not (eaten is int or eaten is float) \
            or not is_finite(float(eaten)) \
            or float(eaten) != float(int(eaten)) \
            or eaten < 0 or eaten > MAX_STOCK:
        return false
    var pending: Dictionary = data["order"]
    if not pending.is_empty():
        if not YIELDS.has(pending.get("species")) \
                or pending.get("phase") not in ["туда", "обратно"] \
                or not (pending.get("killed") is bool):
            return false
        if bool(pending["killed"]) != (pending["phase"] == "обратно"):
            return false
        var amount: Variant = pending.get("amount")
        if not (amount is int or amount is float) \
                or not is_finite(float(amount)) \
                or float(amount) != float(int(amount)) \
                or amount < 1 or amount > MAX_BATCH:
            return false
        for field in ["region", "target", "position"]:
            var pair: Variant = pending.get(field)
            if not (pair is Array) or pair.size() != 2:
                return false
            for v in pair:
                if not (v is int or v is float) \
                        or not is_finite(float(v)) \
                        or float(v) != float(int(v)):
                    return false
            var coord := Vector2i(int(pair[0]), int(pair[1]))
            if field == "region":
                if not world.config.region_rect(coord).has_area():
                    return false
            elif not world.config.contains_cell(coord):
                return false
        var target: Array = pending["target"]
        var region: Array = pending["region"]
        if world.config.region_of(Vector2i(
                int(target[0]), int(target[1]))) != Vector2i(
                int(region[0]), int(region[1])):
            return false
    site = cell
    _carcasses = data["carcasses"].duplicate(true)
    _products = data["products"].duplicate(true)
    _order = pending.duplicate(true)
    eaten_meat = int(eaten)
    last_day = climate.day
    last_event = str(data["last_event"])
    return true
