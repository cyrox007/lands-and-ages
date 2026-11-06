extends SceneTree
## 11.5/F3: подстилка тлеет вне камеры, расходует запас и переживает JSON.

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


func _check(ok: bool, message: String) -> void:
    # Собираем ошибки всех этапов: зарождение, тление, влага,
    # внешний вид и сохранения проверяются раздельно.
    if not ok:
        failures.append(message)


func _models() -> Dictionary:
    # Источник огня — реальная природа, а не тестовый список ID.
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
    _check(nature.generate(), "Горючая растительность реально сгенерирована")
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _tree(nature: RefCounted) -> Dictionary:
    # Берём взрослый ствол внутри карты, способный оставить
    # растительную подстилку после выгорания.
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
    # Промежуточные сутки проходит вся почва и природный реестр:
    # прямой вызов F3 не должен обходить календарь мира.
    var climate: RefCounted = m["climate"]
    var surface: RefCounted = m["surface"]
    var nature: RefCounted = m["nature"]
    climate.set_day(day)
    _check(surface.advance_climate_day(climate),
        "Поверхность пересчитана на день %d" % day)
    surface._moisture.fill(moisture)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    nature.advance_day(day)


func _test_smolder() -> void:
    # Пламя сначала загорается на дереве и лишь при фактическом
    # расходовании топлива передаёт жар наземной подстилке.
    var m: Dictionary = _models()
    var world: RefCounted = m["world"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var chosen: Dictionary = _tree(nature)
    if chosen.is_empty():
        _check(false, "Найдено взрослое дерево для F3")
        return
    var id := int(chosen["id"])
    var cell := Vector2i(int(chosen["x"]), int(chosen["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)

    _day(m, 2, 0.02)
    fire.advance_day(2, [], cell)
    _check(fire.is_burning(id) and fire.smolder_count() == 0,
        "Одно возгорание ещё не расходует подстилку")

    _day(m, 3, 0.02)
    fire.advance_day(3)
    _check(fire.smolder_count() >= 1 and fire.is_smoldering(cell),
        "Расход древесины поджигает существующую лесную подстилку")
    var initial: Dictionary = fire.to_data()
    _check(int(initial["version"]) == 6
        and initial["embers"].size() >= 1,
        "Подстилка имеет самостоятельный конечный запас топлива")

    var embers_view: Node3D = Renderer.create_chunk(
        world, nature, chunk, 1.0, fire)
    _check(embers_view.get_node_or_null("угли") != null,
        "Горячая подстилка видна без отдельных сценовых объектов")
    embers_view.free()

    # Миграция F2 сохраняет пепел и старое пламя, но не изобретает
    # угли, которых в старой версии физического формата не было.
    var legacy_data: Dictionary = initial.duplicate(true)
    legacy_data["version"] = 2
    legacy_data.erase("embers")
    var older := Fire.new(m["world"], m["hydro"], m["surface"],
        m["climate"], m["nature"])
    _check(older.load_data(legacy_data)
        and older.smolder_count() == 0
        and older.scorched_count() == fire.scorched_count(),
        "Старый формат F2 мигрирует без ложного тления")

    # Не допускаем испорченных или дублированных индексов. Проверка
    # должна завершиться до подмены уже существующих физических очагов.
    var broken: Dictionary = initial.duplicate(true)
    broken["embers"].append(broken["embers"][0].duplicate())
    _check(not fire.load_data(broken)
        and fire.to_data() == initial,
        "Дубликат тлеющей клетки не портит мир")
    var invalid: Dictionary = initial.duplicate(true)
    invalid["embers"][0][1] = 99999
    _check(not fire.load_data(invalid)
        and fire.to_data() == initial,
        "Неограниченный запас топлива отклоняется")

    # Проверяем восстановление целого мира вместе с углями:
    # сохраняются и природные объекты, и пожарный реестр v3.
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
        "Общий JSON включает слой тлеющей подстилки")
    if not snapshot.is_empty():
        var loaded: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not loaded.is_empty(),
            "Сохранённый пожарный мир F3 можно полностью загрузить")
        if not loaded.is_empty():
            _check(loaded["fire"].to_data() == fire.to_data()
                and loaded["fire"].is_smoldering(cell),
                "Повторная загрузка сохраняет топливо и активные угли")

    # Ветер меняет вероятность лишь по потоку. Мокрая клетка
    # имеет нулевой шанс, даже при максимальном порыве.
    var down: float = Fire.litter_spread_chance(1.0, 40.0, 1.0)
    var cross: float = Fire.litter_spread_chance(1.0, 40.0, 0.0)
    var up: float = Fire.litter_spread_chance(1.0, 40.0, -1.0)
    _check(down > cross and cross > up
        and up == 0.0
        and Fire.litter_spread_chance(0.0, 60.0, 1.0) == 0.0,
        "Попутный ветер помогает переносу, вода и встречный — нет")

    # Второй день тления списывает именно сохранённый запас,
    # а вновь зажжённая соседняя клетка не тратит его дважды.
    _day(m, 4, 0.02)
    var fuel_before: int = int(initial["embers"][0][1])
    var events: Array[Dictionary] = fire.advance_day(4)
    var fuel_after := 0
    for entry in fire.to_data()["embers"]:
        if int(entry[0]) == hydro.cell_index(cell):
            fuel_after = int(entry[1])
    _check(events.any(func(event: Dictionary) -> bool:
        return event["kind"] == "тление")
        and fuel_after < fuel_before,
        "Тление списывает физическое топливо по игровым суткам")

    # Сильная сырость одновременно гасит пламя и жар подстилки.
    # Пепел остаётся, а после повторного расчёта того же дня
    # физическое состояние не меняется.
    _day(m, 5, 1.0)
    fire.advance_day(5)
    _check(fire.smolder_count() == 0
        and fire.scorched_at(cell) > 0.0,
        "Мокрая почва гасит угли, но сохраняет след выгорания")
    var stopped: Dictionary = fire.to_data()
    _check(fire.advance_day(5).is_empty()
        and fire.to_data() == stopped,
        "Повторный расчёт не ускоряет тление и восстановление")
    var extinguished_view: Node3D = Renderer.create_chunk(
        world, nature, chunk, 1.0, fire)
    _check(extinguished_view.get_node_or_null("угли") == null,
        "После тушения исчезает только реальное свечение углей")
    extinguished_view.free()


func _run() -> void:
    # Удача одного эффекта не скрывает ошибку баланса топлива или JSON.
    _test_smolder()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F3: ", message)
        quit(1)
        return
    print("11.5/F3: физическое тление, ветер, вода и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # MultiMesh и Godot-классы доступны в инициализированном SceneTree.
    call_deferred("_run")
