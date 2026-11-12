extends RefCounted
## Постоянное поселение этапа 13; право на мастерскую подтверждает Economy.

const Paths = preload("res://scripts/world_resource_path.gd")
const Topology = preload("res://scripts/world_road_topology.gd")

const VERSION := 1
const RADIUS := 9
const MAX_ROADS := 128
const WORKSHOP := "кирпичная мастерская"
const STORAGE := "малый склад"

var world: RefCounted
var economy: RefCounted
var industry: RefCounted
var settlement_id := ""
var center := Vector2i(-1, -1)
var _buildings: Array[Dictionary] = []
var _roads: Dictionary = {}


func _init(map: RefCounted, first_economy: RefCounted,
        production: RefCounted = null) -> void:
    # Не дублируем реестр глины, леса и кирпичей.
    world = map
    economy = first_economy
    bind_industry(production)


func bind_industry(production: RefCounted) -> void:
    # Реестр дорог принадлежит поселению, перевозчики получают ссылку
    # на него, а не независимую копию. При восстановлении всё связываем
    # после загрузки оплаченных производственных записей.
    industry = production
    if industry != null:
        industry.road_tiles = _roads
        _refresh_ports()


static func _id(seed: int, cell: Vector2i) -> String:
    # Стабилен при повторной генерации, перезапуске и загрузке.
    return "поселение:%d:%d:%d" % [seed, cell.x, cell.y]


static func _whole(value: Variant) -> bool:
    # Недоверенный JSON не должен округлять координаты.
    return (value is int or value is float) and is_finite(float(value)) \
        and float(value) == float(int(value))


func established() -> bool:
    return not settlement_id.is_empty()


func found(cell: Vector2i) -> bool:
    # Сначала физически обеспеченный строительный заказ, затем поселение.
    # Землю проверяем тем же контрактом, что WorldFirstEconomy.
    if established() or economy.phase == "ожидание" or economy.site != cell:
        return false
    if not world.config.contains_cell(cell) or not economy._buildable(cell):
        return false
    center = cell
    settlement_id = _id(world.config.world_seed, cell)
    return true


func attach_legacy_workshop() -> bool:
    # Старое сохранение уже оплатило мастерскую. Лишь восстанавливаем
    # её физическую запись без повторной добычи и расхода ресурсов.
    if established() or not economy.built \
            or not world.config.contains_cell(economy.site):
        return false
    center = economy.site
    settlement_id = _id(world.config.world_seed, center)
    return sync_workshop()


func sync_workshop() -> bool:
    # Дубль невозможен: одну оплату нельзя превратить в два здания.
    if not established() or not economy.built or economy.site != center:
        return false
    if has_workshop():
        return false
    _buildings.append({"id": settlement_id + ":мастерская",
        "kind": WORKSHOP, "x": center.x, "y": center.y})
    _refresh_ports()
    return true


func has_workshop() -> bool:
    # Проверяем тип, а не число объектов: рядом может стоять склад.
    for item in _buildings:
        if str(item["kind"]) == WORKSHOP:
            return true
    return false


func has_storage() -> bool:
    # В первом поселении допускается один оплаченный склад.
    for item in _buildings:
        if str(item["kind"]) == STORAGE:
            return true
    return false


func build_storage(cell: Vector2i) -> bool:
    # До списания материалов проверяем место и существующую мастерскую.
    # Отказ не должен менять ни склад сырья, ни реестр построек.
    if not has_workshop() or has_storage() or industry == null \
            or industry.site != center or not within_territory(cell) \
            or occupies(cell) or not economy._buildable(cell):
        return false
    # Фундамент — существующий материальный потребитель этапа 12.
    # Нельзя создать склад только потому, что игрок нажал кнопку.
    if not industry.construct("каменный фундамент"):
        return false
    _buildings.append({"id": settlement_id + ":склад",
        "kind": STORAGE, "x": cell.x, "y": cell.y})
    _refresh_ports()
    return true


func port_for(kind: String) -> Vector2i:
    # Вход в мастерскую или малый склад расположен строго за стеной.
    # Сначала предпочитаем оплаченную дорогу, затем ближайшую к центру
    # доступную клетку. Декоративный меш не влияет на выбор входа.
    if industry == null or not has_workshop():
        return Vector2i(-1, -1)
    for building in _buildings:
        if str(building["kind"]) != kind:
            continue
        var at := Vector2i(int(building["x"]), int(building["y"]))
        var footprint := Rect2i(at, Vector2i.ONE)
        var bounds := Rect2i(Vector2i.ZERO,
            Vector2i(world.config.width, world.config.height))
        var best := Vector2i(-1, -1)
        var score := 100000
        for candidate in Topology.perimeter(footprint, bounds):
            if occupies(candidate) or not Paths.walkable(
                    world, industry.hydro, industry.surface, candidate) \
                    or industry.nature.intersects_solid(
                        Vector2(candidate) + Vector2(0.5, 0.5), 0.35):
                continue
            var distance := absi(candidate.x - center.x) \
                + absi(candidate.y - center.y)
            var priority := distance + (0 if _roads.has(candidate) else 100)
            if priority < score:
                best = candidate
                score = priority
        return best
    return Vector2i(-1, -1)


func _refresh_ports() -> void:
    # Фундаменты исключаются из поиска путей, а порт выбирается из
    # геометрии того же физического реестра. Не создаём отдельный склад.
    if industry == null:
        return
    industry.blocked_tiles.clear()
    for item in _buildings:
        var cell := Vector2i(int(item["x"]), int(item["y"]))
        industry.blocked_tiles[cell] = true
    var port := port_for(STORAGE) if has_storage() else port_for(WORKSHOP)
    if port.x < 0:
        port = port_for(WORKSHOP)
    if port.x >= 0:
        industry.set_home_port(port)


func roads() -> Array[Vector2i]:
    # UI получает упорядоченный список, но не ссылку на реестр.
    # Сортировка делает сериализацию независимой от истории вставки.
    var cells: Array[Vector2i] = []
    for cell in _roads:
        cells.append(cell)
    cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.y < b.y if a.y != b.y else a.x < b.x)
    return cells


func road_mask(cell: Vector2i) -> int:
    # Геометрия соединений определяется только построенными дорогами.
    return Topology.road_mask(_roads, cell)


func _road_connected(cell: Vector2i, registry: Dictionary) -> bool:
    # Первый участок начинается от мастерской; остальные продолжают
    # реально существующую четырёхсвязную дорогу.
    if absi(cell.x - center.x) + absi(cell.y - center.y) == 1:
        return true
    for side in Topology.SIDES:
        if registry.has(cell + side):
            return true
    return false


func can_build_road(cell: Vector2i) -> bool:
    # Не допускаем дорог внутри зданий, в воде, на непроходимых склонах
    # и сквозь объекты природы. Проверка не изменяет склад.
    if not has_workshop() or industry == null or industry.site != center \
            or _roads.size() >= MAX_ROADS or not within_territory(cell) \
            or occupies(cell) or _roads.has(cell):
        return false
    if not Paths.walkable(world, industry.hydro, industry.surface, cell):
        return false
    if industry.nature.intersects_solid(
            Vector2(cell) + Vector2(0.5, 0.5), 0.35):
        return false
    return _road_connected(cell, _roads)


func build_road(cell: Vector2i) -> bool:
    # Сначала проверяем физическое место, затем единым вызовом
    # списываем три единицы уже изготовленного дорожного покрытия.
    # Повторное нажатие не расходует продукцию и не удваивает участок.
    if not can_build_road(cell) \
            or not industry.construct("участок дороги"):
        return false
    _roads[cell] = true
    # Новое покрытие может открыть более удобный дверной порт.
    # Путь активного перевозчика пересчитывается без телепортации.
    _refresh_ports()
    return true


func occupies(cell: Vector2i) -> bool:
    # Коллизия фундамента занимает одну клетку, территория — не коллизия.
    for item in _buildings:
        if Vector2i(int(item["x"]), int(item["y"])) == cell:
            return true
    return false


func within_territory(cell: Vector2i) -> bool:
    # Пока один компактный посёлок; физика миллионов NPC не нужна.
    return established() and world.config.contains_cell(cell) \
        and absi(cell.x - center.x) + absi(cell.y - center.y) <= RADIUS


func buildings() -> Array[Dictionary]:
    # UI получает копию, не может добавить бесплатное строение.
    return _buildings.duplicate(true)


func to_data() -> Dictionary:
    # Не сохраняем графические узлы или временные маршруты.
    var surfaces: Array = []
    for cell in roads():
        surfaces.append([cell.x, cell.y])
    return {"version": VERSION, "id": settlement_id,
        "center": [center.x, center.y], "buildings": buildings(),
        "roads": surfaces}


func load_data(data: Dictionary) -> bool:
    # Валидация атомарна: сначала проверяем каждое поле,
    # затем применяем весь реестр за один шаг.
    if data.get("version") != VERSION or not (data.get("id") is String) \
            or not (data.get("center") is Array) \
            or not (data.get("buildings") is Array):
        return false
    var pair: Array = data["center"]
    if pair.size() != 2 or not _whole(pair[0]) or not _whole(pair[1]):
        return false
    var cell := Vector2i(int(pair[0]), int(pair[1]))
    var expected := _id(world.config.world_seed, cell)
    if not world.config.contains_cell(cell) or str(data["id"]) != expected:
        return false
    if economy.phase == "ожидание" or economy.site != cell:
        return false
    var incoming: Array = data["buildings"]
    if incoming.size() > 2 or (economy.built and incoming.is_empty()):
        return false
    var accepted: Array[Dictionary] = []
    var workshop_count := 0
    var storage_count := 0
    var occupied := {}
    for entry in incoming:
        if not (entry is Dictionary):
            return false
        var item: Dictionary = entry
        if not _whole(item.get("x")) or not _whole(item.get("y")) \
                or item.size() != 4:
            return false
        var position := Vector2i(int(item["x"]), int(item["y"]))
        var kind := str(item.get("kind", ""))
        var suffix := ":мастерская" if kind == WORKSHOP else ":склад"
        if kind not in [WORKSHOP, STORAGE] \
                or str(item.get("id", "")) != expected + suffix \
                or occupied.has(position):
            return false
        occupied[position] = true
        if kind == WORKSHOP:
            workshop_count += 1
            if position != cell:
                return false
        else:
            storage_count += 1
            # Склад не может быть подделан без оплаченного фундамента.
            if not economy.built or industry == null \
                    or industry.site != cell \
                    or int(industry.completed.get("каменный фундамент", 0)) < 1 \
                    or absi(position.x - cell.x) \
                        + absi(position.y - cell.y) > RADIUS \
                    or not world.config.contains_cell(position) \
                    or not economy._buildable(position):
                return false
        accepted.append({"id": expected + suffix, "kind": kind,
            "x": position.x, "y": position.y})
    if workshop_count != (1 if economy.built else 0) \
            or storage_count > 1:
        return false
    # Старые сохранения не содержат roads. Новый раздел строго
    # привязан к оплате каждого участка, доступному грунту и связности.
    var roads_data: Variant = data.get("roads", [])
    if not (roads_data is Array) or roads_data.size() > MAX_ROADS:
        return false
    var candidate_roads := {}
    for pair_data in roads_data:
        if not (pair_data is Array) or pair_data.size() != 2 \
                or not _whole(pair_data[0]) or not _whole(pair_data[1]):
            return false
        var road_cell := Vector2i(int(pair_data[0]), int(pair_data[1]))
        if candidate_roads.has(road_cell) \
                or not world.config.contains_cell(road_cell) \
                or absi(road_cell.x - cell.x) + absi(road_cell.y - cell.y) > RADIUS \
                or occupied.has(road_cell):
            return false
        if industry == null or industry.site != cell \
                or not Paths.walkable(world, industry.hydro, industry.surface, road_cell) \
                or industry.nature.intersects_solid(
                    Vector2(road_cell) + Vector2(0.5, 0.5), 0.35):
            return false
        candidate_roads[road_cell] = true
    if not candidate_roads.is_empty():
        if not economy.built or industry == null \
                or int(industry.completed.get("участок дороги", 0)) \
                    < candidate_roads.size():
            return false
        # Восстанавливаем лишь одну дорогу от мастерской без островов.
        var seen := {}
        seen[cell] = true
        var queue: Array[Vector2i] = [cell]
        var cursor := 0
        while cursor < queue.size():
            var current: Vector2i = queue[cursor]
            cursor += 1
            for side in Topology.SIDES:
                var neighbor: Vector2i = current + side
                if candidate_roads.has(neighbor) and not seen.has(neighbor):
                    seen[neighbor] = true
                    queue.append(neighbor)
        if seen.size() != candidate_roads.size() + 1:
            return false
    # Не мутируем поселение до полной проверки всех построек и дорог.
    _roads.clear()
    for road_cell in candidate_roads:
        _roads[road_cell] = true
    center = cell
    settlement_id = expected
    _buildings = accepted
    _refresh_ports()
    return true
