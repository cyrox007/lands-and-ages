extends SceneTree
## Этап 11.3/V2.9: кустарники физически страдают от ветра и пыли.
## Урон, окраска, высыхание и распад не зависят от камеры и FPS.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")

var failures: Array[String] = []


func _check(valid: bool, message: String) -> void:
    # Сохраняем все ошибки, чтобы один прогон CI выявил и визуальные,
    # и физические нарушения без преждевременного завершения.
    if not valid:
        failures.append(message)


func _models(seed: int) -> Dictionary:
    # Условия берутся из настоящих географических систем, включая
    # гидрологию и влажность. События проверяются отдельно от рендера.
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


func _shrub(nature: RefCounted, day: int) -> Dictionary:
    # Для проверки выбираем куст не из очереди естественного
    # старения в выбранный день: изменение здоровья будет от ветра.
    for record in nature.to_data()["objects"]:
        if record[1] != "кустарник" or record[9] != "целое":
            continue
        var id := int(record[0])
        var x := int(record[3])
        var y := int(record[4])
        if posmod(day - id, 8) == 0:
            continue
        if x < 10 or y < 10 or x >= 86 or y >= 70:
            continue
        return nature.object_at(id)
    return {}


func _test_physical_damage() -> void:
    # Две последовательные стихии изменяют состояние одного куста:
    # сначала пыль сушит листву, затем вихрь превращает её в сухостой.
    var m: Dictionary = _models(1729)
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Природный мир содержит реальные объекты")
    var before: Dictionary = _shrub(nature, 2)
    if before.is_empty():
        _check(false, "Для проверки выбран живой кустарник")
        return
    var id: int = int(before["id"])
    var cell := Vector2i(int(before["x"]), int(before["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)
    var changed: Array[Vector2i] = []
    nature.objects_changed.connect(func(chunks: Array[Vector2i],
            _revision: int) -> void:
        changed.append_array(chunks))

    # Пылевое воздействие ограничено полосой физического ветра.
    _check(Nature.dust_reaches(Vector2(5.0, 1.0), Vector2.RIGHT)
        and not Nature.dust_reaches(Vector2(5.0, 3.0), Vector2.RIGHT)
        and not Nature.dust_reaches(Vector2(9.0, 0.0), Vector2.RIGHT)
        and not Nature.dust_reaches(Vector2.ZERO, Vector2.ZERO),
        "Пылевая полоса не повреждает удалённые объекты")

    var appearance_before: Dictionary = Renderer.shrub_appearance(before)
    _check(absf(float(appearance_before["scale"]) - 1.0) < 0.00001,
        "Здоровый куст сохраняет исходный масштаб")
    climate.set_day(2)
    nature.advance_day(2, [{
        "kind": "пыльная буря", "cell": cell,
        "severity": 1.0, "day": 2
    }])
    var dusty: Dictionary = nature.object_at(id)
    var appearance_dusty: Dictionary = Renderer.shrub_appearance(dusty)
    _check(int(dusty["health"]) == 720
        and dusty["state"] == "целое"
        and int(dusty["dead_since_day"]) == -1,
        "Пыль снижает здоровье куста, но не создаёт фиктивную древесину")
    _check(chunk in changed,
        "Повреждение куста инвалидирует природный чанк")
    _check(float(appearance_dusty["scale"]) <
        float(appearance_before["scale"])
        and appearance_dusty["tint"] != appearance_before["tint"],
        "Повреждённый куст меняет реальный масштаб и окраску")

    # Поваленное ветром дерево и погибший куст — разные сущности:
    # куст не может стать пнём или источником брёвен.
    changed.clear()
    climate.set_day(3)
    nature.advance_day(3, [{
        "kind": "ураган", "cell": cell,
        "severity": 1.0, "day": 3
    }])
    var dry: Dictionary = nature.object_at(id)
    var appearance_dry: Dictionary = Renderer.shrub_appearance(dry)
    _check(dry["state"] == "сухостой" and int(dry["health"]) == 0
        and int(dry["dead_since_day"]) == 3
        and int(dry["wood_units"]) == 0
        and int(dry["fallen_wood"]) == 0
        and int(dry["fallen_since_day"]) == -1,
        "Ветер губит куст без пня и несуществующего запаса древесины")
    _check(chunk in changed and
        float(appearance_dry["scale"]) <
            float(appearance_dusty["scale"]),
        "Погибший куст становится заметно меньше и чанк обновлён")

    # У кустарника сохраняются именно здоровье, статус и дата гибели.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    var restored := Nature.new(world, hydro, surface, climate)
    _check(restored.load_data(saved)
        and restored.object_at(id) == nature.object_at(id),
        "Сухостой и его физическое здоровье переживают JSON")

    # После установленного игрового срока сухостой исчезает
    # естественным путём. Повторное проигрывание FX не нужно.
    for day in range(4, 111):
        climate.set_day(day)
        nature.advance_day(day)
    _check(nature.object_at(id).is_empty(),
        "Спустя 96 суток погибший куст удаляется из экосистемы")


func _test_runner_and_other_objects() -> void:
    # Диагностика не меняет здоровье сама: запрос живёт до
    # следующего дня и обрабатывается штатным WorldDayRunner.
    var m: Dictionary = _models(1739)
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Кустарники созданы для игрового сценария")
    var before: Dictionary = _shrub(nature, 2)
    if before.is_empty():
        _check(false, "Для игрового сценария найден куст")
        return
    var id: int = int(before["id"])
    var cell := Vector2i(int(before["x"]), int(before["y"]))
    var lightning := Weather.new(world, climate, surface, hydro)
    var processes := Processes.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var runner := Runner.new(world, hydro, surface, climate,
        lightning, processes, disasters, nature)
    runner.test_shrub_cell = cell
    runner.run_day()

    var diagnostic_events := 0
    for event in runner.last_result["hazards"]:
        if event.get("source", "") != "диагностика":
            continue
        diagnostic_events += 1
        _check(event["kind"] == "ураган"
            and event["cell"] == cell
            and event.get("target", "") == "кустарник",
            "Испытание куста запускает настоящий физический ураган")
    _check(diagnostic_events == 1 and runner.test_shrub_cell.x < 0,
        "Запрос на испытание куста исполняется ровно один раз")
    var dry: Dictionary = nature.object_at(id)
    _check(dry["state"] == "сухостой" and int(dry["health"]) == 0,
        "Суточный Runner доводит сильный ветер до кустарника")
    for fall in runner.last_result["windfalls"]:
        _check(int(fall["before"]["id"]) != id,
            "Куст не подменяется анимацией падающего дерева")

    # Действие пыли не повреждает стволы и камни. Выбираем объект
    # вне очереди роста, чтобы результат не смешивался со старением.
    var objects: Array = nature.to_data()["objects"]
    for kind in ["дерево", "валун"]:
        var inspected: Dictionary = {}
        for record in objects:
            if record[1] != kind or posmod(3 - int(record[0]), 8) == 0:
                continue
            inspected = nature.object_at(int(record[0]))
            break
        if inspected.is_empty():
            _check(false, "Для проверки есть объект: " + kind)
            continue
        var untouched_id: int = int(inspected["id"])
        var target := Vector2i(int(inspected["x"]), int(inspected["y"]))
        climate.set_day(3)
        nature.advance_day(3, [{
            "kind": "пыльная буря", "cell": target, "severity": 1.0
        }])
        _check(nature.object_at(untouched_id)["health"] ==
            inspected["health"],
            "Пыль не снижает здоровье объекта: " + kind)
        break

    runner.run_day()
    for event in runner.last_result["hazards"]:
        _check(event.get("source", "") != "диагностика",
            "Испытание куста не повторяется без команды игрока")


func _run() -> void:
    # Каждый сценарий строит независимый физический мир, чтобы
    # порядок тестов не менял результаты и состояние сохранений.
    _test_physical_damage()
    _test_runner_and_other_objects()
    if not failures.is_empty():
        for message in failures:
            printerr("11.3/V2.9: ", message)
        quit(1)
        return
    print("11.3/V2.9: кустарники, ветер, пыль, визуал и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Графические классы загружаются в готовом SceneTree.
    call_deferred("_run")
