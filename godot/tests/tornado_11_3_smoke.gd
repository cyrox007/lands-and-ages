extends SceneTree
## Этап 11.3/V2.6: смерч от климата до направленного бревна и GPU.

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
const Collisions = preload("res://scripts/nature_collision.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const FX = preload("res://scripts/weather_fx_controller.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
    # Не прекращаем проверку после первой ошибки: CI показывает все
    # нарушенные физические контракты и условия воспроизводимости.
    if not ok:
        failures.append(reason)


func _models(seed: int) -> Dictionary:
    # Создаём настоящий рельеф, водосбор и грунт. Единственный
    # искусственный фронт ниже живёт в проверке экстремальных условий.
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
    return {"world": world, "hydro": hydro,
        "surface": surface, "climate": climate}


func _test_natural_event() -> void:
    # Проверяем естественный путь: физическая гроза и сильный
    # порыв дают независимый смерч без команды из интерфейса.
    var models: Dictionary = _models(2719)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    var disasters := Disasters.new(world, hydro, surface, climate)
    var found := false
    for day in range(2, 26):
        climate.set_day(day)
        surface.advance_climate_day(climate)
        # Значения нарочно экстремальны только в тестовом мире.
        # Это проверяет механизм редкого события, не калибровку м/с.
        climate._wind.fill(30.0)
        climate._storm.fill(1.0)
        for event in disasters.advance_day(day):
            if event["kind"] != "смерч":
                continue
            found = true
            _check(int(event["duration_days"]) == 1
                and not hydro.has_water(hydro.cell_index(event["cell"])),
                "Смерч однодневный и возникает над сушей")
            break
        if found:
            break
    _check(found, "Экстремальная физическая гроза порождает смерч")
    if not found:
        return

    # Новый вид события использует прежний формат NaturalDisasters.
    # При загрузке не должны сбрасываться суточные счётчики.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(
        disasters.to_data()))
    var loaded := Disasters.new(world, hydro, surface, climate)
    _check(loaded.load_data(saved), "Смерч принимается из JSON v1")
    _check(loaded.last_day == disasters.last_day
        and loaded.total_events == disasters.total_events
        and loaded._storms == disasters._storms,
        "После загрузки сохранились время и накопленный шторм")
    var has_tornado := false
    for event in loaded.last_events:
        if event["kind"] == "смерч":
            has_tornado = true
    _check(has_tornado, "Событие смерча действительно восстановлено")


func _test_game_tornado() -> void:
    # Пользовательское испытание обязано пройти через официальный
    # суточный Runner, а не прямой вызов FX или подмену сохранения.
    var seed := 1729
    var models: Dictionary = _models(seed)
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Создан исходный лес")

    var original: Dictionary = {}
    for record in nature.to_data()["objects"]:
        var id := int(record[0])
        var x := int(record[3])
        var y := int(record[4])
        if record[1] != "дерево" or record[9] != "целое" \
                or int(record[7]) <= 0 or posmod(2 - id, 8) == 0:
            continue
        if x < 18 or y < 18 or x >= 78 or y >= 62:
            continue
        # Для двух сценариев выбираем дерево с гарантированно
        # низким порогом падения, чтобы тест не зависел от удачи.
        if Terrain.hash2(x, y, seed + 2 * 31 + 3173) >= 0.40:
            continue
        original = nature.object_at(id)
        break
    if original.is_empty():
        _check(false, "В глубине карты найдётся дерево для смерча")
        return

    var id: int = int(original["id"])
    var cell := Vector2i(int(original["x"]), int(original["y"]))
    var wood := int(original["wood_units"]) + int(original["fallen_wood"])
    var initial: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    var cloned := Nature.new(world, hydro, surface, climate)
    _check(cloned.load_data(initial),
        "Исходный лес отдельно сохранён для проверки вихревого угла")
    var before: Dictionary = {}
    for entry in nature.to_data()["objects"]:
        if entry[1] == "дерево" and entry[9] == "целое":
            before[int(entry[0])] = nature.object_at(int(entry[0]))
    var lightning := Weather.new(world, climate, surface, hydro)
    var processes := Processes.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var runner := Runner.new(world, hydro, surface, climate,
        lightning, processes, disasters, nature)
    runner.test_tornado_cell = cell
    runner.run_day()

    # На один день добавляется один типизированный hazard. Повторный
    # день без команды не должен воссоздавать предыдущий вихрь.
    var count := 0
    for event in runner.last_result["hazards"]:
        if event.get("source", "") != "диагностика":
            continue
        count += 1
        _check(event["kind"] == "смерч" and event["cell"] == cell
            and float(event["severity"]) == 1.0,
            "Игровая диагностика создаёт физический смерч")
    _check(count == 1 and runner.test_tornado_cell.x < 0,
        "Смерч запускается однократно и сбрасывает запрос")

    var fallen: Dictionary = nature.object_at(id)
    _check(fallen["state"] == "пень"
        and int(fallen["wood_units"]) == 0
        and int(fallen["fallen_wood"]) == wood
        and int(fallen["fallen_since_day"]) == 2,
        "Дерево реально повалено без создания лишней древесины")
    var axis: Vector2 = Geometry.log_footprint(
        fallen, world.config).get("axis", Vector2.ZERO)
    var wind: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(cell))
    _check(axis.dot(wind) > 0.999,
        "У оси смерча лежащий ствол направлен по потоку")

    # Узкая извилистая трасса, а не круговое поражение. Проверяем
    # различие независимых зон и поворот потока за пределами оси.
    _check(Nature.tornado_reaches(Vector2(4.0, 0.0), Vector2.RIGHT)
        and not Nature.tornado_reaches(Vector2(4.0, 5.0), Vector2.RIGHT)
        and not Nature.tornado_reaches(Vector2(13.0, 0.0), Vector2.RIGHT),
        "Вихрь оставляет узкую ограниченную полосу")
    var left := Nature.tornado_direction(
        Vector2(4.0, 1.5), Vector2.RIGHT, false)
    var right := Nature.tornado_direction(
        Vector2(4.0, 1.5), Vector2.RIGHT, true)
    _check(left.dot(right) < 0.0,
        "Противоположное вращение меняет локальный ветер")

    var offtrack_safe := false
    for other_id in before.keys():
        var old: Dictionary = before[other_id]
        if posmod(2 - int(other_id), 8) == 0:
            continue
        var offset := Vector2(int(old["x"]) - cell.x,
            int(old["y"]) - cell.y)
        if offset.length() > 13.0 or offset.length() < 2.0:
            continue
        var current: Dictionary = nature.object_at(int(other_id))
        if current.is_empty():
            continue
        if not Nature.tornado_reaches(offset, wind):
            if current["state"] == "целое" and \
                    int(current["health"]) == int(old["health"]):
                offtrack_safe = true
            continue
    _check(offtrack_safe, "Дерево рядом со следом не получает урон")

    # В редком лесу нельзя требовать, чтобы случайно стояло второе
    # дерево на полосе. Вместо этого подбираем центр вихря так,
    # чтобы выбранный ствол заведомо находился на периферии.
    var vortex_center := Vector2i(-1, -1)
    var expected := Vector2.ZERO
    for dy in range(-5, 6):
        if vortex_center.x >= 0:
            break
        for dx in range(-5, 6):
            var candidate: Vector2i = cell + Vector2i(dx, dy)
            if not world.config.contains_cell(candidate):
                continue
            var candidate_wind: Vector2 = climate.wind_direction_at_index(
                hydro.cell_index(candidate))
            var distance_to_tree := Vector2(cell - candidate)
            if distance_to_tree.length() < 2.0:
                continue
            if not Nature.tornado_reaches(distance_to_tree, candidate_wind):
                continue
            var track: Vector2 = Nature.tornado_track_offset(
                distance_to_tree, candidate_wind)
            if absf(track.y) < 0.4 or absf(track.y) > 1.1:
                continue
            var falloff := 0.25 + 0.75 * (1.0 - absf(track.y) / 2.2)
            var probability := clampf((falloff - 0.25) * 1.6, 0.0, 0.99)
            if Terrain.hash2(cell.x, cell.y,
                    seed + climate.day * 31 + 3173) >= probability:
                continue
            vortex_center = candidate
            var spin := Terrain.hash2(candidate.x, candidate.y,
                seed + climate.day * 43 + 6139) < 0.5
            expected = Nature.tornado_direction(
                distance_to_tree, candidate_wind, spin)
            break
    _check(vortex_center.x >= 0,
        "Для проверяемого дерева найдена периферийная трасса вихря")
    if vortex_center.x >= 0:
        cloned.advance_day(2, [{
            "kind": "смерч", "cell": vortex_center, "severity": 1.0
        }])
        var spun: Dictionary = cloned.object_at(id)
        var spin_shape: Dictionary = Geometry.log_footprint(
            spun, world.config)
        _check(spun["state"] == "пень" and
            Vector2(spin_shape.get("axis", Vector2.ZERO)).dot(expected) > 0.999,
            "Периферийный ствол падает по вычисленному вихревому ветру")

    var colliders := Collisions.create_chunk(
        world, nature, world.config.chunk_of(cell))
    var parts: Array[String] = []
    for part in colliders.get_children():
        if part is CollisionShape3D and int(part.get_meta(
                "nature_id", -1)) == id:
            parts.append(str(part.get_meta("nature_part", "")))
    parts.sort()
    _check(parts == ["бревно", "пень"],
        "Смерч оставляет реальное препятствие для пути")
    colliders.free()

    var fx := FX.new()
    root.add_child(fx)
    var snapshot: Dictionary = Visual.sample(climate,
        world.config, Vector2(cell), 36.0)
    var before_climate: Dictionary = climate.to_data()
    fx.show_tornado_event(1.0, wind)
    fx.apply_snapshot(snapshot, Vector2(cell), 3.0, 36.0, seed)
    var gusts: GPUParticles3D = fx.get("_gusts")
    _check(gusts != null and gusts.emitting,
        "У физического смерча есть отдельный видимый GPU-след")
    if gusts != null:
        var motion: ParticleProcessMaterial = gusts.process_material
        _check(motion.initial_velocity_max >= 38.0
            and motion.emission_box_extents.x < 18.0
            and motion.emission_box_extents.z < 18.0,
            "Смерч визуально уже и быстрее урагана")
    _check(climate.to_data() == before_climate,
        "Визуальный след не меняет климат")
    fx.set_effects_enabled(false)
    _check(gusts != null and not gusts.emitting,
        "Отключение FX скрывает только частицы")
    root.remove_child(fx)
    fx.free()

    # Только физический объект сохраняется после JSON; история
    # кратковременных анимаций на следующий запуск не переносится.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    var loaded := Nature.new(world, hydro, surface, climate)
    _check(loaded.load_data(saved) and loaded.to_data() == nature.to_data(),
        "Древесина, дата и угол смерча переживают сохранение")
    _check(loaded.last_windfalls.is_empty(),
        "Загрузка не проигрывает старый смерч повторно")
    runner.run_day()
    for event in runner.last_result["hazards"]:
        _check(event.get("source", "") != "диагностика",
            "Пробный смерч не повторяется без нового действия")


func _run() -> void:
    # Разделяем естественное возникновение и игровой путь: успешная
    # проверка одного сценария не маскирует ошибку другого.
    _test_natural_event()
    _test_game_tornado()
    if not failures.is_empty():
        for reason in failures:
            printerr("11.3/V2.6: ", reason)
        quit(1)
        return
    print("11.3/V2.6: смерч, след, вращение, лес, GPU и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # GPU-контроллер требует готового SceneTree.
    call_deferred("_run")
