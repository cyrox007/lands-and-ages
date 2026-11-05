extends SceneTree
## Этап 11.3: повреждение леса и ветровал без зависимости от камеры.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")
const Collisions = preload("res://scripts/nature_collision.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    # Собираем все нарушения, чтобы CI показал не только первую ошибку.
    if not ok:
        failures.append(message)


func _parts(body: StaticBody3D, id: int) -> Array[String]:
    # Проверяем фактические формы коллизии, а не название визуального меша.
    var parts: Array[String] = []
    for child in body.get_children():
        if child is CollisionShape3D and int(child.get_meta("nature_id", -1)) == id:
            parts.append(str(child.get_meta("nature_part", "")))
    parts.sort()
    return parts


func _run() -> void:
    # Небольшой детерминированный мир достаточен для проверки локального
    # воздействия, но использует настоящую гидрологию, почвы и климат.
    var seed := 1729
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
    _check(nature.generate(), "Природа создана до погодного события")

    # Ищем дерево, которое сильный шторм закономерно повалит на 3-й день.
    # Исключаем суточную очередь роста на днях 2 и 3 для точного баланса.
    var tree: Dictionary = {}
    for record in nature.to_data()["objects"]:
        var id: int = int(record[0])
        var x: int = int(record[3])
        var y: int = int(record[4])
        if record[1] != "дерево" or record[9] != "целое" or int(record[7]) <= 0:
            continue
        # Возле краёв физический ствол может обрезаться границей.
        if x < 4 or y < 4 or x >= 92 or y >= 76:
            continue
        if posmod(2 - id, 8) == 0 or posmod(3 - id, 8) == 0:
            continue
        if Terrain.hash2(x, y, seed + 3 * 31 + 3173) >= 0.85:
            continue
        tree = nature.object_at(id)
        break
    if tree.is_empty():
        failures.append("Нет подходящего дерева для воспроизводимого ветровала")
        _finish()
        return

    var tree_id: int = int(tree["id"])
    var cell := Vector2i(int(tree["x"]), int(tree["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)
    var refreshed: Array[Vector2i] = []
    nature.objects_changed.connect(func(chunks: Array[Vector2i], _revision: int) -> void:
        for place in chunks:
            refreshed.append(place))

    # Неполный урон должен обновлять чанк, даже если дерево ещё стоит.
    climate.set_day(2)
    nature.advance_day(2, [{
        "kind": "шторм", "cell": cell, "severity": 0.2
    }])
    var damaged: Dictionary = nature.object_at(tree_id)
    _check(damaged["state"] == "целое"
        and int(damaged["health"]) < int(tree["health"]),
        "Обычный шторм повреждает, но не валит дерево")
    _check(chunk in refreshed,
        "Чанк уведомлён о частичном повреждении кроны")

    var before: Dictionary = damaged.duplicate(true)
    var old_wood := int(before["wood_units"]) + int(before["fallen_wood"])
    var old_collisions := Collisions.create_chunk(world, nature, chunk)
    _check(_parts(old_collisions, tree_id) == ["ствол"],
        "До ветровала физическая коллизия содержит стоящий ствол")
    old_collisions.free()

    # Шторм 100% интенсивности повалит выбранное по seed дерево.
    # Ресурс переносится в лежащую древесину, без создания нового запаса.
    refreshed.clear()
    climate.set_day(3)
    nature.advance_day(3, [{
        "kind": "шторм", "cell": cell, "severity": 1.0
    }])
    var fallen: Dictionary = nature.object_at(tree_id)
    _check(fallen["state"] == "пень"
        and int(fallen["wood_units"]) == 0
        and int(fallen["fallen_wood"]) == old_wood,
        "Ветровал сохраняет физический баланс древесины")
    _check(int(fallen["fallen_since_day"]) == 3
        and int(fallen["dead_since_day"]) == -1,
        "Дата ветровала сохранена как состояние природы")
    # Ствол ложится по реальному локальному ветру, а не по хэшу ID.
    # Угол квантован до градуса: JSON не меняет направление коллизий.
    var direction: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(cell))
    var footprint: Dictionary = Geometry.log_footprint(fallen, world.config)
    var axis: Vector2 = footprint["axis"]
    var expected_angle := posmod(roundi(rad_to_deg(
        atan2(-direction.y, direction.x))), 360)
    _check(int(fallen.get("fall_angle_deg", -1)) == expected_angle,
        "Ветровал сохраняет угол физического ветра")
    _check(axis.dot(direction) > 0.999,
        "Физическая ось лежащего бревна совпадает с направлением ветра")
    var base := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
    var offset: Vector2 = Vector2(footprint["center"]) - base
    _check(offset.dot(direction) > 0.65,
        "Центр поваленного дерева смещён по ветру")
    _check(nature.intersects_solid(footprint["center"], 0.04),
        "Лежащий ствол реально перекрывает путь по ветру")
    _check(chunk in refreshed, "Ветровал инвалидирует рендер и коллизии")
    _check(nature.hit_tree(tree_id, 250).is_empty(),
        "Поваленное дерево нельзя повторно рубить")

    var new_collisions := Collisions.create_chunk(world, nature, chunk)
    _check(_parts(new_collisions, tree_id) == ["бревно", "пень"],
        "Коллизии дерева заменены физическими бревном и пнём")
    var oriented := false
    for shape in new_collisions.get_children():
        if not (shape is CollisionShape3D) or \
                int(shape.get_meta("nature_id", -1)) != tree_id or \
                shape.get_meta("nature_part", "") != "бревно":
            continue
        var body_axis: Vector3 = shape.transform.basis.y.normalized()
        var physical_axis := Vector3(axis.x, 0.0, axis.y)
        oriented = absf(body_axis.dot(physical_axis)) > 0.999
        break
    _check(oriented, "Коллизия бревна повторяет физический угол ветровала")
    new_collisions.free()

    # Повторная обработка дня не даёт дополнительного ветровала.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    _check(nature.advance_day(3, [{
        "kind": "шторм", "cell": cell, "severity": 1.0
    }]) == 0 and saved == JSON.parse_string(JSON.stringify(nature.to_data())),
        "Событие одного дня не применяется повторно")

    var restored := Nature.new(world, hydro, surface, climate)
    _check(restored.load_data(saved), "Ветровал восстанавливается из JSON")
    _check(restored.to_data() == nature.to_data(),
        "После загрузки совпадают деревья, ресурсы и даты")

    # Версия 3 хранила даты, но не знала направление. Старые карты
    # продолжают открываться с прежней геометрией лежащих брёвен.
    var old_snapshot: Dictionary = saved.duplicate(true)
    old_snapshot["version"] = 3
    for record in old_snapshot["objects"]:
        record.resize(13)
    var old_nature := Nature.new(world, hydro, surface, climate)
    _check(old_nature.load_data(old_snapshot),
        "Сохранение природы v3 загружается без изменения дат")
    var old_tree: Dictionary = old_nature.object_at(tree_id)
    var old_footprint: Dictionary = Geometry.log_footprint(
        old_tree, world.config)
    _check(int(old_tree.get("fall_angle_deg", 0)) == -1
        and int(old_tree["fallen_since_day"]) == 3,
        "Старый формат не изобретает направление ветровала")
    _check(absf(float(old_footprint["angle"]) -
        Geometry.angle_for(tree_id, seed)) < 0.000001,
        "Геометрия legacy-бревна остаётся прежней")

    # Отклоняем испорченные углы, не изменяя уже загруженный реестр.
    for wrong in [-2, 360, 1.25]:
        var corrupt: Dictionary = saved.duplicate(true)
        for record in corrupt["objects"]:
            if int(record[0]) == tree_id:
                record[13] = wrong
                break
        _check(not restored.load_data(corrupt),
            "Недопустимый угол ветровала должен отклоняться")
        _check(restored.to_data() == nature.to_data(),
            "Ошибочный снимок не повреждает действующий мир")
    climate.set_day(4)
    nature.advance_day(4)
    restored.advance_day(4)
    _check(restored.to_data() == nature.to_data(),
        "После восстановления продолжение природного цикла детерминировано")
    _finish()


func _finish() -> void:
    # Возвращаем ненулевой код только при доказанном нарушении инварианта.
    if not failures.is_empty():
        for message in failures:
            push_error(message)
        quit(1)
        return
    print("Этап 11.3: локальные повреждения, ветровал, коллизии и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Запуск переносим после инициализации SceneTree, как в остальных smoke.
    call_deferred("_run")
