extends SceneTree
## 11.5/F2: сохраняемая гарь, пепел, последствия и восстановление.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(valid: bool, message: String) -> void:
    # Не прекращаем проверку при первой ошибке, чтобы видеть
    # все нарушения последствий и старых сохранений в одном CI.
    if not valid:
        failures.append(message)


func _models(seed: int) -> Dictionary:
    # Создаём обычные мировые системы; тест изменяет только погоду.
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
    _check(nature.generate(), "Создана реальная растительность мира")
    var fire := Fire.new(world, hydro, surface, climate, nature)
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire
    }


func _tree(nature: RefCounted) -> Dictionary:
    # Взрослый древесный запас даёт несколько суток горения.
    # Края карты исключаем для устойчивого теста чанков.
    for record in nature.to_data()["objects"]:
        if record[1] != "дерево" or record[9] != "целое":
            continue
        var x := int(record[3])
        var y := int(record[4])
        if x < 10 or y < 10 or x >= 86 or y >= 70 \
                or int(record[7]) < 35:
            continue
        return nature.object_at(int(record[0]))
    return {}


func _day(m: Dictionary, day: int, moisture: float) -> void:
    # Все переходы проходят через игровой календарь и поверхность,
    # а не через визуальное время или отдельный флаг «излечено».
    var climate: RefCounted = m["climate"]
    var surface: RefCounted = m["surface"]
    var nature: RefCounted = m["nature"]
    climate.set_day(day)
    _check(surface.advance_climate_day(climate),
        "Климатическое состояние перешло в день %d" % day)
    surface._moisture.fill(moisture)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    nature.advance_day(day)


func _test_persistent_ash() -> void:
    # Сначала поджигаем дерево, затем расходуем древесину.
    # След возникает только при настоящем горении в следующий день.
    var m: Dictionary = _models(1729)
    var world: RefCounted = m["world"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var chosen: Dictionary = _tree(nature)
    if chosen.is_empty():
        _check(false, "Найден горючий взрослый ствол")
        return
    var id := int(chosen["id"])
    var cell := Vector2i(int(chosen["x"]), int(chosen["y"]))
    var chunk := world.config.chunk_of(cell)
    var dirty: Array[Vector2i] = []
    nature.objects_changed.connect(func(chunks: Array[Vector2i],
            _revision: int) -> void:
        dirty.append_array(chunks))

    _day(m, 2, 0.02)
    fire.advance_day(2, [], cell)
    _check(fire.is_burning(id) and fire.scorched_count() == 0,
        "Одно возгорание не создаёт гарь до расходования топлива")
    var initial: float = fire._flammability(cell)

    _day(m, 3, 0.02)
    var wood_before: int = nature.wood_total()
    fire.advance_day(3)
    var severity: float = fire.scorched_at(cell)
    _check(severity > 0.2 and severity <= 1.0
        and fire.scorched_count() > 0,
        "После физического горения появился ограниченный пепел")
    _check(nature.wood_total() < wood_before,
        "Пепел образуется при действительном расходе древесины")
    _check(chunk in dirty,
        "Гарь оповещает визуальную систему об изменённом чанке")
    _check(fire._flammability(cell) < initial,
        "Выжженная земля снижает вероятность нового возгорания")

    var visible: Node3D = Renderer.create_chunk(world, nature, chunk,
        1.0, fire)
    _check(visible.get_node_or_null("гарь") != null,
        "Видимый чанк показывает физический пепел")
    visible.free()

    # В общий сейв попадают и объекты природы, и отдельный
    # реестр последствий, но не временные частицы/анимации.
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty() and snapshot.has("fire"),
        "Общий сохранённый мир содержит реальные следы пожара")
    if not snapshot.is_empty():
        var restored: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not restored.is_empty(),
            "Весь мир с гарью загружается из JSON")
        if not restored.is_empty():
            var loaded_fire: RefCounted = restored["fire"]
            _check(loaded_fire.to_data() == fire.to_data()
                and absf(loaded_fire.scorched_at(cell) - severity) < 0.00001,
                "Повторная загрузка сохраняет пепел и день выгорания")

    # Старый снимок F1 содержит только горящие деревья. Не
    # изобретаем пепел при миграции формата 1 -> 2.
    var old_snapshot: Dictionary = fire.to_data().duplicate(true)
    old_snapshot["version"] = 1
    old_snapshot.erase("scorched")
    var legacy := Fire.new(world, hydro, surface, climate, nature)
    _check(legacy.load_data(old_snapshot)
        and legacy.scorched_count() == 0
        and legacy.burning_count() == fire.burning_count(),
        "Сохранение пожаров v1 остаётся совместимым")

    var safe: Dictionary = fire.to_data()
    var damaged: Dictionary = safe.duplicate(true)
    var first: Array = damaged["scorched"][0]
    damaged["scorched"].append(first.duplicate())
    _check(not fire.load_data(damaged) and fire.to_data() == safe,
        "Дублированный участок не повреждает действующий реестр")
    var invalid: Dictionary = safe.duplicate(true)
    invalid["scorched"][0][1] = 1001
    _check(not fire.load_data(invalid) and fire.to_data() == safe,
        "Недопустимое количество пепла отклоняется без частичной загрузки")

    # Заливаем участок дождём: горение гаснет, след остаётся.
    _day(m, 4, 1.0)
    fire.advance_day(4)
    var after_rain: float = fire.scorched_at(cell)
    _check(not fire.is_burning(id) and after_rain > 0.0
        and after_rain < severity,
        "Дождь тушит пламя, но не стирает гарь мгновенно")
    var rainy_visual: Node3D = Renderer.create_chunk(world, nature,
        chunk, 1.0, fire)
    _check(rainy_visual.get_node_or_null("пламя") == null
        and rainy_visual.get_node_or_null("гарь") != null,
        "После тушения пепел виден без живого пламени")
    rainy_visual.free()
    var fixed_day: Dictionary = fire.to_data()
    _check(fire.advance_day(4).is_empty()
        and fixed_day == fire.to_data(),
        "Повторные расчёты одной даты не ускоряют восстановление")

    # Пепел уходит только за игровые сутки. Проверяем длительное
    # восстановление, не меняя рельеф или распределение ресурсов.
    for day in range(5, 110):
        _day(m, day, 0.42)
        fire.advance_day(day)
    _check(fire.scorched_at(cell) == 0.0
        and fire.scorched_count() == 0,
        "Природное восстановление полностью удаляет пепел за сезон")
    var grown_visual: Node3D = Renderer.create_chunk(world, nature,
        chunk, 1.0, fire)
    _check(grown_visual.get_node_or_null("гарь") == null,
        "После восстановления на карте нет старого пятна гари")
    grown_visual.free()


func _run() -> void:
    # Смоук проверяет последствия после исчезновения огня,
    # а не только наличие чёрной картинки при пожаре.
    _test_persistent_ash()
    if not failures.is_empty():
        for failure in failures:
            printerr("11.5/F2: ", failure)
        quit(1)
        return
    print("11.5/F2: гарь, пепел, JSON, тушение и восстановление — успешно")
    quit(0)


func _initialize() -> void:
    # Реальные MultiMesh-узлы доступны после инициализации SceneTree.
    call_deferred("_run")
