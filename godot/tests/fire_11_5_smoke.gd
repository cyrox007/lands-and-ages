extends SceneTree
## 11.5/F1: очаг молнии, настоящая биомасса, дождь, ветер, JSON и игра.

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
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(value: bool, message: String) -> void:
    # Все проваленные проверки попадают в итоговый лог CI.
    # Тест не маскирует регрессию ранним завершением.
    if not value:
        failures.append(message)


func _models(seed: int) -> Dictionary:
    # Используем готовую физику карты: вода, грунт, сезон,
    # настоящие деревья, кустарники и природные события.
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
    _check(nature.generate(), "Природный лес с горючими объектами создан")
    var fire := Fire.new(world, hydro, surface, climate, nature)
    return {"world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire}


func _tree(nature: RefCounted) -> Dictionary:
    # Выбираем взрослое дерево далеко от краёв и водоёмов.
    # Его древесины достаточно на несколько физических дней огня.
    for record in nature.to_data()["objects"]:
        if record[1] != "дерево" or record[9] != "целое":
            continue
        var id := int(record[0])
        var x := int(record[3])
        var y := int(record[4])
        if x < 10 or y < 10 or x >= 86 or y >= 70 \
                or int(record[7]) < 35:
            continue
        return nature.object_at(id)
    return {}


func _test_physics_and_save() -> void:
    # Пробный пожар запускается физическим источником, не
    # переключением текстуры и не созданием GPU-частиц.
    var m: Dictionary = _models(1729)
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var chosen: Dictionary = _tree(nature)
    if chosen.is_empty():
        _check(false, "В мире найдено взрослое дерево для воспламенения")
        return
    var id := int(chosen["id"])
    var cell := Vector2i(int(chosen["x"]), int(chosen["y"]))
    var chunk: Vector2i = world.config.chunk_of(cell)
    var original_wood: int = nature.wood_total()

    climate.set_day(2)
    surface.advance_climate_day(climate)
    surface._moisture.fill(0.02)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    nature.advance_day(2)
    var started: Array[Dictionary] = fire.advance_day(2, [], cell)
    _check(started.size() > 0 and fire.is_burning(id)
        and fire.burning_count() > 0
        and fire.total_ignitions >= 1,
        "Сухое дерево загорается при реальном пробном источнике")
    _check(nature.wood_total() >= original_wood,
        "Возгорание ещё не создало древесный ресурс")

    # Сохраняем активный огонь с полной географией, а не
    # изолированную анимацию. Снимок без поля fire остаётся legacy.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty() and snapshot.has("fire"),
        "Общий WorldSave сохраняет физический горящий объект")
    if not snapshot.is_empty():
        var restored: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not restored.is_empty()
            and restored.get("fire") != null,
            "Полный мир с огнём загружается из JSON")
        if not restored.is_empty():
            _check(restored["fire"].to_data() == fire.to_data()
                and restored["fire"].is_burning(id),
                "После загрузки очаг сохраняет ID, топливо и дату")
            _check(restored["runner"].fire == restored["fire"],
                "Возобновлённый Runner использует новый физический реестр")

        # Старый формат снимка не содержал отдельной модели огня.
        # Он должен продолжить игру без выдуманного пожара.
        var legacy: Dictionary = snapshot.duplicate(true)
        legacy.erase("fire")
        var old: Dictionary = Save.restore(legacy)
        _check(not old.is_empty() and
            old["fire"].burning_count() == 0,
            "Старый сохранённый мир восстанавливается без очагов")

        # Дубликат и несуществующий объект должны отклоняться
        # полностью, не меняя действующий физический реестр.
        var broken: Dictionary = fire.to_data()
        broken["fires"] = [[id, 40, 2], [id, 50, 2]]
        _check(not fire.load_data(broken)
            and fire.is_burning(id),
            "Неправильный JSON не повреждает активный пожар")

    var visible: Node3D = Renderer.create_chunk(
        world, nature, chunk, 1.0, fire)
    _check(visible.get_node_or_null("пламя") != null,
        "Физическое горение видно в чанке без отдельного очага FX")
    visible.free()

    climate.set_day(3)
    surface.advance_climate_day(climate)
    surface._moisture.fill(0.02)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    nature.advance_day(3)
    var before_burn: Dictionary = nature.object_at(id)
    var total_before_burn: int = nature.wood_total()
    fire.advance_day(3)
    var after_burn: Dictionary = nature.object_at(id)
    _check(int(after_burn["health"]) < int(before_burn["health"])
        and int(after_burn["wood_units"]) < int(before_burn["wood_units"]),
        "Огонь расходует здоровье и реальный древесный запас")
    _check(nature.wood_total() < total_before_burn,
        "Горение расходует существующий запас без создания брёвен")

    # Дождь и мокрая земля гасят очаг без удаления объекта мира.
    climate.set_day(4)
    surface.advance_climate_day(climate)
    surface._moisture.fill(1.0)
    nature.advance_day(4)
    var extinguished: Array[Dictionary] = fire.advance_day(4)
    _check(not fire.is_burning(id)
        and extinguished.any(func(event: Dictionary) -> bool:
            return event["kind"] == "затухание"),
        "Мокрый грунт тушит горящий объект на следующий день")
    var empty_visual: Node3D = Renderer.create_chunk(
        world, nature, chunk, 1.0, fire)
    _check(empty_visual.get_node_or_null("пламя") == null,
        "После тушения не остаётся фиктивного пламени")
    empty_visual.free()
    var unchanged: Dictionary = fire.to_data()
    _check(fire.advance_day(4).is_empty()
        and fire.to_data() == unchanged,
        "Один физический день не прожигается повторно")


func _test_runner() -> void:
    # Суточный Runner проходит новый шаг даже без диагностического
    # события: это контракт интеграции с игрой и старыми тестами.
    var m: Dictionary = _models(1739)
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var runner := Runner.new(world, hydro, surface, climate,
        Weather.new(world, climate, surface, hydro),
        Processes.new(world, hydro, surface, climate),
        Disasters.new(world, hydro, surface, climate), nature, fire)
    var chosen: Dictionary = _tree(nature)
    if chosen.is_empty():
        _check(false, "Для Runner найдено дерево")
        return
    runner.test_fire_cell = Vector2i(int(chosen["x"]), int(chosen["y"]))
    runner.run_day()
    _check(fire.last_day == climate.day
        and runner.test_fire_cell.x < 0
        and runner.last_result.has("fire_events")
        and runner.last_result.has("fires_active")
        and runner.last_profile_us.has("горение"),
        "Runner обрабатывает пожар после природного шага и сбрасывает пробу")
    runner.run_day()
    _check(fire.last_day == climate.day
        and runner.test_fire_cell.x < 0,
        "На следующем дне пробный источник не появляется повторно")


func _run() -> void:
    # Физика, сохранения и пользовательская цепочка проверяются
    # независимо: успешная анимация не заменяет проверку топлива.
    _test_physics_and_save()
    _test_runner()
    if not failures.is_empty():
        for failure in failures:
            printerr("11.5/F1: ", failure)
        quit(1)
        return
    print("11.5/F1: реальные очаги, топливо, дождь, вид и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Рендерер требует готового SceneTree для MultiMesh.
    call_deferred("_run")
