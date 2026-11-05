extends SceneTree
## Профиль работы природных коллизий без графического рендера.
## Время создания физических чанков НЕ является измерением FPS на устройстве.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Collisions = preload("res://scripts/nature_collision.gd")

const REPORT_PATH := "res://tests/world-collision-profile-10.json"
const CAMERA_STEPS := 24


static func _percentile(numbers: Array[float], portion: float) -> float:
    if numbers.is_empty():
        return 0.0
    numbers.sort()
    var index := clampi(ceili(float(numbers.size()) * portion) - 1,
        0, numbers.size() - 1)
    return snappedf(numbers[index], 0.001)


func _make_world() -> Dictionary:
    # Используем текущую пилотную карту целиком, а не маленький фрагмент.
    var world := Map.new(Config.new(256, 192, 1729, 16, 64))
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


func _target_chunks(center: Vector2i, limit: Vector2i) -> Array[Vector2i]:
    var desired: Array[Vector2i] = []
    for y in range(center.y - Collisions.ACTIVE_RADIUS_CHUNKS,
            center.y + Collisions.ACTIVE_RADIUS_CHUNKS + 1):
        for x in range(center.x - Collisions.ACTIVE_RADIUS_CHUNKS,
                center.x + Collisions.ACTIVE_RADIUS_CHUNKS + 1):
            if x < 0 or y < 0 or x >= limit.x or y >= limit.y:
                continue
            desired.append(Vector2i(x, y))
    return desired


func _run() -> void:
    var started := Time.get_ticks_usec()
    var state: Dictionary = _make_world()
    var generation_ms := float(Time.get_ticks_usec() - started) / 1000.0
    var world: RefCounted = state["world"]
    var nature: RefCounted = state["nature"]
    var limit: Vector2i = world.config.chunk_count()
    var active: Dictionary = {}
    var creation_samples: Array[float] = []
    var refresh_samples: Array[float] = []
    var max_active := 0
    var max_shapes := 0
    var created := 0
    var errors: Array[String] = []
    var physics_root := Node3D.new()
    get_root().add_child(physics_root)
    var memory_before := Performance.get_monitor(Performance.MEMORY_STATIC)

    # Сначала прогреваем формы, чтобы различать холодные и повторные чанки.
    for step in range(CAMERA_STEPS):
        var center := Vector2i(
            1 + (step * 7) % maxi(1, limit.x - 2),
            1 + (step * 5) % maxi(1, limit.y - 2))
        var desired: Array[Vector2i] = _target_chunks(center, limit)
        var start_us := Time.get_ticks_usec()
        for old_chunk in active.keys():
            if old_chunk in desired:
                continue
            var old_body: StaticBody3D = active[old_chunk]
            physics_root.remove_child(old_body)
            old_body.free()
            active.erase(old_chunk)
        var built_this_frame := 0
        for chunk in desired:
            if active.has(chunk):
                continue
            if built_this_frame >= Collisions.MAX_NEW_CHUNKS_PER_FRAME:
                break
            var begin_us := Time.get_ticks_usec()
            var body := Collisions.create_chunk(world, nature, chunk)
            physics_root.add_child(body)
            creation_samples.append(
                float(Time.get_ticks_usec() - begin_us) / 1000.0)
            active[chunk] = body
            built_this_frame += 1
            created += 1
        if built_this_frame > Collisions.MAX_NEW_CHUNKS_PER_FRAME:
            errors.append("Превышен бюджет физических чанков")
        var shapes := 0
        for body in active.values():
            shapes += (body as StaticBody3D).get_child_count()
        max_active = maxi(max_active, active.size())
        max_shapes = maxi(max_shapes, shapes)
        refresh_samples.append(
            float(Time.get_ticks_usec() - start_us) / 1000.0)
        if active.size() > 9:
            errors.append("Физические тела накапливаются при перемещении камеры")
        await physics_frame

    for body in active.values():
        physics_root.remove_child(body)
        body.free()
    active.clear()
    physics_root.queue_free()
    await physics_frame
    if created == 0 or max_shapes == 0:
        errors.append("Не созданы физические препятствия")
    if not active.is_empty():
        errors.append("После перемещения остались активные коллизии")

    var result := {
        "stage": "10.7",
        "benchmark": "Коллизии при перемещении камеры, headless CPU",
        "seed": world.config.world_seed,
        "map_size": [world.config.width, world.config.height],
        "camera_steps": CAMERA_STEPS,
        "collision_chunks_created": created,
        "max_collision_chunks": max_active,
        "max_collision_shapes": max_shapes,
        "max_new_chunks_per_frame": Collisions.MAX_NEW_CHUNKS_PER_FRAME,
        "generation_ms": snappedf(generation_ms, 0.01),
        "chunk_create_ms_p50": _percentile(creation_samples.duplicate(), 0.50),
        "chunk_create_ms_p95": _percentile(creation_samples.duplicate(), 0.95),
        "chunk_create_ms_p99": _percentile(creation_samples.duplicate(), 0.99),
        "camera_update_ms_p95": _percentile(refresh_samples.duplicate(), 0.95),
        "memory_static_delta_bytes": Performance.get_monitor(
            Performance.MEMORY_STATIC) - memory_before,
        "measures_fps": false,
        "measures_android_gpu": false,
        "errors": errors
    }
    var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
    if file == null:
        push_error("Не удалось записать отчёт физических чанков")
        quit(1)
        return
    file.store_string(JSON.stringify(result, "  ") + "\n")
    file.close()
    if not errors.is_empty():
        for message in errors:
            push_error(message)
        print("Этап 10.7: ошибок физических коллизий ", errors.size())
        quit(1)
        return
    print("Этап 10.7: профиль природных коллизий готов")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
