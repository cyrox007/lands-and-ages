extends SceneTree
## 11.5/F5b2b: скорость регенерации обожжённой почвы зависит от климата.

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
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
    # Накапливаем все независимые ошибки регрессии: один удачный
    # погодный сценарий не скрывает неисправность другого.
    if not condition:
        failures.append(message)


func _test_recovery_rates() -> void:
    # Условные, но детерминированные коэффициенты не создают новой
    # модели климата: используются уже рассчитанные температуры.
    _check(Fire.soil_recovery_per_day(0.55, 20.0, 0.0, 0.0, false) == 6,
        "Умеренно влажная тёплая почва восстанавливается быстрее")
    _check(Fire.soil_recovery_per_day(0.05, 20.0, 0.0, 0.0, false) == 1,
        "Засуха тормозит восстановление")
    _check(Fire.soil_recovery_per_day(0.55, -7.0, 0.8, 0.8, false) == 1,
        "Мороз и снег тормозят восстановление")
    _check(Fire.soil_recovery_per_day(0.55, 20.0, 0.3, 0.0, false) == 1,
        "Снежный покров подавляет восстановление")
    _check(Fire.soil_recovery_per_day(0.55, 20.0, 0.0, 0.0, true) == 1,
        "Затопленный участок восстанавливается медленно")
    _check(Fire.soil_recovery_per_day(0.95, 20.0, 0.0, 0.0, false) == 4,
        "Избыточная влажность сохраняет умеренный темп")
    _check(Fire.soil_recovery_per_day(0.55, 42.0, 0.0, 0.0, false) == 1,
        "Сильная жара замедляет восстановление")


func _test_calendar_and_save() -> void:
    # Создаём настоящий природный мир и восстанавливаем в нём
    # корректную запись прежнего ожога через строгий формат v4.
    var world := Map.new(Config.new(96, 80, 1729, 16, 32))
    var hydro := Hydro.new(world)
    hydro.rebuild()
    var surface := Surface.new(world, hydro)
    surface.rebuild()
    var climate := Climate.new(world, hydro)
    climate.rebuild()
    climate.set_day(1)
    _check(surface.advance_climate_day(climate),
        "Поверхность рассчитана для первого дня")
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Природа сгенерирована на физической карте")
    var fire := Fire.new(world, hydro, surface, climate, nature)

    # Выбираем сухопутную клетку растительности вне затопления.
    var cell := Vector2i(-1, -1)
    for record in nature.to_data()["objects"]:
        if record[1] != "дерево" or record[9] != "целое":
            continue
        var position := Vector2i(int(record[3]), int(record[4]))
        if position.x < 8 or position.y < 8 \
                or position.x >= 88 or position.y >= 72:
            continue
        var candidate: int = hydro.cell_index(position)
        if not hydro.has_water(candidate) and not hydro.flooded_at(candidate):
            cell = position
            break
    _check(cell.x >= 0, "Найдена пригодная сухопутная клетка")
    if cell.x < 0:
        return
    var index: int = hydro.cell_index(cell)
    var stored: Dictionary = fire.to_data()
    stored["soil_damage"] = [[index, 240, 1]]
    _check(fire.load_data(stored), "Реестр принял сохранённый физический ожог")
    if fire.soil_scar_count() != 1:
        return

    var cases := [
        {"day": 2, "moisture": 0.55, "temperature": 20.0,
            "snow": 0.0, "frost": 0.0, "healed": 6},
        {"day": 3, "moisture": 0.05, "temperature": 20.0,
            "snow": 0.0, "frost": 0.0, "healed": 1},
        {"day": 4, "moisture": 0.55, "temperature": -7.0,
            "snow": 0.7, "frost": 0.8, "healed": 1},
        {"day": 5, "moisture": 0.95, "temperature": 20.0,
            "snow": 0.0, "frost": 0.0, "healed": 4},
        {"day": 6, "moisture": 0.55, "temperature": 42.0,
            "snow": 0.0, "frost": 0.0, "healed": 1}
    ]
    for scenario in cases:
        # Обычный суточный пересчёт меняет дату всех моделей,
        # затем подменяем только контролируемые климатические пробы.
        var day: int = int(scenario["day"])
        _check(climate.set_day(day), "Климат обновлён на день %d" % day)
        _check(surface.advance_climate_day(climate),
            "Поверхность обновлена на день %d" % day)
        surface._moisture[index] = float(scenario["moisture"])
        surface._snow[index] = float(scenario["snow"])
        surface._frost[index] = float(scenario["frost"])
        climate._temperature[index] = float(scenario["temperature"])
        surface._air_temperature[index] = float(scenario["temperature"])
        nature.advance_day(day)

        var before: int = int(fire.to_data()["soil_damage"][0][1])
        fire.advance_day(day)
        var after: int = int(fire.to_data()["soil_damage"][0][1])
        _check(before - after == int(scenario["healed"]),
            "Суточная регенерация соответствует погоде дня %d" % day)
        # Повторная обработка того же дня не даёт бесплатного роста.
        fire.advance_day(day)
        _check(int(fire.to_data()["soil_damage"][0][1]) == after,
            "День %d не обрабатывается дважды" % day)

    # Формат сохранений прежний: дата и интенсивность ожога переживают
    # JSON без таймеров, FPS или временных коэффициентов рендера.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": Processes.new(world, hydro, surface, climate),
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Мир с климатическим восстановлением сохранён")
    if not snapshot.is_empty():
        var restored: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not restored.is_empty(), "Мир восстановлен из JSON")
        if not restored.is_empty():
            var loaded_fire: RefCounted = restored["fire"]
            _check(loaded_fire.to_data() == fire.to_data()
                and loaded_fire.soil_damage_at(cell) == fire.soil_damage_at(cell),
                "После загрузки сохранён прогресс регенерации грунта")
            _check(restored["runner"].fire == loaded_fire,
                "После загрузки Runner использует сохранённый ожог")


func _run() -> void:
    # Проверяем одновременно диапазоны скорости, реальный
    # календарный цикл и восстановление данных без нового формата.
    _test_recovery_rates()
    _test_calendar_and_save()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F5b2b: ", message)
        quit(1)
        return
    print("11.5/F5b2b: климат, почва, сутки и JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Сценарий стартует после подготовки SceneTree.
    call_deferred("_run")
