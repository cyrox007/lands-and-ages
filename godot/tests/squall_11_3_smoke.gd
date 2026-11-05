extends SceneTree
## Этап 11.3/V2.4: сквозной шквал от климата до коллизий и GPU.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Geometry = preload("res://scripts/nature_geometry.gd")
const Collisions = preload("res://scripts/nature_collision.gd")
const Felling = preload("res://scripts/nature_felling_visual.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const FX = preload("res://scripts/weather_fx_controller.gd")

var failures: Array[String] = []


func _check(valid: bool, reason: String) -> void:
    # Не прерываемся после первого нарушения: CI покажет все симптомы.
    if not valid:
        failures.append(reason)


func _run() -> void:
    # Строим настоящий мир и все модели суточного расчёта.
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
    _check(nature.generate(), "Создан природный мир")
    var lightning := Weather.new(world, climate, surface, hydro)
    var processes := Processes.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var runner := Runner.new(world, hydro, surface, climate,
        lightning, processes, disasters, nature)

    # Отбираем дерево с гарантированным по хэшу выпадением на второй
    # день и без очереди роста: это проверяет именно ущерб шквала.
    var before: Dictionary = {}
    for record in nature.to_data()["objects"]:
        var id := int(record[0])
        var x := int(record[3])
        var y := int(record[4])
        if record[1] != "дерево" or record[9] != "целое" or int(record[7]) <= 0:
            continue
        if x < 10 or y < 10 or x >= 86 or y >= 70:
            continue
        if posmod(2 - id, 8) == 0 or Terrain.hash2(x, y,
                seed + 2 * 31 + 3173) >= 0.95:
            continue
        before = nature.object_at(id)
        break
    if before.is_empty():
        _check(false, "Есть доступное дерево для направленного шквала")
        _finish()
        return

    var id: int = int(before["id"])
    var cell := Vector2i(int(before["x"]), int(before["y"]))
    var old_wood := int(before["wood_units"]) + int(before["fallen_wood"])
    var chunk: Vector2i = world.config.chunk_of(cell)
    var changed_chunks: Array[Vector2i] = []
    nature.objects_changed.connect(func(chunks: Array[Vector2i],
            _revision: int) -> void:
        changed_chunks.append_array(chunks))

    # Диагностическое событие должно войти в обычный Runner, а не
    # вызывать метод повреждения леса напрямую из визуального теста.
    runner.test_squall_cell = cell
    runner.run_day()
    var hazards: Array[Dictionary] = runner.last_result["hazards"]
    var trials := 0
    for event in hazards:
        if event.get("source", "") == "диагностика":
            trials += 1
            _check(event["kind"] == "шквал" and event["cell"] == cell
                and float(event["severity"]) == 1.0,
                "Диагностика создаёт настоящий однодневный шквал")
    _check(trials == 1 and runner.test_squall_cell.x < 0,
        "Событие однократно и сбрасывает команду")

    var fallen: Dictionary = nature.object_at(id)
    var direction: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(cell))
    var shape: Dictionary = Geometry.log_footprint(fallen, world.config)
    _check(fallen.get("state", "") == "пень"
        and int(fallen.get("wood_units", -1)) == 0
        and int(fallen.get("fallen_wood", -1)) == old_wood,
        "Шквал валит дерево и не дублирует древесину")
    _check(not shape.is_empty() and
        Vector2(shape.get("axis", Vector2.ZERO)).dot(direction) > 0.999,
        "Ствол и физическая геометрия ориентированы по ветру")
    _check(chunk in changed_chunks,
        "Физический ущерб инвалидирует природный чанк")
    var colliders := Collisions.create_chunk(world, nature, chunk)
    var parts: Array[String] = []
    for node in colliders.get_children():
        if node is CollisionShape3D \
                and int(node.get_meta("nature_id", -1)) == id:
            parts.append(str(node.get_meta("nature_part", "")))
    parts.sort()
    _check(parts == ["бревно", "пень"],
        "Поваленное шквалом дерево имеет бревно и пень")
    colliders.free()

    # Главный поток может анимировать только реальные переходы,
    # полученные из фонового физического расчёта.
    var visualized := false
    for entry in runner.last_result["windfalls"]:
        if int(entry["before"]["id"]) != id:
            continue
        var visual: Node3D = Felling.make_visual(world,
            entry["before"], 1.0, false, int(entry["fall_angle_deg"]))
        visualized = visual != null
        if visual != null:
            _check(int(entry["fall_angle_deg"]) == int(fallen["fall_angle_deg"]),
                "Угол анимации совпадает с состоянием мира")
            visual.free()
        break
    _check(visualized, "Фоновая физика передаёт переход для анимации")

    # Графический порыв ограничен временем и использует климатический
    # вектор, не меняя физическую силу ветра или снимки сохранения.
    var fx := FX.new()
    root.add_child(fx)
    var snapshot: Dictionary = Visual.sample(
        climate, world.config, Vector2(cell), 36.0)
    var climate_before: Dictionary = climate.to_data()
    fx.show_squall_event(1.0, direction)
    fx.apply_snapshot(snapshot, Vector2(cell), 3.0, 36.0, seed)
    var gusts: GPUParticles3D = fx.get("_gusts")
    _check(gusts != null and gusts.emitting,
        "Шквал отображает отдельные направленные порывы")
    if gusts != null:
        var motion: ParticleProcessMaterial = gusts.process_material
        _check(Vector2(motion.direction.x, motion.direction.z).dot(
            direction) > 0.999, "GPU-порывы движутся по ветру")
        _check(motion.initial_velocity_max > 18.0 and
            motion.emission_box_extents.z < 36.0,
            "Шквал визуально быстрее и уже обычного шторма")
    _check(climate.to_data() == climate_before,
        "Графика не меняет физический климат")
    fx.set_effects_enabled(false)
    _check(gusts != null and not gusts.emitting,
        "Кнопка отключения FX выключает и шквал")
    root.remove_child(fx)
    fx.free()

    # После JSON коллизия и ориентированная древесина не пропадают.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    var restored := Nature.new(world, hydro, surface, climate)
    _check(restored.load_data(saved) and restored.to_data() == nature.to_data(),
        "Ветровал шквала переживает сохранение и загрузку")
    runner.run_day()
    var repeated := false
    for event in runner.last_result["hazards"]:
        if event.get("source", "") == "диагностика":
            repeated = true
    _check(not repeated, "Диагностический шквал не повторяется")
    _finish()


func _finish() -> void:
    # Нулевой код даём только после всех проверок физики и графики.
    if not failures.is_empty():
        for reason in failures:
            printerr("11.3/V2.4: ", reason)
        quit(1)
        return
    print("11.3/V2.4: физический шквал, коллизии, анимация, FX и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # GPU-узлы создаются после инициализации SceneTree.
    call_deferred("_run")
