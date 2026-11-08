extends SceneTree
## 11.5/F5b1: выгоревшая почва теряет плодородие и восстанавливается.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(valid: bool, message: String) -> void:
    # Проверки независимы: ошибки почвы, JSON и биомассы
    # не должны скрываться удачной графической регрессией.
    if not valid:
        failures.append(message)


func _models() -> Dictionary:
    # Используем настоящий рельеф, грунт, гидрологию и лес.
    # Состояние пожара не подменяется флагом рендера.
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
    _check(nature.generate(), "Лес с реальными древесными объектами создан")
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": Fire.new(world, hydro, surface, climate, nature)
    }


func _tree(nature: RefCounted) -> Dictionary:
    # Выбираем дерево с запасом древесины вдали от границы мира.
    # При вынужденной сухости именно оно инициирует ожог почвы.
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


func _day(models: Dictionary, day: int, moisture: float,
        plants: RefCounted, fire: RefCounted = null) -> void:
    # Все календари синхронизированы: изменения здоровья и
    # восстановление ожога происходят за игровые сутки, не за FPS.
    var climate: RefCounted = models["climate"]
    var surface: RefCounted = models["surface"]
    climate.set_day(day)
    _check(surface.advance_climate_day(climate),
        "Грунт пересчитан для дня %d" % day)
    surface._moisture.fill(moisture)
    surface._snow.fill(0.0)
    climate._rain.fill(0.0)
    # GDScript различает Array и Array[Dictionary] даже тогда,
    # когда контейнер пуст; суточный реестр принимает типизированный.
    var events: Array[Dictionary] = []
    plants.advance_day(day, events, events, fire)


func _test_fertility() -> void:
    # Получаем физический ожог только из расхода топлива дерева,
    # а не вручную записываем состояние почвы в игровой реестр.
    var models: Dictionary = _models()
    var world: RefCounted = models["world"]
    var hydro: RefCounted = models["hydro"]
    var surface: RefCounted = models["surface"]
    var climate: RefCounted = models["climate"]
    var nature: RefCounted = models["nature"]
    var fire: RefCounted = models["fire"]
    var item: Dictionary = _tree(nature)
    if item.is_empty():
        _check(false, "Найдено взрослое дерево для возгорания")
        return
    var id := int(item["id"])
    var cell := Vector2i(int(item["x"]), int(item["y"]))

    _day(models, 2, 0.02, nature)
    fire.advance_day(2, [], cell)
    _check(fire.is_burning(id) and fire.soil_scar_count() == 0,
        "Почва не теряет плодородие до физического горения")

    _day(models, 3, 0.02, nature)
    fire.advance_day(3)
    var damage: float = fire.soil_damage_at(cell)
    var ash: float = fire.scorched_at(cell)
    _check(damage > 0.0 and ash > 0.0,
        "Горение создаёт и золу, и отдельный ожог почвы")
    _check(int(fire.to_data()["version"]) == 7,
        "Почвенный ожог сохраняется в формате v6")

    # Плодородие сравниваем при одинаковой погоде и рельефе.
    # Снизившийся потенциал роста используется травой и деревьями.
    surface._moisture.fill(0.42)
    var healthy: Dictionary = surface.profile_at(cell)
    var burned: Dictionary = surface.profile_at(cell, damage)
    _check(float(burned["fertility"]) < float(healthy["fertility"])
        and float(burned["base_fertility"]) == float(healthy["fertility"]),
        "Ожог снижает эффективное плодородие, не меняя породу")
    _check(float(burned["growth_potential"])
        <= float(healthy["growth_potential"])
        and float(burned["fire_damage"]) == damage,
        "Рост использует сохраняемый физический ожог")
    _check(nature.ground_cover_at(cell, fire)
        <= nature.ground_cover_at(cell),
        "Растительный покров учитывает повреждённую почву")

    # Создаём сейв целого мира. Переход к старому формату v3
    # допускается без вымышленных повреждений, но с прежней золой.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Повреждённая почва вошла в общий JSON")
    if not snapshot.is_empty():
        var loaded: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not loaded.is_empty(), "Мир с потерей плодородия загружается")
        if not loaded.is_empty():
            var loaded_fire: RefCounted = loaded["fire"]
            var loaded_surface: RefCounted = loaded["surface"]
            _check(loaded_fire.to_data() == fire.to_data()
                and absf(float(loaded_surface.profile_at(cell,
                    loaded_fire.soil_damage_at(cell))["fertility"])
                    - float(burned["fertility"])) < 0.00001,
                "После загрузки сохранены ожог и эффективное плодородие")
            _check(loaded["runner"].fire == loaded_fire,
                "Загруженный Runner использует тот же реестр ожога")

    var older_data: Dictionary = fire.to_data()
    older_data["version"] = 3
    older_data.erase("soil_damage")
    var older := Fire.new(world, hydro, surface, climate, nature)
    _check(older.load_data(older_data)
        and older.soil_scar_count() == 0
        and older.scorched_count() == fire.scorched_count(),
        "Пожарные сохранения v3 загружаются без придуманного ожога")

    # Отклоняем дубликаты и невалидные величины до замены реестра.
    var initial: Dictionary = fire.to_data()
    if initial["soil_damage"].is_empty():
        _check(false, "После горения существует сохраняемый ожог почвы")
        return
    var duplicate: Dictionary = initial.duplicate(true)
    duplicate["soil_damage"].append(
        duplicate["soil_damage"][0].duplicate())
    _check(not fire.load_data(duplicate)
        and fire.to_data() == initial,
        "Дубли почвенных повреждений не портят действующий мир")
    var invalid: Dictionary = initial.duplicate(true)
    invalid["soil_damage"][0][1] = 1001
    _check(not fire.load_data(invalid)
        and fire.to_data() == initial,
        "Недопустимый ожог почвы не проходит строгую загрузку")

    # Отделяем влияния собственно почвенного ожога от погоды
    # на двух одинаковых копиях природного реестра.
    var baseline := Nature.new(world, hydro, surface, climate)
    _check(baseline.load_data(nature.to_data()),
        "Создан контрольный мир с теми же деревьями")
    var initial_health: int = int(nature.object_at(id)["health"])
    for day in range(4, 12):
        _day(models, day, 1.0, nature, fire)
        baseline.advance_day(day)
        fire.advance_day(day)
    _check(int(nature.object_at(id)["health"])
        < int(baseline.object_at(id)["health"])
        and int(nature.object_at(id)["health"]) <= initial_health,
        "Ожог создаёт дополнительный стресс реально растущему дереву")
    _check(not fire.is_burning(id)
        and fire.soil_damage_at(cell) > 0.0,
        "Дождь потушил огонь, но почва ещё восстанавливается")

    # Полный цикл проверяем при благоприятном, умеренно влажном
    # климате: холод и засуха в новой модели вправе замедлить заживление.
    # Температуру фиксируем только в физическом тесте, после расчёта
    # календарного дня; сама система не зависит от кадров и камеры.
    var cell_index: int = hydro.cell_index(cell)
    for day in range(12, 132):
        _day(models, day, 0.55, nature, fire)
        climate._temperature[cell_index] = 20.0
        surface._air_temperature[cell_index] = 20.0
        surface._frost[cell_index] = 0.0
        fire.advance_day(day)
    _check(fire.soil_damage_at(cell) == 0.0
        and fire.soil_scar_count() == 0,
        "Спустя игровые сутки почвенная травма полностью исчезла")
    var restored: Dictionary = surface.profile_at(
        cell, fire.soil_damage_at(cell))
    _check(absf(float(restored["fertility"])
        - float(surface.profile_at(cell)["fertility"])) < 0.00001,
        "Плодородие восстановилось без изменения геологического слоя")


func _run() -> void:
    # Отдельно проверяем поражение почвы, миграции JSON и
    # здоровье растительности, а не только цвет гари на карте.
    _test_fertility()
    if not failures.is_empty():
        for error in failures:
            printerr("11.5/F5b1: ", error)
        quit(1)
        return
    print("11.5/F5b1: почва, растения, JSON и восстановление — успешно")
    quit(0)


func _initialize() -> void:
    # Объекты Godot доступны после инициализации дерева сцен.
    call_deferred("_run")
