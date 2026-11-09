extends RefCounted
## 12.8: отлов диких предков, потомство и последовательный отбор.
## Постройки не создают коров, кур, гусей, собак и кошек.

const Paths = preload("res://scripts/world_resource_path.gd")
const Access = preload("res://scripts/wildlife_region_access.gd")
const Habitats = preload("res://scripts/wildlife_habitats.gd")
const FORMAT_VERSION := 1
const STEPS_PER_DAY := 8
const MAX_CAPTURE := 4
const MAX_HERD := 120
const BREED_DAYS := 24
const REQUIRED_GENERATIONS := 4
const LINEAGES := {
    "корова": {"ancestor": "тур", "predator": false},
    "курица": {"ancestor": "дикая курица", "predator": false},
    "гусь": {"ancestor": "дикий гусь", "predator": false},
    "собака": {"ancestor": "волк", "predator": true},
    "кошка": {"ancestor": "дикая кошка", "predator": true}
}

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var climate: RefCounted
var wildlife: RefCounted
var predators: RefCounted
var harvest: RefCounted
var habitats: RefCounted
var site := Vector2i(-1, -1)
var last_day := 0
var _herds: Dictionary = {}
var _order: Dictionary = {}
var last_event := "Домашних животных нет"


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        weather: RefCounted, animals: RefCounted,
        hunters: RefCounted, food: RefCounted) -> void:
    # Отлов изымает предков непосредственно из природных популяций,
    # а для хищников используется тот же пищевой реестр, что охота.
    world = map
    hydro = water
    surface = ground
    climate = weather
    wildlife = animals
    predators = hunters
    harvest = food
    habitats = Habitats.new(map, water, ground, weather, animals.nature)
    last_day = weather.day


func activate(cell: Vector2i) -> bool:
    # Пустое пастбище не выдаёт стартовые стада или домашних питомцев.
    if site.x >= 0 or not Paths.walkable(world, hydro, surface, cell):
        return false
    site = cell
    last_event = "Участок готов; нужны живые предки из природы"
    return true


func _available(region: Vector2i, domestic: String) -> int:
    # Нельзя заменить отсутствующего дикого предка другим видом.
    var rule: Dictionary = LINEAGES.get(domestic, {})
    if rule.is_empty():
        return 0
    if bool(rule["predator"]):
        return predators.count_at(region, str(rule["ancestor"]))
    return wildlife.population_at(region, str(rule["ancestor"]))


func order_capture(region: Vector2i, domestic: String, amount: int) -> bool:
    # Участок, вид, живая исходная популяция и наземный маршрут
    # проверяются ДО создания заказа. Отлов не происходит при клике.
    if site.x < 0 or not _order.is_empty() \
            or not LINEAGES.has(domestic) or amount < 1 \
            or amount > MAX_CAPTURE or _available(region, domestic) < amount:
        return false
    var route: Dictionary = Access.entry(world, hydro, surface, site, region)
    if route.is_empty():
        last_event = "Дикие предки недоступны по суше"
        return false
    var target: Vector2i = route["cell"]
    _order = {
        "domestic": domestic, "amount": amount,
        "region": [region.x, region.y],
        "target": [target.x, target.y], "position": [site.x, site.y],
        "phase": "туда", "caught": false
    }
    last_event = "Начат отлов предка: " + str(LINEAGES[domestic]["ancestor"])
    return true


func _catch() -> bool:
    # Изъятие происходит только после прибытия; если стадо ушло,
    # заказ отменяется без возникновения нового домашнего животного.
    var pair: Array = _order["region"]
    var region := Vector2i(int(pair[0]), int(pair[1]))
    var domestic: String = _order["domestic"]
    var rule: Dictionary = LINEAGES[domestic]
    var amount: int = _order["amount"]
    if _available(region, domestic) < amount:
        return false
    if bool(rule["predator"]):
        return predators.capture_predators(region, str(rule["ancestor"]), amount)
    return wildlife.consume_prey(region, str(rule["ancestor"]), amount)


func _arrive() -> void:
    # Сначала существуют лишь пойманные дикие основатели.
    # Они не превращаются в породистую корову или собаку по нажатию.
    var kind: String = _order["domestic"]
    var amount: int = _order["amount"]
    var record: Dictionary = _herds.get(kind, {
        "founders": 0, "young": 0, "domestic": 0,
        "generations": 0, "ancestors": [],
        "origin": []
    })
    record = record.duplicate(true)
    record["founders"] = int(record["founders"]) + amount
    record["ancestors"] = [str(LINEAGES[kind]["ancestor"])]
    var origin: Array = _order["region"]
    # Сохраняем происхождение каждого отлова как исходный ареал.
    var provenance: Array = record["origin"]
    provenance.append([int(origin[0]), int(origin[1]), amount])
    record["origin"] = provenance
    _herds[kind] = record
    _order.clear()
    last_event = "Живые дикие основатели доставлены: " + kind


func _breed(kind: String, record: Dictionary) -> void:
    # Племенной цикл возможен только при наличии пары родителей.
    # Травоядным нужны реальные пастбищные условия; хищникам —
    # запас мяса из настоящей добычи, который при кормлении списываем.
    var parents := int(record["founders"]) + int(record["young"]) \
        + int(record["domestic"])
    if parents < 2 or parents >= MAX_HERD:
        return
    var rule: Dictionary = LINEAGES[kind]
    if bool(rule["predator"]):
        if not harvest.consume_food(2):
            return
    else:
        var habitat: Dictionary = habitats.profile_at(site)
        if habitat.is_empty() or float(habitat["food"]) < 0.15 \
                or float(habitat["water"]) < 0.10:
            return
    var next_record: Dictionary = record.duplicate(true)
    # Появляется только одно потомство от реальных родителей.
    # Продвижение линии происходит через поколения, не через здание.
    next_record["generations"] = int(record["generations"]) + 1
    if int(next_record["generations"]) < REQUIRED_GENERATIONS:
        next_record["young"] = int(record["young"]) + 1
    else:
        next_record["domestic"] = int(record["domestic"]) \
            + int(record["young"]) + 1
        next_record["young"] = 0
    _herds[kind] = next_record
    last_event = "Новая генерация потомков: " + kind


func advance_day(day: int) -> bool:
    # Охота и отлов завершаются после общего природного дня.
    # Нельзя ускорить одомашнивание одним большим скачком даты.
    if day != last_day + 1 or day != climate.day:
        return false
    last_day = day
    if not _order.is_empty():
        var pair: Array = _order["position"]
        var current := Vector2i(int(pair[0]), int(pair[1]))
        var destination := site
        if _order["phase"] == "туда":
            var target: Array = _order["target"]
            destination = Vector2i(int(target[0]), int(target[1]))
        if current != destination:
            var path: Array[Vector2i] = Paths.find(
                world, hydro, surface, current, destination)
            if path.is_empty():
                last_event = "Путь отлова закрыт погодой или рельефом"
            else:
                var steps := mini(STEPS_PER_DAY, path.size())
                current = path[steps - 1]
                _order["position"] = [current.x, current.y]
        if current == destination:
            if _order["phase"] == "туда":
                if not _catch():
                    _order.clear()
                    last_event = "Дикие предки покинули ареал"
                else:
                    _order["phase"] = "обратно"
                    _order["caught"] = true
                    last_event = "Пойманные предки едут к участку"
            else:
                _arrive()
    if day % BREED_DAYS == 0:
        for kind in LINEAGES:
            if _herds.has(kind):
                _breed(kind, _herds[kind])
    return true


func total(domestic: String, domesticated_only: bool = false) -> int:
    # До четырёх поколений выведенный помёт не считается
    # полноценной домашней породой и не выдаётся игроку за неё.
    var item: Dictionary = _herds.get(domestic, {})
    if item.is_empty():
        return 0
    if domesticated_only:
        return int(item["domestic"])
    return int(item["founders"]) + int(item["young"]) \
        + int(item["domestic"])


func summary() -> Dictionary:
    # Отдельно показываем пойманных предков и домашних потомков.
    return {"day": last_day, "herds": _herds.duplicate(true),
        "pending": _order.duplicate(true), "event": last_event}


func to_data() -> Dictionary:
    # Протокол фиксирует происхождение, поколения и перевозку.
    return {"version": FORMAT_VERSION, "last_day": last_day,
        "site": [site.x, site.y], "herds": _herds.duplicate(true),
        "order": _order.duplicate(true), "last_event": last_event}


func load_data(data: Dictionary) -> bool:
    # Запрещено импортировать домашнее животное без предковой
    # популяции и списка реальных отловов. Ошибка атомарна.
    if data.get("version") != FORMAT_VERSION \
            or data.get("last_day") != climate.day \
            or not (data.get("site") is Array) \
            or not (data.get("herds") is Dictionary) \
            or not (data.get("order") is Dictionary) \
            or not (data.get("last_event") is String):
        return false
    var coords: Array = data["site"]
    if coords.size() != 2:
        return false
    for n in coords:
        if not (n is int or n is float) \
                or not is_finite(float(n)) or float(n) != float(int(n)):
            return false
    var location := Vector2i(int(coords[0]), int(coords[1]))
    if not world.config.contains_cell(location):
        return false
    var herds: Dictionary = data["herds"]
    for kind in herds:
        if not LINEAGES.has(kind) or not (herds[kind] is Dictionary):
            return false
        var record: Dictionary = herds[kind]
        for field in ["founders", "young", "domestic", "generations"]:
            var number: Variant = record.get(field)
            if not (number is int or number is float) \
                    or not is_finite(float(number)) \
                    or float(number) != float(int(number)) \
                    or number < 0 or number > MAX_HERD:
                return false
        if record.get("ancestors") != [str(LINEAGES[kind]["ancestor"])] \
                or not (record.get("origin") is Array):
            return false
        var origins: Array = record["origin"]
        if origins.is_empty() or origins.size() > MAX_HERD:
            return false
        var captured := 0
        for source in origins:
            if not (source is Array) or source.size() != 3:
                return false
            for n in source:
                if not (n is int or n is float) \
                        or not is_finite(float(n)) \
                        or float(n) != float(int(n)):
                    return false
            if not world.config.region_rect(Vector2i(
                    int(source[0]), int(source[1]))).has_area() \
                    or int(source[2]) < 1 or int(source[2]) > MAX_CAPTURE:
                return false
            captured += int(source[2])
        if captured != int(record["founders"]) \
                or int(record["founders"]) + int(record["young"]) \
                + int(record["domestic"]) > MAX_HERD \
                or (int(record["generations"]) < REQUIRED_GENERATIONS \
                and int(record["domestic"]) > 0):
            return false
    var order: Dictionary = data["order"]
    if not order.is_empty():
        if not LINEAGES.has(order.get("domestic")) \
                or order.get("phase") not in ["туда", "обратно"] \
                or not (order.get("caught") is bool):
            return false
        if bool(order["caught"]) != (order["phase"] == "обратно"):
            return false
        var amount: Variant = order.get("amount")
        if not (amount is int or amount is float) \
                or not is_finite(float(amount)) \
                or float(amount) != float(int(amount)) \
                or amount < 1 or amount > MAX_CAPTURE:
            return false
        for field in ["region", "target", "position"]:
            var pair: Variant = order.get(field)
            if not (pair is Array) or pair.size() != 2:
                return false
            for n in pair:
                if not (n is int or n is float) \
                        or not is_finite(float(n)) \
                        or float(n) != float(int(n)):
                    return false
            var cell := Vector2i(int(pair[0]), int(pair[1]))
            if field == "region":
                if not world.config.region_rect(cell).has_area():
                    return false
            elif not world.config.contains_cell(cell):
                return false
        var target: Array = order["target"]
        var region: Array = order["region"]
        if world.config.region_of(Vector2i(
                int(target[0]), int(target[1]))) != Vector2i(
                int(region[0]), int(region[1])):
            return false
    site = location
    _herds = herds.duplicate(true)
    _order = order.duplicate(true)
    last_day = climate.day
    last_event = str(data["last_event"])
    return true
