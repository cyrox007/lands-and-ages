extends SceneTree
## Этап 11.3/V2.5: ураган — протяжённый фронт, вращение, лес и JSON.
## Проверяется реальная игровая цепочка, а не отдельная иллюстрация.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const FX = preload("res://scripts/weather_fx_controller.gd")
const Collisions = preload("res://scripts/nature_collision.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    # Сохраняем все нарушения, чтобы не перезапускать длинный CI
    # после исправления каждого отдельного условия.
    if not ok:
        failures.append(message)


func _models(seed: int) -> Dictionary:
    # Создаём одну настоящую географию с климатом и грунтом,
    # не подменяя игровую гидрологию графическими объектами.
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
    return {
        "world": world, "hydro": hydro,
        "surface": surface, "climate": climate
    }


func _test_automatic_hurricane() -> void:
    # Воспроизводим сильный многодневный фронт внутри настоящей
    # модели Climate. В обычном мире такого фронта не навязываем:
    # эти крайние значения существуют только в контрольном тесте.
    var models: Dictionary = _models(2719)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    var disasters := Disasters.new(world, hydro, surface, climate)

    # Уже четыре дня назад был устойчивый шторм. Только на пятый
    # день сильного фронта допускаем развитие урагана.
    disasters._storms.fill(3)
    for day in [2, 3]:
        climate.set_day(day)
        surface.advance_climate_day(climate)
        climate._wind.fill(24.0)
        climate._storm.fill(1.0)
        var sample: Dictionary = disasters.conditions_at(Vector2i(24, 24),
            false)
        _check(float(sample["ураган"]) >= 0.65,
            "Фронт с высокой скоростью и грозой опасен")
        var events: Array[Dictionary] = disasters.advance_day(day)
        var found := false
        for event in events:
            if event["kind"] == "ураган":
                found = true
                _check(int(event["duration_days"]) == 5,
                    "Ураган возникает после пяти штормовых суток")
        _check(found == (day == 3),
            "Нельзя объявлять ураган до пятого дня сильного фронта")

    # Сохраняем новое событие в старом девятипольном формате:
    # изменение набора типов не требует миграции JSON.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(
        disasters.to_data()))
    var restored := Disasters.new(world, hydro, surface, climate)
    var loaded_ok: bool = restored.load_data(saved)
    _check(loaded_ok, "Сохранение бедствий с ураганом принимается")
    if loaded_ok:
        _check(restored.last_day == disasters.last_day
            and restored.total_events == disasters.total_events,
            "После JSON совпадают счётчики и дата бедствий")
        _check(restored._storms == disasters._storms,
            "Серия штормовых суток восстановлена без потери истории")
        _check(restored.last_events == disasters.last_events,
            "События урагана восстановлены без изменения вида и клеток")
    _check(restored.advance_day(3).is_empty(),
        "Повторное применение того же дня не создаёт второй ураган")
    climate.set_day(4)
    surface.advance_climate_day(climate)
    climate._wind.fill(24.0)
    climate._storm.fill(1.0)
    for event in restored.advance_day(4):
        _check(event["kind"] != "ураган",
            "Одна штормовая серия не создаёт ураган ежедневно")


func _test_game_hurricane() -> void:
    # Прогоняем пробное событие через Runner, NatureRegistry и FX.
    # Модели сохраняют последствия даже при отключённой анимации.
    var seed := 1729
    var models: Dictionary = _models(seed)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Физический лес создан")

    var target: Dictionary = {}
    for record in nature.to_data()["objects"]:
        var id := int(record[0])
        var x := int(record[3])
        var y := int(record[4])
        if record[1] != "дерево" or record[9] != "целое" \
                or int(record[7]) <= 0 or posmod(2 - id, 8) == 0:
            continue
        if x < 18 or y < 18 or x >= 78 or y >= 62:
            continue
        if Terrain.hash2(x, y, seed + 2 * 31 + 3173) >= 0.98:
            continue
        target = nature.object_at(id)
        break
    if target.is_empty():
        _check(false, "Для урагана найдено дерево в глубине карты")
        return

    var cell := Vector2i(int(target["x"]), int(target["y"]))
    var center := Vector2(cell)
    var id: int = int(target["id"])
    var balance := int(target["wood_units"]) + int(target["fallen_wood"])
    var before: Dictionary = {}
    for item in nature.to_data()["objects"]:
        if item[1] == "дерево" and item[9] == "целое":
            before[int(item[0])] = nature.object_at(int(item[0]))
    var weather := Weather.new(world, climate, surface, hydro)
    var processes := Processes.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var runner := Runner.new(world, hydro, surface, climate,
        weather, processes, disasters, nature)
    runner.test_hurricane_cell = cell
    runner.run_day()

    # Исключительно один реальный hazard входит в суточную физику,
    # а команда испытания сбрасывается сразу после использования.
    var trials := 0
    for event in runner.last_result["hazards"]:
        if event.get("source", "") != "диагностика":
            continue
        trials += 1
        _check(event["kind"] == "ураган" and event["cell"] == cell
            and float(event["severity"]) == 1.0,
            "Диагностика добавляет именно физический ураган")
    _check(trials == 1 and runner.test_hurricane_cell.x < 0,
        "Пробное событие сбрасывается после одного дня")

    var fallen: Dictionary = nature.object_at(id)
    _check(fallen["state"] == "пень"
        and int(fallen["wood_units"]) == 0
        and int(fallen["fallen_wood"]) == balance
        and int(fallen["fallen_since_day"]) == 2,
        "Ураган переносит древесину в лежащий ресурс без потерь")
    var chunk: Vector2i = world.config.chunk_of(cell)
    var colliders := Collisions.create_chunk(world, nature, chunk)
    var parts: Array[String] = []
    for part in colliders.get_children():
        if part is CollisionShape3D and int(part.get_meta(
                "nature_id", -1)) == id:
            parts.append(str(part.get_meta("nature_part", "")))
    parts.sort()
    _check(parts == ["бревно", "пень"],
        "После урагана есть настоящее препятствие и пень")
    colliders.free()

    # Границу проверяем на реальных деревьях: в центре ущерб
    # выше, на удалении 7–13 клеток он меньше, а вне 14 его нет.
    var outer_damaged := false
    var far_unchanged := false
    var rotated_fall := false
    var front: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(cell))
    var clockwise := Terrain.hash2(cell.x, cell.y,
        seed + climate.day * 41 + 9421) < 0.5
    for other_id in before.keys():
        var old: Dictionary = before[other_id]
        if posmod(2 - int(other_id), 8) == 0:
            continue
        var offset := Vector2(int(old["x"]) - cell.x,
            int(old["y"]) - cell.y)
        var dist := offset.length()
        var current: Dictionary = nature.object_at(int(other_id))
        if current.is_empty():
            continue
        if dist >= 7.0 and dist <= 13.0:
            if int(current["health"]) < int(old["health"]) \
                    or current["state"] == "пень":
                outer_damaged = true
        if dist >= 17.0 and dist <= 20.0 and \
                current["state"] == old["state"] and \
                int(current["health"]) == int(old["health"]):
            far_unchanged = true
        if dist < 2.0 or dist > 11.0 or current["state"] != "пень":
            continue
        var direction: Vector2 = Nature.hurricane_direction(
            offset, front, clockwise)
        var shape: Dictionary = Geometry.log_footprint(
            current, world.config)
        if not shape.is_empty() and Vector2(shape["axis"]).dot(
                direction) > 0.999:
            rotated_fall = true
    _check(outer_damaged, "Ураган достигает деревьев дальше радиуса шторма")
    _check(far_unchanged, "За пределами урагана дерево остаётся невредимым")
    _check(rotated_fall,
        "Падение на периферии согласовано с касательным вращением")
    _check(Nature.hurricane_direction(Vector2(4, 0),
        Vector2.RIGHT, false).y > 0.75
        and Nature.hurricane_direction(Vector2(4, 0),
            Vector2.RIGHT, true).y < -0.75,
        "Две стороны вращения дают противоположные направления")

    # GPU-порывы шире и быстрее обычного шторма, но не меняют
    # данные климата, физическое дерево и источник бедствия.
    var fx := FX.new()
    root.add_child(fx)
    var snapshot: Dictionary = Visual.sample(climate,
        world.config, Vector2(cell), 36.0)
    var climate_before: Dictionary = climate.to_data()
    fx.show_hurricane_event(1.0, front)
    fx.apply_snapshot(snapshot, Vector2(cell), 3.0, 36.0, seed)
    var gusts: GPUParticles3D = fx.get("_gusts")
    _check(gusts != null and gusts.emitting,
        "Ураган включает видимые направленные GPU-порывы")
    if gusts != null:
        var motion: ParticleProcessMaterial = gusts.process_material
        _check(motion.initial_velocity_max >= 34.0
            and motion.emission_box_extents.z > 20.0,
            "Ураган имеет широкую область быстрых порывов")
    _check(climate.to_data() == climate_before,
        "Визуальное усиление не меняет физический климат")
    fx.set_effects_enabled(false)
    _check(gusts != null and not gusts.emitting,
        "Отключение FX скрывает только графику урагана")
    root.remove_child(fx)
    fx.free()

    var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    var restored := Nature.new(world, hydro, surface, climate)
    _check(restored.load_data(saved) and restored.to_data() == nature.to_data(),
        "Ураганный ветровал и коллизии сохраняются в JSON")
    runner.run_day()
    for event in runner.last_result["hazards"]:
        _check(event.get("source", "") != "диагностика",
            "Ураган не запускается повторно без действия игрока")


func _run() -> void:
    # Сначала тестируем естественный фронт, затем игровой сценарий.
    # Каждый тест создаёт отдельный мир без общих изменяемых данных.
    _test_automatic_hurricane()
    _test_game_hurricane()
    if not failures.is_empty():
        for reason in failures:
            printerr("11.3/V2.5: ", reason)
        quit(1)
        return
    print("11.3/V2.5: ураган, вращение, лес, FX, JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Запускаем после создания SceneTree и возможности добавить GPU-узлы.
    call_deferred("_run")
