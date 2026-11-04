extends SceneTree
## Проверка этапа 10: природные объекты, физический запас, сохранения.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Capacity = preload("res://scripts/world_capacity_audit.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    if not ok:
        failures.append(message)


func _state(seed: int = 1729) -> Dictionary:
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
    var weather := Weather.new(world, climate, surface, hydro)
    var natural := Natural.new(world, hydro, surface, climate)
    var disasters := Disasters.new(world, hydro, surface, climate)
    var nature := Nature.new(world, hydro, surface, climate)
    _check(nature.generate(), "Первичная генерация растений выполнена")
    return {
        "world": world, "hydro": hydro, "surface": surface,
        "climate": climate, "nature": nature,
        "weather": weather, "natural": natural, "disasters": disasters,
        "runner": Runner.new(world, hydro, surface, climate,
            weather, natural, disasters, nature)
    }


func _run() -> void:
    var original := _state()
    var repeated := _state()
    var nature: RefCounted = original["nature"]
    _check(nature.generated and nature.count() > 0,
        "Физические объекты заселяют подходящие участки мира")
    _check(nature.to_data() == repeated["nature"].to_data(),
        "Заселение не зависит от порядка вычисления")
    _check(not nature.generate(), "Повторная генерация не удваивает объекты")

    var ids := {}
    var tree_id := -1
    for cy in range(original["world"].config.chunk_count().y):
        for cx in range(original["world"].config.chunk_count().x):
            var chunk := Vector2i(cx, cy)
            for item in nature.objects_in_chunk(chunk):
                var id: int = item["id"]
                _check(not ids.has(id), "ID не дублируется между чанками")
                ids[id] = true
                var cell := Vector2i(int(item["x"]), int(item["y"]))
                _check(not original["hydro"].has_water(
                    original["hydro"].cell_index(cell)),
                    "Растительность не возникает в воде")
                if item["kind"] == "дерево" and tree_id < 0:
                    tree_id = id
    _check(ids.size() == nature.count(),
        "Все природные объекты доступны через пространственный индекс")
    _check(tree_id > 0, "Для испытания есть настоящее дерево")

    if tree_id > 0:
        var stock: int = nature.wood_total()
        var hit: Dictionary = nature.fell_tree(tree_id)
        _check(not hit.is_empty() and int(hit["wood_units"]) > 0,
            "Физическая валка переводит дерево в пень")
        _check(nature.wood_total() == stock,
            "Древесина не возникает и не исчезает при валке")
        _check(nature.fell_tree(tree_id).is_empty(),
            "Повторная рубка не дублирует древесину")
        var extracted: int = maxi(1, int(hit["wood_units"]) / 2)
        _check(nature.take_fallen_wood(tree_id, extracted),
            "Часть лежащей древесины доступна для будущей перевозки")
        _check(nature.wood_total() == stock - extracted,
            "Изъятие ресурса сохраняет количественный баланс")
        _check(not nature.take_fallen_wood(tree_id, 1000000),
            "Нельзя получить больше древесины, чем осталось")

    var capacity: Dictionary = Capacity.report(original["world"],
        original["hydro"], original["surface"], nature, 9)
    _check(int(capacity["cells"]) == 96 * 80,
        "Аудит использует реальные размеры конфигурации")
    _check(int(capacity["ocean"]) + int(capacity["dry"]) <= 96 * 80,
        "Аудит не удваивает морские клетки")
    _check(int(capacity["developable"]) <= int(capacity["dry"]),
        "Площадь строительства не превышает сухую сушу")
    _check(int(capacity["wood_units"]) == nature.wood_total(),
        "Аудит читает физическую древесину, а не визуальные меши")

    var snapshot: Dictionary = Save.capture(original)
    _check(snapshot.has("nature"), "Растительность включена в сохранение")
    var restored: Dictionary = Save.restore(snapshot)
    _check(not restored.is_empty(), "Снимок растительности загружается")
    if not restored.is_empty():
        _check(restored["nature"].to_data() == nature.to_data(),
            "После загрузки совпадают объекты и остатки ресурсов")
        _check(restored["runner"].nature == restored["nature"],
            "Суточная симуляция использует восстановленный лес")
        for i in range(8):
            original["runner"].run_day()
            restored["runner"].run_day()
        _check(restored["nature"].to_data() == nature.to_data(),
            "Рост, природный стресс и ресурсы детерминированы после загрузки")
        _check(nature.advance_day(original["climate"].day) == 0,
            "Нельзя повторить уже рассчитанный день")

    var corrupt := snapshot.duplicate(true)
    corrupt["nature"]["objects"] = [[-1]]
    _check(Save.restore(corrupt).is_empty(),
        "Повреждённый список природных объектов отклоняется")

    if not failures.is_empty():
        for error in failures:
            push_error(error)
        print("Этап 10: ошибок ", failures.size())
        quit(1)
        return
    print("Этап 10: реестр, ресурсы, рост, сохранения и масштаб — успешно")
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
