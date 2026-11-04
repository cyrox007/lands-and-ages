extends SceneTree
## Проверка этапа 10: природные объекты, физический запас, сохранения.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")
const Models = preload("res://scripts/nature_asset_library.gd")
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
    var model_names: Array[String] = Models.available_models()
    _check(model_names.size() == 12,
        "Все 12 настоящих CC0 GLB загружаются в Godot")
    for key in model_names:
        var info: Dictionary = Models.info(key)
        _check(int(info.get("triangles", 999999)) <= 1000,
            "Лёгкая модель помещается в бюджет полигонов: " + key)
        var transform: Transform3D = Models.placement(key, Vector3.ZERO)
        var bounds: AABB = (info["mesh"] as Mesh).get_aabb()
        var ground: Vector3 = transform * Vector3(0.0, bounds.position.y, 0.0)
        _check(absf(ground.y) < 0.025,
            "Модель нормализована по уровню земли: " + key)
        _check(transform.basis.get_scale().y > 0.0,
            "Масштаб GLB положительный: " + key)
    _check(Models.select_tree(30 * 96, 2, 1.0).begins_with("TreeHigh"),
        "Взрослое дерево использует полноценную визуальную модель")
    _check(Models.select_tree(30 * 96, 2, 0.1).begins_with("TreeLow"),
        "Отдалённая камера выбирает низкий LOD")

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
        var tree: Dictionary = nature.object_at(tree_id)
        var center := Vector2(float(tree["x"]) + 0.5,
            float(tree["y"]) + 0.5)
        _check(nature.intersects_solid(center, 0.10),
            "Ствол занимает физический участок, а не всю клетку")
        _check(not nature.interaction_points(tree_id).is_empty(),
            "У дерева есть физические точки подхода")
        var canopy_before: float = nature.canopy_pressure_at(
            Vector2i(int(tree["x"]), int(tree["y"])))
        _check(canopy_before > 0.0,
            "Взрослое дерево создаёт физическое затенение")
        var stock: int = nature.wood_total()
        var hit: Dictionary = nature.fell_tree(tree_id)
        _check(not hit.is_empty() and int(hit["wood_units"]) > 0,
            "Физическая валка переводит дерево в пень")
        _check(nature.wood_total() == stock,
            "Древесина не возникает и не исчезает при валке")
        _check(nature.canopy_pressure_at(
            Vector2i(int(tree["x"]), int(tree["y"]))) < canopy_before,
            "Валка освобождает свет для молодняка")
        _check(nature.fell_tree(tree_id).is_empty(),
            "Повторная рубка не дублирует древесину")
        var extracted: int = maxi(1, int(hit["wood_units"]) / 2)
        _check(nature.take_fallen_wood(tree_id, extracted),
            "Часть лежащей древесины доступна для будущей перевозки")
        _check(nature.wood_total() == stock - extracted,
            "Изъятие ресурса сохраняет количественный баланс")
        _check(not nature.take_fallen_wood(tree_id, 1000000),
            "Нельзя получить больше древесины, чем осталось")

    if tree_id > 0:
        var target: Dictionary = repeated["nature"].object_at(tree_id)
        var target_cell := Vector2i(int(target["x"]), int(target["y"]))
        repeated["climate"].set_day(2)
        var hazards: Array[Dictionary] = [{
            "cell": target_cell, "severity": 1.0
        }]
        var strikes: Array[Dictionary] = []
        repeated["nature"].advance_day(2, hazards, strikes)
        _check(int(repeated["nature"].object_at(tree_id)["health"]) <
            int(target["health"]),
            "Стихийное событие повреждает живое дерево вне камеры")

    # Один игровой год без кадрового рендера: рост и расселение
    # должны быть одинаковыми при повторном расчёте.
    var saplings_a := _state(9143)
    var saplings_b := _state(9143)
    for day in range(2, 98):
        saplings_a["climate"].set_day(day)
        saplings_b["climate"].set_day(day)
        saplings_a["nature"].advance_day(day)
        saplings_b["nature"].advance_day(day)
    _check(saplings_a["nature"].to_data() == saplings_b["nature"].to_data(),
        "Годовой цикл семян и роста воспроизводится без рендера")

    for y in range(4, 48, 4):
        for x in range(4, 48, 4):
            var cell := Vector2i(x, y)
            var first: float = saplings_a["nature"].ground_cover_at(cell)
            var second: float = saplings_b["nature"].ground_cover_at(cell)
            _check(first >= 0.0 and first <= 1.0,
                "Плотность травы остаётся в физических границах")
            _check(is_equal_approx(first, second),
                "Покров не зависит от камеры и FPS")
            var index: int = saplings_a["hydro"].cell_index(cell)
            if saplings_a["hydro"].has_water(index):
                _check(first == 0.0,
                    "Трава не генерируется в водоёме")

    var rendered_objects := 0
    var rendered_grass := 0
    var rendered_glb := 0
    var chunk_count: Vector2i = original["world"].config.chunk_count()
    for cy in range(chunk_count.y):
        for cx in range(chunk_count.x):
            var visible_chunk := Renderer.create_chunk(
                original["world"], nature, Vector2i(cx, cy))
            for child in visible_chunk.get_children():
                if not (child is MultiMeshInstance3D):
                    continue
                var instance: MultiMeshInstance3D = child
                _check(instance.multimesh.instance_count > 0,
                    "Пустой MultiMesh не расходует GPU-ресурсы")
                rendered_objects += instance.multimesh.instance_count
                if instance.name.begins_with("glb:"):
                    rendered_glb += instance.multimesh.instance_count
                if instance.name == "трава" or instance.name.begins_with("glb:Grass"):
                    rendered_grass += instance.multimesh.instance_count
            visible_chunk.free()
    _check(rendered_objects > 0 and rendered_grass > 0,
        "Трава и природные объекты создаются в видимых чанках")
    _check(rendered_glb > 0,
        "На реальных видимых чанках присутствуют GLB, а не только заглушки")

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
