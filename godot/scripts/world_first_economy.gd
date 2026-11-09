extends RefCounted
## Первый физический хозяйственный цикл: глина → доставка → обжиг → постройка.
## Поставки расходуют реальные залежи и древесину, не создавая сырьё из команд.

const CLAY_UNITS := 3
const FUEL_UNITS := 3
const BRICKS_REQUIRED := 3
const STEPS_PER_DAY := 8
const VERSION := 1
const DIRECTIONS := [
    Vector2i(1, 0), Vector2i(0, 1),
    Vector2i(-1, 0), Vector2i(0, -1)
]
const PHASES := [
    "ожидание", "к_глине", "добыча", "назад_с_глиной",
    "к_дереву", "рубка", "назад_с_древесиной",
    "обжиг", "строительство", "готово", "приостановлено"
]

var world: RefCounted
var hydro: RefCounted
var surface: RefCounted
var nature: RefCounted
var resources: RefCounted
var last_day := 0
var phase := "ожидание"
var site := Vector2i(-1, -1)
var worker := Vector2i(-1, -1)
var clay_cell := Vector2i(-1, -1)
var tree_stop := Vector2i(-1, -1)
var clay_id := ""
var tree_id := -1
var cargo_clay := 0
var cargo_wood := 0
var stored_clay := 0
var stored_wood := 0
var bricks := 0
var built := false
var last_event := "Строительство ещё не заказано"


func _init(map: RefCounted, water: RefCounted, ground: RefCounted,
        vegetation: RefCounted, deposits: RefCounted, day: int = 0) -> void:
    # Модель не создаёт дублей природы: все списания идут в исходные реестры.
    world = map
    hydro = water
    surface = ground
    nature = vegetation
    resources = deposits
    last_day = day


func _walkable(cell: Vector2i) -> bool:
    # Используем те же базовые запреты, что и географический сценарий:
    # вода, паводок, слишком крутой склон или заболоченная поверхность.
    if not world.config.contains_cell(cell):
        return false
    var index: int = cell.y * world.config.width + cell.x
    return not hydro.has_water(index) and not hydro.flooded_at(index) \
        and world.normal_at(cell).y >= 0.76 \
        and surface.waterlogging_at_index(index) <= 0.85


func _buildable(cell: Vector2i) -> bool:
    # Фундамент не ставим на дерево, валун или недопустимый грунт.
    if not _walkable(cell):
        return false
    var index: int = cell.y * world.config.width + cell.x
    return world.normal_at(cell).y >= 0.88 \
        and surface.waterlogging_at_index(index) <= 0.70 \
        and surface.soil_depth_at_index(index) >= 0.12 \
        and not nature.intersects_solid(Vector2(cell) + Vector2(0.5, 0.5), 0.32)


func _route(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
    # Четырёхсвязный поиск на физической карте: не телепортируем груз
    # через море и не считаем непреодолимые склоны готовыми дорогами.
    var result: Array[Vector2i] = []
    if not _walkable(from) or not _walkable(to):
        return result
    if from == to:
        return result
    var width: int = world.config.width
    var size: int = width * world.config.height
    var parents := PackedInt32Array()
    parents.resize(size)
    parents.fill(-1)
    var first: int = from.y * width + from.x
    var finish: int = to.y * width + to.x
    var queue: Array[int] = [first]
    parents[first] = first
    var cursor := 0
    while cursor < queue.size() and parents[finish] == -1:
        var current: int = queue[cursor]
        cursor += 1
        var x: int = current % width
        var y: int = current / width
        for direction in DIRECTIONS:
            var next_cell: Vector2i = Vector2i(x, y) + direction
            if not _walkable(next_cell):
                continue
            var next: int = next_cell.y * width + next_cell.x
            if parents[next] != -1:
                continue
            parents[next] = current
            queue.append(next)
            if next == finish:
                break
    if parents[finish] == -1:
        return result
    var reverse: Array[Vector2i] = []
    var position := finish
    while position != first:
        reverse.append(Vector2i(position % width, position / width))
        position = parents[position]
    reverse.reverse()
    return reverse


func _find_site(clay: Vector2i) -> Vector2i:
    # Рабочая площадка стоит близко к залежи, но не на месте добычи.
    # Проверка доступности предотвращает строительство за рекой.
    for distance in range(3, 13):
        for direction in DIRECTIONS:
            var candidate: Vector2i = clay + direction * distance
            if _buildable(candidate) and not _route(candidate, clay).is_empty():
                return candidate
    return Vector2i(-1, -1)


func start() -> bool:
    # Подбираем реальную связанную пару «глина — лес»; при отказе
    # не списываем ни один запас и не создаём фиктивную постройку.
    if phase != "ожидание":
        return false
    hydro.ensure_ready()
    surface.ensure_ready()
    var trees: Array = nature.to_data().get("objects", [])
    for deposit in resources.to_data().get("sources", []):
        if deposit["kind"] != "глина" or int(deposit["remaining_units"]) < CLAY_UNITS:
            continue
        var cell := Vector2i(int(deposit["x"]), int(deposit["y"]))
        var camp := _find_site(cell)
        if camp.x < 0:
            continue
        for item in trees:
            # Поля реестра природы: id, тип, вид, x/y, возраст,
            # здоровье, древесина, лежащая древесина, состояние.
            if item[1] != "дерево" or (int(item[7]) < FUEL_UNITS \
                    and int(item[8]) < FUEL_UNITS):
                continue
            var tree := Vector2i(int(item[3]), int(item[4]))
            if (tree - camp).length_squared() > 40 * 40:
                continue
            for direction in DIRECTIONS:
                var approach: Vector2i = tree + direction
                if not _walkable(approach):
                    continue
                if approach != camp and _route(camp, approach).is_empty():
                    continue
                site = camp
                worker = camp
                clay_cell = cell
                tree_stop = approach
                clay_id = str(deposit["id"])
                tree_id = int(item[0])
                phase = "к_глине"
                last_event = "Заказ: добыть глину и привезти древесину"
                return true
    last_event = "Нет доступной пары: глина, лес и проходимый маршрут"
    return false


func _travel(target: Vector2i, next_phase: String, description: String) -> void:
    # За один игровой день рабочий проходит лишь ограниченный маршрут.
    # Задержка перевозки зависит от настоящей географии карты.
    if worker == target:
        phase = next_phase
        return
    var path: Array[Vector2i] = _route(worker, target)
    if path.is_empty():
        phase = "приостановлено"
        last_event = "Проход к ресурсу перекрыт природными изменениями"
        return
    worker = path[mini(STEPS_PER_DAY, path.size()) - 1]
    last_event = "%s: %d клеток до цели" % [
        description, maxi(0, path.size() - STEPS_PER_DAY)]
    if worker == target:
        phase = next_phase


func advance_day(day: int) -> void:
    # Хозяйство обновляется один раз за календарный день и не зависит
    # от FPS, камеры, чанков и повторного открытия карты.
    if day <= last_day:
        return
    last_day = day
    match phase:
        "к_глине":
            _travel(clay_cell, "добыча", "Рабочий идёт к глине")
        "добыча":
            var deposit: Dictionary = resources.source_at("глина", clay_cell)
            if int(deposit.get("remaining_units", 0)) < CLAY_UNITS:
                phase = "приостановлено"
                last_event = "Месторождение глины истощено"
                return
            cargo_clay = resources.extract(clay_id, CLAY_UNITS)
            phase = "назад_с_глиной"
            last_event = "Добыто %d единиц глины" % cargo_clay
        "назад_с_глиной":
            _travel(site, "к_дереву", "Перевозка глины")
            if phase == "к_дереву":
                stored_clay += cargo_clay
                cargo_clay = 0
        "к_дереву":
            _travel(tree_stop, "рубка", "Рабочий идёт к лесу")
        "рубка":
            var stock: Dictionary = nature.resource_stock(tree_id)
            var wood: Dictionary = stock.get("resources", {}).get("wood", {})
            if int(wood.get("available", 0)) < FUEL_UNITS:
                if nature.fell_tree(tree_id).is_empty():
                    phase = "приостановлено"
                    last_event = "Древесина исчезла до рубки"
                    return
            if not nature.take_raw_resource(tree_id, "wood", FUEL_UNITS):
                phase = "приостановлено"
                last_event = "Невозможно забрать древесину"
                return
            cargo_wood = FUEL_UNITS
            phase = "назад_с_древесиной"
            last_event = "Заготовлена древесина из существующего дерева"
        "назад_с_древесиной":
            _travel(site, "обжиг", "Перевозка древесины")
            if phase == "обжиг":
                stored_wood += cargo_wood
                cargo_wood = 0
        "обжиг":
            if stored_clay < CLAY_UNITS or stored_wood < FUEL_UNITS:
                phase = "приостановлено"
                last_event = "Для обжига не хватает материалов"
                return
            # Реальная переработка меняет склад: глина и топливо исчезают,
            # а кирпичи появляются как отдельный продукт, не как месторождение.
            stored_clay -= CLAY_UNITS
            stored_wood -= FUEL_UNITS
            bricks += BRICKS_REQUIRED
            phase = "строительство"
            last_event = "Обожжены кирпичи из доставленного сырья"
        "строительство":
            if bricks < BRICKS_REQUIRED:
                phase = "приостановлено"
                last_event = "Для строительства не хватает кирпичей"
                return
            bricks -= BRICKS_REQUIRED
            built = true
            phase = "готово"
            last_event = "Кирпичная мастерская построена; сырьё израсходовано"


func summary() -> Dictionary:
    # Возвращаем снимок для UI и тестов без доступа к изменяемому складу.
    return {
        "phase": phase, "day": last_day, "event": last_event,
        "worker": worker, "site": site, "built": built,
        "clay_in_transit": cargo_clay, "wood_in_transit": cargo_wood,
        "stored_clay": stored_clay, "stored_wood": stored_wood,
        "bricks": bricks
    }


func to_data() -> Dictionary:
    # В файловом снимке только числа и строки: нет ссылок на Godot-узлы.
    return {
        "version": VERSION, "last_day": last_day, "phase": phase,
        "site": [site.x, site.y], "worker": [worker.x, worker.y],
        "clay_cell": [clay_cell.x, clay_cell.y],
        "tree_stop": [tree_stop.x, tree_stop.y],
        "clay_id": clay_id, "tree_id": tree_id,
        "cargo_clay": cargo_clay, "cargo_wood": cargo_wood,
        "stored_clay": stored_clay, "stored_wood": stored_wood,
        "bricks": bricks, "built": built, "last_event": last_event
    }


func load_data(data: Dictionary, saved_day: int) -> bool:
    # Неполный или испорченный снимок не должен частично менять хозяйство.
    if data.get("version") != VERSION or data.get("phase") not in PHASES \
            or data.get("last_day") != saved_day \
            or not (data.get("clay_id") is String) \
            or not (data.get("last_event") is String) \
            or not (data.get("built") is bool):
        return false
    var fields := ["tree_id", "cargo_clay", "cargo_wood",
        "stored_clay", "stored_wood", "bricks"]
    for key in fields:
        var value: Variant = data.get(key)
        if not (value is int or value is float) \
                or not is_finite(float(value)) \
                or float(value) != float(int(value)):
            return false
        # Загрузка не может подделать сотни кирпичей из трёх единиц
        # глины: ограничиваем каждый отсек объёмом настоящего заказа.
        var limit := FUEL_UNITS if key in [
            "cargo_wood", "stored_wood"] else (
            CLAY_UNITS if key in ["cargo_clay", "stored_clay"]
            else BRICKS_REQUIRED)
        if key != "tree_id" and (value < 0 or value > limit):
            return false
    var cells := {}
    for key in ["site", "worker", "clay_cell", "tree_stop"]:
        var pair: Variant = data.get(key)
        if not (pair is Array) or pair.size() != 2:
            return false
        for number in pair:
            if not (number is int or number is float) \
                    or not is_finite(float(number)) \
                    or float(number) != float(int(number)):
                return false
        var cell := Vector2i(int(pair[0]), int(pair[1]))
        if data["phase"] != "ожидание" \
                and not world.config.contains_cell(cell):
            return false
        cells[key] = cell
    if bool(data["built"]) != (data["phase"] == "готово"):
        return false
    if bool(data["built"]) and (int(data["cargo_clay"]) != 0
            or int(data["cargo_wood"]) != 0
            or int(data["stored_clay"]) != 0
            or int(data["stored_wood"]) != 0 or int(data["bricks"]) != 0):
        return false
    if data["phase"] != "ожидание" and str(data["clay_id"]) != \
            str(resources.source_id("глина", cells["clay_cell"])):
        return false
    if data["phase"] != "ожидание" and (int(data["tree_id"]) < 1 \
            or not str(data["clay_id"]).begins_with("глина:")):
        return false
    phase = str(data["phase"])
    site = cells["site"]
    worker = cells["worker"]
    clay_cell = cells["clay_cell"]
    tree_stop = cells["tree_stop"]
    clay_id = str(data["clay_id"])
    tree_id = int(data["tree_id"])
    cargo_clay = int(data["cargo_clay"])
    cargo_wood = int(data["cargo_wood"])
    stored_clay = int(data["stored_clay"])
    stored_wood = int(data["stored_wood"])
    bricks = int(data["bricks"])
    built = bool(data["built"])
    last_event = str(data["last_event"])
    last_day = saved_day
    return true
