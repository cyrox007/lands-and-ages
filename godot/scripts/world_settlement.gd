extends RefCounted
## Постоянное поселение этапа 13; право на мастерскую подтверждает Economy.

const VERSION := 1
const RADIUS := 9
const WORKSHOP := "кирпичная мастерская"
const STORAGE := "малый склад"

var world: RefCounted
var economy: RefCounted
var industry: RefCounted
var settlement_id := ""
var center := Vector2i(-1, -1)
var _buildings: Array[Dictionary] = []


func _init(map: RefCounted, first_economy: RefCounted,
        production: RefCounted = null) -> void:
    # Не дублируем реестр глины, леса и кирпичей.
    world = map
    economy = first_economy
    industry = production


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
    return {"version": VERSION, "id": settlement_id,
        "center": [center.x, center.y], "buildings": buildings()}


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
    # Отрицательный тест не должен менять уже существующее поселение.
    center = cell
    settlement_id = expected
    _buildings = accepted
    return true
