extends RefCounted
## Универсальный склад и производственный участок первого хозяйственного масштаба.
## Источники списываются лишь на месте добычи, перевозка занимает дни.

const Paths = preload("res://scripts/world_resource_path.gd")
const Recipes = preload("res://scripts/natural_resource_recipes.gd")

const VERSION := 1
const STEPS_PER_DAY := 8
const MAX_DELIVERY := 20
const MAX_STOCK := 100000
const MAX_COMPLETED := 10000
const MAX_PENDING_STEPS := 100000
const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(0, 1),
    Vector2i(-1, 0), Vector2i(0, -1)
]

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var nature: RefCounted
var deposits: RefCounted
var site := Vector2i(-1, -1)
var last_day := 0
var technology := 0
var stock: Dictionary = {}
var completed: Dictionary = {}
var delivery: Dictionary = {}
var last_event := "Хозяйственный участок не создан"


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        vegetation: RefCounted, resources: RefCounted, day: int = 0) -> void:
    # Все объекты остаются ссылками на исходные природные реестры;
    # повторной генерации леса, камня или руды здесь нет.
    world = map
    hydro = water
    surface = ground
    nature = vegetation
    deposits = resources
    last_day = day


func activate(cell: Vector2i) -> bool:
    # Участок появляется только на проходимой суше. Новых запасов
    # или технологий при создании мастерской не выдаётся.
    if site.x >= 0 or not Paths.walkable(world, hydro, surface, cell):
        return false
    site = cell
    last_event = "Участок готов; для работы требуются физические поставки"
    return true


func _schedule(kind: String, source_id: String,
        tree_id: int, target: Vector2i, amount: int,
        length: int) -> bool:
    # Один перевозчик одновременно обслуживает одну поставку.
    # Источник пока не меняется: списание произойдёт при прибытии.
    if site.x < 0 or not delivery.is_empty() or amount < 1 \
            or amount > MAX_DELIVERY or length < 1 \
            or length > MAX_PENDING_STEPS:
        return false
    delivery = {
        "kind": kind, "source_id": source_id,
        "tree_id": tree_id, "amount": amount,
        "target": [target.x, target.y],
        "length": length, "left": length, "phase": "туда"
    }
    last_event = "Перевозчик отправился за ресурсом: " + kind
    return true


func order_deposit(kind: String, amount: int) -> bool:
    # Кандидаты сортируем по настоящей длине маршрута, а не
    # прямому расстоянию через реки или горные склоны.
    if kind not in Recipes.RAW_MATERIALS or kind == "древесина" \
            or site.x < 0 or not delivery.is_empty():
        return false
    var best: Dictionary = {}
    var best_length := MAX_PENDING_STEPS + 1
    for item in deposits.to_data().get("sources", []):
        if str(item["kind"]) != kind or int(item["remaining_units"]) < amount:
            continue
        var target := Vector2i(int(item["x"]), int(item["y"]))
        var route: Array[Vector2i] = Paths.find(
            world, hydro, surface, site, target)
        if route.is_empty() or route.size() >= best_length:
            continue
        best = item
        best_length = route.size()
    if best.is_empty():
        last_event = "Нет достижимого месторождения: " + kind
        return false
    return _schedule(kind, str(best["id"]), -1, Vector2i(
        int(best["x"]), int(best["y"])), amount, best_length)


func order_wood(amount: int) -> bool:
    # Подходим к соседней клетке реального дерева. Нельзя брать
    # древесину у ещё не срубленного дерева или из лесной декорации.
    if amount < 1 or amount > MAX_DELIVERY \
            or site.x < 0 or not delivery.is_empty():
        return false
    var best_id := -1
    var best_stop := Vector2i(-1, -1)
    var best_length := MAX_PENDING_STEPS + 1
    for object in nature.to_data().get("objects", []):
        if str(object[1]) != "дерево" \
                or int(object[7]) + int(object[8]) < amount:
            continue
        var tree := Vector2i(int(object[3]), int(object[4]))
        for direction in DIRECTIONS:
            var target: Vector2i = tree + direction
            var route: Array[Vector2i] = Paths.find(
                world, hydro, surface, site, target)
            if route.is_empty() or route.size() >= best_length:
                continue
            best_id = int(object[0])
            best_stop = target
            best_length = route.size()
    if best_id < 0:
        last_event = "Нет доступной древесины по сухопутному маршруту"
        return false
    return _schedule("древесина", "", best_id, best_stop,
        amount, best_length)


func _collect() -> bool:
    # Вычитаем сырьё непосредственно в точке работы. Если другое
    # природное событие уничтожило источник — поставка срывается.
    var kind: String = delivery["kind"]
    var amount: int = delivery["amount"]
    if kind == "древесина":
        var id: int = delivery["tree_id"]
        var current: Dictionary = nature.resource_stock(id)
        var wood: Dictionary = current.get("resources", {}).get("wood", {})
        if int(wood.get("available", 0)) < amount:
            if nature.fell_tree(id).is_empty():
                return false
        return nature.take_raw_resource(id, "wood", amount)
    var id: String = delivery["source_id"]
    var target: Array = delivery["target"]
    var cell := Vector2i(int(target[0]), int(target[1]))
    var entry: Dictionary = deposits.source_at(kind, cell)
    if str(entry.get("id", "")) != id \
            or int(entry.get("remaining_units", 0)) < amount:
        return false
    return deposits.extract(id, amount) == amount


func advance_day(day: int) -> void:
    # Ускоренная перемотка проходит каждый промежуточный день;
    # нельзя мгновенно перевезти груз одним большим шагом времени.
    if day <= last_day:
        return
    for current_day in range(last_day + 1, day + 1):
        if delivery.is_empty():
            continue
        delivery["left"] = maxi(0, int(delivery["left"]) - STEPS_PER_DAY)
        if int(delivery["left"]) > 0:
            continue
        if delivery["phase"] == "туда":
            if not _collect():
                last_event = "Источник исчез или запас исчерпан"
                delivery.clear()
                continue
            delivery["phase"] = "обратно"
            delivery["left"] = int(delivery["length"])
            last_event = "Сырьё добыто; перевозчик возвращается"
            continue
        # Только по возвращении в мастерскую груз становится складским.
        var kind: String = delivery["kind"]
        var amount: int = delivery["amount"]
        stock[kind] = int(stock.get(kind, 0)) + amount
        last_event = "Доставлено %d ед.: %s" % [amount, kind]
        delivery.clear()
    last_day = day


func _consume(inputs: Dictionary) -> bool:
    # Проверка всех компонентов ДО первого списания гарантирует
    # отсутствие наполовину выполненного производственного шага.
    for kind in inputs:
        if int(inputs[kind]) < 1 or int(stock.get(kind, 0)) < int(inputs[kind]):
            return false
    for kind in inputs:
        stock[kind] = int(stock[kind]) - int(inputs[kind])
        if int(stock[kind]) == 0:
            stock.erase(kind)
    return true


func produce(recipe_id: String) -> bool:
    # Рецепт разрешён лишь при нужной технологии, наличии каждого
    # материала и места под результат; иначе состояние не меняется.
    var recipe: Dictionary = Recipes.RECIPES.get(recipe_id, {})
    if recipe.is_empty() or technology < int(recipe["tier"]):
        return false
    for kind in recipe["outputs"]:
        if int(recipe["outputs"][kind]) < 1 or int(stock.get(kind, 0)) \
                + int(recipe["outputs"][kind]) > MAX_STOCK:
            return false
    if not _consume(recipe["inputs"]):
        return false
    for kind in recipe["outputs"]:
        stock[kind] = int(stock.get(kind, 0)) + int(recipe["outputs"][kind])
    last_event = "Изготовлен продукт: " + recipe_id
    return true


func construct(consumer_id: String) -> bool:
    # Стройка — отдельный потребитель. Она не производит кирпичи,
    # каменные блоки, инструменты или сырьё при появлении объекта.
    var item: Dictionary = Recipes.CONSUMERS.get(consumer_id, {})
    if site.x < 0 or item.is_empty() or technology < int(item["tier"]) \
            or int(completed.get(consumer_id, 0)) >= MAX_COMPLETED:
        return false
    if not _consume(item["inputs"]):
        return false
    completed[consumer_id] = int(completed.get(consumer_id, 0)) + 1
    last_event = "Постройка завершена: " + consumer_id
    return true


func research_next() -> bool:
    # Новые технологии не появляются от кнопки: для развития цеха
    # требуется уже изготовленная продукция предыдущего уровня.
    var cost := {}
    if technology == 0:
        cost = {"каменные блоки": 2, "обожжённый кирпич": 3}
    elif technology == 1:
        cost = {"железо": 2, "медь": 2}
    else:
        return false
    if not _consume(cost):
        return false
    technology += 1
    last_event = "Открыта производственная технология %d" % technology
    return true


func state() -> Dictionary:
    # UI и тесты получают копию, а не изменяемый склад с возможностью
    # неучтённого добавления товара.
    return {
        "site": site, "day": last_day, "technology": technology,
        "stock": stock.duplicate(true), "completed": completed.duplicate(true),
        "delivery": delivery.duplicate(true), "event": last_event
    }


func to_data() -> Dictionary:
    # Снимок содержит только простые типы JSON и числа — без Node3D.
    return {
        "version": VERSION, "last_day": last_day,
        "site": [site.x, site.y], "technology": technology,
        "stock": stock.duplicate(true), "completed": completed.duplicate(true),
        "delivery": delivery.duplicate(true), "last_event": last_event
    }


func load_data(data: Dictionary, saved_day: int) -> bool:
    # Полная проверка перед присвоением исключает порчу живой модели
    # при неудачном импорте пользовательского WorldSave.
    if data.get("version") != VERSION or data.get("last_day") != saved_day \
            or not (data.get("site") is Array) \
            or not (data.get("stock") is Dictionary) \
            or not (data.get("completed") is Dictionary) \
            or not (data.get("delivery") is Dictionary) \
            or not (data.get("last_event") is String):
        return false
    var location: Array = data["site"]
    if location.size() != 2:
        return false
    for coordinate in location:
        if not (coordinate is int or coordinate is float) \
                or not is_finite(float(coordinate)) \
                or float(coordinate) != float(int(coordinate)):
            return false
    var cell := Vector2i(int(location[0]), int(location[1]))
    if not world.config.contains_cell(cell):
        return false
    var tier: Variant = data.get("technology")
    if not (tier is int or tier is float) \
            or not is_finite(float(tier)) \
            or float(tier) != float(int(tier)) or tier < 0 or tier > 2:
        return false
    var known: Dictionary = Recipes.materials()
    var restored_stock: Dictionary = data["stock"]
    for key in restored_stock:
        var value: Variant = restored_stock[key]
        if not known.has(key) or not (value is int or value is float) \
                or not is_finite(float(value)) \
                or float(value) != float(int(value)) \
                or value < 1 or value > MAX_STOCK:
            return false
    var restored_buildings: Dictionary = data["completed"]
    for key in restored_buildings:
        var value: Variant = restored_buildings[key]
        if not Recipes.CONSUMERS.has(key) \
                or not (value is int or value is float) \
                or not is_finite(float(value)) \
                or float(value) != float(int(value)) \
                or value < 1 or value > MAX_COMPLETED:
            return false
    var incoming: Dictionary = data["delivery"]
    if not incoming.is_empty():
        for key in ["kind", "source_id", "tree_id", "amount",
                "target", "length", "left", "phase"]:
            if not incoming.has(key):
                return false
        if str(incoming["kind"]) not in Recipes.RAW_MATERIALS \
                or str(incoming["phase"]) not in ["туда", "обратно"] \
                or not (incoming["target"] is Array) \
                or incoming["target"].size() != 2:
            return false
        for key in ["tree_id", "amount", "length", "left"]:
            var value: Variant = incoming[key]
            if not (value is int or value is float) \
                    or not is_finite(float(value)) \
                    or float(value) != float(int(value)):
                return false
        if incoming["amount"] < 1 or incoming["amount"] > MAX_DELIVERY \
                or incoming["length"] < 1 \
                or incoming["length"] > MAX_PENDING_STEPS \
                or incoming["left"] < 0 \
                or incoming["left"] > incoming["length"]:
            return false
        for v in incoming["target"]:
            if not (v is int or v is float) \
                    or not is_finite(float(v)) or float(v) != float(int(v)):
                return false
        var target := Vector2i(int(incoming["target"][0]),
            int(incoming["target"][1]))
        if not world.config.contains_cell(target):
            return false
        if incoming["kind"] == "древесина":
            if incoming["tree_id"] < 1 or str(incoming["source_id"]) != "":
                return false
        else:
            if incoming["tree_id"] != -1 \
                    or str(incoming["source_id"]) != str(incoming["kind"]) \
                    + ":%d:%d" % [target.x, target.y]:
                return false
    site = cell
    last_day = saved_day
    technology = int(tier)
    stock = restored_stock.duplicate(true)
    completed = restored_buildings.duplicate(true)
    delivery = incoming.duplicate(true)
    last_event = str(data["last_event"])
    return true
