extends SceneTree
## Интеграционная регрессия этапа 10 без визуальной и аппаратной приёмки.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Collisions = preload("res://scripts/nature_collision.gd")

var errors: Array[String] = []


func _check(ok: bool, message: String) -> void:
    if not ok:
        errors.append(message)


func _world(seed: int) -> Dictionary:
    var world := Map.new(Config.new(96, 80, seed, 16, 32))
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
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature
    }


func _tree(nature: RefCounted, world: RefCounted) -> Dictionary:
    var count: Vector2i = world.config.chunk_count()
    for cy in range(count.y):
        for cx in range(count.x):
            for item in nature.objects_in_chunk(Vector2i(cx, cy)):
                if item["kind"] != "дерево" or item["state"] != "целое":
                    continue
                if int(item["wood_units"]) > 0:
                    return item
    return {}


func _parts(body: StaticBody3D, id: int) -> Array[String]:
    var parts: Array[String] = []
    for child in body.get_children():
        if child is CollisionShape3D                 and int(child.get_meta("nature_id", -1)) == id:
            parts.append(str(child.get_meta("nature_part", "")))
    parts.sort()
    return parts


func _verify(seed: int) -> void:
    var state: Dictionary = _world(seed)
    var world: RefCounted = state["world"]
    var nature: RefCounted = state["nature"]
    var tree: Dictionary = _tree(nature, world)
    if tree.is_empty():
        errors.append("Нет дерева с древесиной для seed %d" % seed)
        return

    var id: int = int(tree["id"])
    var chunk: Vector2i = world.config.chunk_of(Vector2i(
        int(tree["x"]), int(tree["y"])))
    var total_before: int = nature.wood_total()
    var wood_before: int = int(tree["wood_units"])
    var felled_events: Array[int] = []
    nature.tree_felled.connect(func(before: Dictionary) -> void:
        felled_events.append(int(before["id"])))

    var standing := Collisions.create_chunk(world, nature, chunk)
    _check(_parts(standing, id) == ["ствол"],
        "До валки есть ствол: seed %d" % seed)
    standing.free()

    for expected in [250, 500, 750]:
        var hit: Dictionary = nature.hit_tree(id, 250)
        _check(int(hit.get("cut_progress", -1)) == expected,
            "Удары не накапливаются: seed %d" % seed)
        _check(nature.wood_total() == total_before,
            "Удары изменили запас древесины: seed %d" % seed)

    # Проверяем сериализацию именно между ударами и окончательной валкой.
    var snapshot: Dictionary = JSON.parse_string(
        JSON.stringify(nature.to_data()))
    var restored := Nature.new(world, state["hydro"],
        state["surface"], state["climate"])
    _check(restored.load_data(snapshot),
        "Промежуточный снимок не загружается: seed %d" % seed)
    if restored.object_at(id).is_empty():
        errors.append("Дерево потеряно при загрузке: seed %d" % seed)
        return
    _check(int(restored.object_at(id)["cut_progress"]) == 750,
        "Повреждение не сохранилось: seed %d" % seed)
    _check(restored.wood_total() == total_before,
        "Снимок удвоил древесину: seed %d" % seed)

    var last_hit: Dictionary = nature.hit_tree(id, 250)
    var restored_hit: Dictionary = restored.hit_tree(id, 250)
    _check(bool(last_hit.get("felled", false))         and bool(restored_hit.get("felled", false)),
        "Последний удар не завершает валку: seed %d" % seed)
    _check(felled_events == [id],
        "Физическое событие валки должно быть одно: seed %d" % seed)
    _check(nature.hit_tree(id, 250).is_empty()         and nature.fell_tree(id).is_empty(),
        "Повторная валка допустима: seed %d" % seed)
    _check(nature.to_data() == restored.to_data(),
        "Положение камеры/загрузка изменили физику: seed %d" % seed)
    _check(nature.wood_total() == total_before,
        "Валка создала или уничтожила ресурс: seed %d" % seed)
    _check(int(nature.resource_stock(id)["resources"]["wood"]["available"])         == wood_before,
        "Лежащий ресурс недоступен после валки: seed %d" % seed)

    var fallen := Collisions.create_chunk(world, nature, chunk)
    _check(_parts(fallen, id) == ["бревно", "пень"],
        "После валки не изменились препятствия: seed %d" % seed)
    fallen.free()

    var point_count := nature.interaction_points(id).size()
    _check(point_count <= 4,
        "Недопустимое число точек подхода: seed %d" % seed)
    for point in nature.interaction_points(id):
        var cell: Vector2i = world.config.cell_at(point)
        var index: int = state["hydro"].cell_index(cell)
        _check(not state["hydro"].has_water(index)             and not state["hydro"].flooded_at(index),
            "Точка взаимодействия в воде: seed %d" % seed)
        _check(not nature.intersects_solid(point, 0.08, id),
            "Точка взаимодействия пересекает препятствие: seed %d" % seed)

    _check(nature.take_raw_resource(id, "wood", wood_before),
        "Древесину нельзя изъять: seed %d" % seed)
    _check(not nature.take_raw_resource(id, "wood", 1),
        "Повторная выдача древесины: seed %d" % seed)
    _check(nature.wood_total() == total_before - wood_before,
        "Расход древесины не отражён в балансе: seed %d" % seed)
    var cleared := Collisions.create_chunk(world, nature, chunk)
    _check(_parts(cleared, id) == ["пень"],
        "Вывоз древесины не освободил место бревна: seed %d" % seed)
    cleared.free()

    var final_snapshot: Dictionary = JSON.parse_string(
        JSON.stringify(nature.to_data()))
    _check(restored.load_data(final_snapshot),
        "Итоговый снимок не загружается: seed %d" % seed)
    _check(restored.to_data() == nature.to_data(),
        "После восстановления ресурсы изменились: seed %d" % seed)


func _run() -> void:
    for seed in [1729, 1802, 2532, 2824]:
        _verify(seed)
    if not errors.is_empty():
        for message in errors:
            push_error(message)
        quit(1)
        return
    print("Этап 10.7: интеграция природы, коллизий и ресурсов проверена")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
