extends SceneTree
## Этап 11.3/V2.4: физический шквал, суточный цикл, урон и сохранения.
## Проверяется реальная связка моделей, а не изолированная картинка.

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


class StrongGust:
    extends RefCounted
    ## Подставляем предельный порыв только в тест генератора бедствий.
    ## Гидрология, грунт и игровая модель не получают фиктивных событий.
    var day := 1

    func ensure_ready() -> void:
        # Данные тестового фронта постоянны, пересчёт не нужен.
        pass

    func temperature_at_index(_index: int) -> float:
        # Тепло без осадков исключает засуху из условия порыва.
        return 18.0

    func precipitation_at_index(_index: int) -> float:
        return 0.0

    func wind_at_index(_index: int) -> float:
        # Средняя скорость значительно меньше отдельного шквала.
        return 7.0

    func wind_gust_at_index(_index: int) -> float:
        return 34.0

    func storm_at_index(_index: int) -> float:
        # Шквал не обязан ждать трёх суток зрелой грозы.
        return 0.0


var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    # Сохраняем несколько ошибок за один запуск, упрощая разбор CI.
    if not ok:
        failures.append(message)


func _test_real_game() -> void:
    # Запускаем официальный суточный Runner с настоящими моделями.
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
    _check(nature.generate(), "Природный мир создан")

    # Выбираем дерево, для которого результат падения в день 2
    # детерминированно известен, и до события нет роста по очереди.
    var tree: Dictionary = {}
    for entry in nature.to_data()["objects"]:
        var id := int(entry[0])
        var x := int(entry[3])
        var y := int(entry[4])
        if entry[1] != "дерево" or entry[9] != "целое" \
                or int(entry[7]) <= 0 or posmod(2 - id, 8) == 0:
            continue
        if x < 7 or y < 7 or x >= 89 or y >= 73:
            continue
        if Terrain.hash2(x, y, seed + 2 * 31 + 3173) >= 0.75:
            continue
        tree = nature.object_at(id)
        break
    if tree.is_empty():
        _check(false, "Есть доступное дерево для воспроизводимого шквала")
        return

    var tree_id: int = int(tree["id"])
    var cell := Vector2i(int(tree["x"]), int(tree["y"]))
    var before_wood := int(tree["wood_units"]) + int(tree["fallen_wood"])
    var preserved := JSON.parse_string(JSON.stringify(nature.to_data()))
    var at_edge := Nature.new(world, hydro, surface, climate)
    _check(at_edge.load_data(preserved), "Создана исходная копия леса")

    var weather := Weather.new(world, climate, surface, hydro)
    var processes := Processes.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var runner := Runner.new(world, hydro, surface, climate,
        weather, processes, disasters, nature)
    runner.test_squall_cell = cell
    runner.run_day()

    # Диагностическая кнопка поставляет один реальный шквал в
    # результирующие события, которые Registry уже обработал.
    var result: Dictionary = runner.last_result
    var trials := 0
    for hazard in result["hazards"]:
        if hazard.get("source", "") != "диагностика":
            continue
        trials += 1
        _check(hazard["kind"] == "шквал" and hazard["cell"] == cell
            and float(hazard["severity"]) == 1.0,
            "Runner зафиксировал самостоятельный физический шквал")
    _check(trials == 1 and runner.test_squall_cell.x < 0,
        "Диагностика не повторяется сама")

    var fallen: Dictionary = nature.object_at(tree_id)
    _check(fallen["state"] == "пень"
        and int(fallen["wood_units"]) == 0
        and int(fallen["fallen_wood"]) == before_wood,
        "Шквал валит дерево без дублирования ресурса")
    _check(int(fallen["fallen_since_day"]) == 2
        and int(fallen["fall_angle_deg"]) >= 0,
        "Дата и направление ветровала записаны в физическое состояние")
    var shape: Dictionary = Geometry.log_footprint(fallen, world.config)
    var direction: Vector2 = climate.wind_direction_at_index(
        hydro.cell_index(cell))
    _check(not shape.is_empty() and
        Vector2(shape.get("axis", Vector2.ZERO)).dot(direction) > 0.999,
        "Шквал и коллизия ориентируют ствол по реальному ветру")
    var visual_found := false
    for item in result["windfalls"]:
        if int(item["before"]["id"]) == tree_id:
            visual_found = int(item["fall_angle_deg"]) == int(
                fallen["fall_angle_deg"])
            break
    _check(visual_found, "Анимация получает истинное физическое падение")

    # Отдельная копия того же дерева получает тот же шквал на
    # расстоянии 3 клеток: у края фронта меньше урон и нет валки.
    at_edge.advance_day(2, [{
        "kind": "шквал", "cell": cell + Vector2i(3, 0),
        "severity": 1.0
    }])
    var weakened: Dictionary = at_edge.object_at(tree_id)
    var expected_damage := roundi(480.0 *
        (0.30 + 0.70 * (1.0 - 3.0 / 3.5)))
    _check(weakened["state"] == "целое"
        and int(weakened["health"]) == int(tree["health"]) - expected_damage,
        "Порыв ослабевает к краю: повреждение меньше и дерево стоит")

    # Сериализация — только последствия. Список видимых анимаций
    # намеренно не входит в сохранение и не повторяется при загрузке.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(nature.to_data()))
    var restored := Nature.new(world, hydro, surface, climate)
    _check(restored.load_data(saved) and restored.to_data() == nature.to_data(),
        "После JSON возвращаются древесина, дата и физический угол")
    _check(restored.last_windfalls.is_empty(),
        "Загрузка не воспроизводит анимацию уже прошедшего шквала")

    runner.run_day()
    for hazard in runner.last_result["hazards"]:
        _check(hazard.get("source", "") != "диагностика",
            "На следующий день пробный шквал не дублируется")


func _test_natural_origin() -> void:
    # Проверяем не диагностический путь, а появление шквала из
    # отдельного фронтального риска на настоящей карте.
    var world := Map.new(Config.new(96, 80, 2719, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var disasters := Disasters.new(world, hydro, surface, climate)
    var gust := StrongGust.new()
    disasters.climate = gust
    var sample := Vector2i(24, 24)
    _check(float(disasters.conditions_at(sample, false)["шквал"]) > 0.52
        and float(disasters.conditions_at(sample, false)["шторм"]) == 0.0,
        "Шквал возникает от разницы порыва и среднего ветра без шторма")

    var happened := false
    for day in range(2, 26):
        # Настоящую поверхность ведём по дням; только поле ветра
        # заменяем граничным тестовым сценарием, не меняя ландшафт.
        climate.set_day(day)
        surface.advance_climate_day(climate)
        gust.day = day
        for event in disasters.advance_day(day):
            if event["kind"] == "шквал":
                happened = true
                _check(event["duration_days"] == 1,
                    "Шквал — однодневный эпизод, а не затяжной шторм")
        if happened:
            break
    _check(happened, "Природный шквал появился без команды игрока")
    if not happened:
        return

    # Формат бедствий остаётся v1: новый разрешённый тип хранится
    # в прежней девятипольной записи без потери старых сохранений.
    var saved: Dictionary = JSON.parse_string(JSON.stringify(
        disasters.to_data()))
    var loaded := Disasters.new(world, hydro, surface, climate)
    loaded.climate = gust
    _check(loaded.load_data(saved)
        and JSON.stringify(loaded.to_data()) == JSON.stringify(
            disasters.to_data()), "Новое событие восстанавливается из JSON")


func _run() -> void:
    # Последовательность проверок исключает влияние одного тестового
    # мира на другой и сообщает о каждом нарушенном инварианте.
    _test_real_game()
    _test_natural_origin()
    if not failures.is_empty():
        for error in failures:
            printerr("11.3/V2.4: ", error)
        quit(1)
        return
    print("11.3/V2.4: шквал, локальный урон, реальный ветровал и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Godot требует начать физическую проверку после создания SceneTree.
    call_deferred("_run")
