extends SceneTree
## Проверка этапа 10.6: формы препятствий и их смена при рубке.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Collisions = preload("res://scripts/nature_collision.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")

var errors: Array[String] = []


func _check(condition: bool, message: String) -> void:
    if not condition:
        errors.append(message)


func _make_world() -> Dictionary:
    var world := Map.new(Config.new(96, 80, 1729, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    nature.generate()
    return {"world": world, "nature": nature}


func _parts_for(body: StaticBody3D, id: int) -> Array[String]:
    var parts: Array[String] = []
    for node in body.get_children():
        if not (node is CollisionShape3D):
            continue
        if int(node.get_meta("nature_id", -1)) == id:
            parts.append(str(node.get_meta("nature_part", "")))
        _check(node.shape != null, "Коллизия должна иметь форму")
    parts.sort()
    return parts


func _run() -> void:
    var state := _make_world()
    var world: RefCounted = state["world"]
    var nature: RefCounted = state["nature"]
    _check(Collisions.near_camera(Vector2i(2, 3), Vector2i(3, 3)),
        "Соседний чанк попадает в активную физическую область")
    _check(not Collisions.near_camera(
        Vector2i(0, 0), Vector2i(3, 3)),
        "Дальний чанк не создаёт физические формы")

    var tree: Dictionary = {}
    var chunk := Vector2i(-1, -1)
    var total: int = 0
    var total_shapes: int = 0
    var chunks: Vector2i = world.config.chunk_count()
    for cy in range(chunks.y):
        for cx in range(chunks.x):
            var coord := Vector2i(cx, cy)
            var items: Array[Dictionary] = nature.objects_in_chunk(coord)
            var body: StaticBody3D = Collisions.create_chunk(
                world, nature, coord)
            _check(body.collision_layer == Collisions.COLLISION_LAYER,
                "Природа использует выделенный слой коллизий")
            _check(body.collision_mask == 0,
                "Неподвижные препятствия не требуют собственного поиска")
            _check(body.get_child_count() <= items.size() * 2,
                "На объект приходится не более двух физических форм")
            total += items.size()
            total_shapes += body.get_child_count()
            for item in items:
                var parts: Array[String] = _parts_for(body, int(item["id"]))
                if item["kind"] == "кустарник":
                    _check(parts.is_empty(),
                        "Куст не блокирует перемещение")
                elif item["kind"] == "дерево":
                    _check(parts == ["ствол"],
                        "Живое дерево блокируется только стволом")
                    if tree.is_empty():
                        tree = item
                        chunk = coord
                elif item["kind"] == "валун":
                    _check(parts == ["камень"],
                        "У камня есть собственный физический контур")
            body.free()
    _check(total == nature.count(),
        "Число объектов одинаково в реестре и чанках")
    _check(total_shapes > 0 and not tree.is_empty(),
        "Есть реальные препятствия для проверок")

    if not tree.is_empty():
        var id: int = tree["id"]
        var standing := Collisions.create_chunk(world, nature, chunk)
        _check(_parts_for(standing, id) == ["ствол"],
            "До рубки присутствует ствол")
        _check(Collisions.object_from_shape(standing, -1).is_empty(),
            "Невалидный индекс столкновения отклоняется")
        standing.free()

        var result: Dictionary = nature.fell_tree(id)
        _check(not result.is_empty() and int(result["wood_units"]) > 0,
            "Рубка создаёт конечный остаток древесины")
        var footprint: Dictionary = Geometry.log_footprint(
            nature.object_at(id), world.config)
        _check(not footprint.is_empty(),
            "Физический остаток древесины имеет координаты")
        if not footprint.is_empty():
            var center: Vector2 = footprint["center"]
            _check(Geometry.hits_log(
                center, 0.0, nature.object_at(id), world.config),
                "Лежащее бревно занимает собственный физический контур")
            _check(nature.intersects_solid(center),
                "Логическая проходимость учитывает лежащее бревно")
        var fallen := Collisions.create_chunk(world, nature, chunk)
        _check(_parts_for(fallen, id) == ["бревно", "пень"],
            "После рубки ствол заменяется пнём и бревном")
        _check(int(Collisions.object_from_shape(
            fallen, 0).get("id", -1)) > 0,
            "Обратный поиск столкновения возвращает ID природного объекта")
        fallen.free()

        var amount: int = nature.object_at(id)["fallen_wood"]
        _check(nature.take_fallen_wood(id, amount),
            "Вся лежащая древесина изымается один раз")
        var cleared := Collisions.create_chunk(world, nature, chunk)
        _check(_parts_for(cleared, id) == ["пень"],
            "После вывоза древесины физический пень остаётся")
        _check(Geometry.log_footprint(
            nature.object_at(id), world.config).is_empty(),
            "После вывоза древесины логический контур бревна исчезает")
        cleared.free()

    if not errors.is_empty():
        for message in errors:
            push_error(message)
        print("Этап 10.6: ошибок ", errors.size())
        quit(1)
        return
    print("Этап 10.6: природные коллизии проверены успешно")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
