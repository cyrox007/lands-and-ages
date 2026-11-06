extends SceneTree
## 11.5/F5a–F5b2a: зола и устойчивый ожог повышают риск эрозии.

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
    # Несколько независимых условий сохраняем в одном логе,
    # чтобы ошибки риска, загрузки и синхронизации были видны сразу.
    if not valid:
        failures.append(message)


func _models() -> Dictionary:
    # Используем физический мир, а не искусственный список склонов.
    # Все риски исходят из настоящей гидрологии, почвы и климата.
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
    _check(nature.generate(), "В мире создана природная растительность")
    var fire := Fire.new(world, hydro, surface, climate, nature)
    var natural := Processes.new(world, hydro, surface, climate)
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "fire": fire, "natural": natural
    }


func _candidate(natural: RefCounted, world: RefCounted) -> Dictionary:
    # Ищем несатурированный риск: у него можно измерить увеличение
    # от пожара, не путая эффект с ограничением вероятности 1.0.
    for y in range(6, world.config.height - 6):
        for x in range(6, world.config.width - 6):
            var cell := Vector2i(x, y)
            var risks: Dictionary = natural.estimate_at(cell)
            if risks.is_empty():
                continue
            for kind in ["water", "wind", "slide"]:
                var value: float = float(risks[kind])
                if value >= 0.02 and value <= 0.75:
                    return {"cell": cell, "kind": kind, "risk": value}
    return {}


func _test_burned_slope() -> void:
    # Без пожара все исходные геологические оценки неизменны.
    var m: Dictionary = _models()
    var world: RefCounted = m["world"]
    var hydro: RefCounted = m["hydro"]
    var surface: RefCounted = m["surface"]
    var climate: RefCounted = m["climate"]
    var nature: RefCounted = m["nature"]
    var fire: RefCounted = m["fire"]
    var natural: RefCounted = m["natural"]
    var sample: Dictionary = _candidate(natural, world)
    _check(not sample.is_empty(),
        "Найден реальный склон или продуваемый участок с ненулевым риском")
    if sample.is_empty():
        return
    var cell: Vector2i = sample["cell"]
    var kind: String = sample["kind"]
    var index: int = hydro.cell_index(cell)
    var base: float = float(sample["risk"])
    _check(float(natural.estimate_at(cell)["fire_exposure"]) == 0.0,
        "В старом мире без пожаров риск не содержит фиктивной гари")

    # Один пожар оставляет независимые следы золы и ожога.
    # Рельеф, влажность и скорость ветра ради теста не меняются.
    var saved: Dictionary = fire.to_data()
    saved["scorched"] = [[index, 1000, 1]]
    saved["soil_damage"] = [[index, 850, 1]]
    _check(fire.load_data(saved),
        "Зола и ожог загружены через строгий формат v4")
    var runner := Runner.new(world, hydro, surface, climate,
        Weather.new(world, climate, surface, hydro),
        natural, Disasters.new(world, hydro, surface, climate),
        nature, fire)
    _check(natural.fire == fire and runner.fire == fire,
        "Суточный Runner передаёт физический пожар в расчёт эрозии")

    var burned: Dictionary = natural.estimate_at(cell)
    _check(absf(float(burned["fire_exposure"]) - 1.0) < 0.00001,
        "Геологический риск читает реальную долю выгорания")
    _check(float(burned[kind]) > base + 0.00001
        and float(burned[kind]) <= 1.0,
        "Выгорание повышает настоящий риск " + kind
        + " без превышения вероятности 1.0")

    # Испытание общей загрузки гарантирует, что эффект не исчезнет
    # после выхода из игры: в восстанавливаемом мире тот же реестр
    # связан с теми же медленными природными процессами.
    var state := {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature, "fire": fire,
        "weather": Weather.new(world, climate, surface, hydro),
        "natural": natural,
        "disasters": Disasters.new(world, hydro, surface, climate)
    }
    var snapshot: Dictionary = Save.capture(state)
    _check(not snapshot.is_empty(), "Мир с выгоревшей почвой сохранён")
    if not snapshot.is_empty():
        var restored: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(snapshot)))
        _check(not restored.is_empty(),
            "Выгоревший склон можно восстановить из JSON")
        if not restored.is_empty():
            var restored_processes: RefCounted = restored["natural"]
            var restored_fire: RefCounted = restored["fire"]
            var restored_risk: Dictionary = restored_processes.estimate_at(cell)
            _check(restored_processes.fire == restored_fire
                and restored_risk["fire_exposure"] == burned["fire_exposure"]
                and absf(float(restored_risk[kind])
                    - float(burned[kind])) < 0.00001,
                "После загрузки сохраняется связь огня и риска эрозии")

    # Дождь смывает пепел, но оставляет обожжённую почву.
    # Риск должен снижаться постепенно, а не исчезать за сутки.
    saved["scorched"] = []
    _check(fire.load_data(saved), "Ожог без золы принят реестром")
    var after_runoff: Dictionary = natural.estimate_at(cell)
    _check(fire.scorched_at(cell) == 0.0
        and absf(fire.soil_damage_at(cell) - 0.85) < 0.00001
        and absf(float(after_runoff["fire_exposure"]) - 0.85) < 0.00001,
        "Смыв золы не удаляет физическое повреждение почвы")
    _check(float(after_runoff[kind]) > base + 0.00001
        and float(after_runoff[kind]) < float(burned[kind]),
        "Сохраняется промежуточный риск до регенерации грунта")

    # Проверяем длительный след и после полной загрузки мира.
    var washed_snapshot: Dictionary = Save.capture(state)
    _check(not washed_snapshot.is_empty(),
        "Мир без золы, но с почвенным ожогом сохраняется")
    if not washed_snapshot.is_empty():
        var washed_world: Dictionary = Save.restore(
            JSON.parse_string(JSON.stringify(washed_snapshot)))
        _check(not washed_world.is_empty(),
            "Мир после зольного смыва загружается")
        if not washed_world.is_empty():
            var risk_after_load: Dictionary = washed_world["natural"].estimate_at(cell)
            _check(absf(float(risk_after_load[kind])
                - float(after_runoff[kind])) < 0.00001,
                "Ожог продолжает влиять на эрозию после загрузки")

    # Только восстановление обоих следов возвращает исходный риск.
    saved["soil_damage"] = []
    _check(fire.load_data(saved), "Зажившая почва принята реестром")
    var recovered: Dictionary = natural.estimate_at(cell)
    _check(absf(float(recovered[kind]) - base) < 0.00001
        and float(recovered["fire_exposure"]) == 0.0,
        "После восстановления почвы риск возвращается к исходному")
    natural.fire = null
    _check(absf(float(natural.estimate_at(cell)[kind]) - base) < 0.00001,
        "Мир без системы пожаров продолжает прежнюю физику")


func _run() -> void:
    # Сценарий проверяет именно значения геологических рисков.
    # Визуальный эффект дыма не участвует ни в одном измерении.
    _test_burned_slope()
    if not failures.is_empty():
        for message in failures:
            printerr("11.5/F5a: ", message)
        quit(1)
        return
    print("11.5/F5a: выгоревшая почва, эрозия, JSON — успешно")
    quit(0)


func _initialize() -> void:
    # Godot-классы подключаются после готовности SceneTree.
    call_deferred("_run")
