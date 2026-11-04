extends SceneTree
## Проверка этапа 10: природные объекты, физический запас, сохранения.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")
const Felling = preload("res://scripts/nature_felling_visual.gd")
const RenderCache = preload("res://scripts/chunk_render_cache.gd")
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


func _state(world_seed: int = 1729) -> Dictionary:
    var world := Map.new(Config.new(96, 80, world_seed, 16, 32))
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


func _check_natural_deadwood(tree_id: int) -> void:
    # Принудительно подготавливаем старый сухостой, не меняя генератор.
    var simulation := _state()
    var nature: RefCounted = simulation["nature"]
    var world: RefCounted = simulation["world"]
    var initial: Dictionary = nature.to_data()
    var stock_before := 0
    for record in initial["objects"]:
        if int(record[0]) != tree_id:
            continue
        stock_before = int(record[7])
        record[6] = 0
        record[9] = "сухостой"
        record[11] = 1
        record[12] = -1
        break
    _check(nature.load_data(initial),
        "Снимок сухостоя содержит корректную дату гибели")

    var deadline: int = 1 + Nature.DEADWOOD_FALL_DAYS + posmod(
        tree_id * 23 + world.config.world_seed,
        Nature.DEADWOOD_VARIATION_DAYS)
    var fall_day: int = deadline + posmod(tree_id - deadline, 8)
    simulation["climate"].set_day(fall_day)
    var before_events: Array[Dictionary] = []
    nature.tree_felled.connect(func(previous: Dictionary) -> void:
        before_events.append(previous))
    nature.advance_day(fall_day)
    var fallen: Dictionary = nature.object_at(tree_id)
    var expected_rot := 1 if fall_day % 96 < 8 else 0
    _check(fallen["state"] == "пень"
        and int(fallen["wood_units"]) == 0
        and int(fallen["fallen_wood"]) == stock_before - expected_rot,
        "Сухостой падает сам, без дублирования древесины")
    _check(before_events.is_empty(),
        "Естественное падение не выдаёт событие ручной рубки")
    _check(int(fallen["fallen_since_day"]) == fall_day
        and int(fallen["dead_since_day"]) == -1,
        "Дата падения остаётся частью физического состояния")
    _check(nature.fell_tree(tree_id).is_empty(),
        "Повторная рубка естественно поваленного дерева запрещена")

    var restored := Nature.new(world, simulation["hydro"],
        simulation["surface"], simulation["climate"])
    _check(restored.load_data(nature.to_data())
        and restored.to_data() == nature.to_data(),
        "Сроки гибели и падения переживают сохранение и загрузку")

    var rot_day: int = fall_day + Nature.LOG_DECAY_INTERVAL_DAYS
    rot_day += posmod(tree_id - rot_day,
        Nature.LOG_DECAY_INTERVAL_DAYS)
    simulation["climate"].set_day(rot_day)
    nature.advance_day(rot_day)
    _check(int(nature.object_at(tree_id)["fallen_wood"]) ==
        maxi(0, stock_before - expected_rot - 1),
        "Лежащая древесина постепенно разлагается вне кадра")


func _run() -> void:
    var model_names: Array[String] = Models.available_models()
    _check(model_names.size() == 21,
        "Загружены 9 детализированных и 12 резервных CC0 GLB")
    for key in model_names:
        var info: Dictionary = Models.info(key)
        var triangle_limit := 22000 if Models.STYLIZED.has(key) else 1000
        _check(int(info.get("triangles", 999999)) <= triangle_limit,
            "Модель помещается в бюджет полигонов: " + key)
        var mesh: Mesh = info["mesh"]
        var transform: Transform3D = Models.placement(key, Vector3.ZERO)
        var bounds: AABB = mesh.get_aabb()
        var ground: Vector3 = transform * Vector3(0.0, bounds.position.y, 0.0)
        _check(absf(ground.y) < 0.025,
            "Модель нормализована по уровню земли: " + key)
        _check(transform.basis.get_scale().y > 0.0,
            "Масштаб GLB положительный: " + key)
    # Встроенные изображения остаются доступными после переноса проекта.
    for key in Models.STYLIZED.keys():
        var styled_mesh: Mesh = Models.info(key)["mesh"]
        var has_texture := false
        for surface in range(styled_mesh.get_surface_count()):
            var material: Material = styled_mesh.surface_get_material(surface)
            if material is ShaderMaterial:
                var texture: Variant = material.get_shader_parameter("source_texture")
                if texture is Texture2D:
                    has_texture = true
                    break
        _check(has_texture or key == "BirchLight",
            "Внутренние текстуры коры/листвы доступны: " + key)
    var pine_mesh: Mesh = Models.info("PineDetailed")["mesh"]
    _check(pine_mesh.get_surface_count() >= 2,
        "Меш дерева объединяет кору и листву, не теряя поверхности")
    for i in range(pine_mesh.get_surface_count()):
        _check(pine_mesh.surface_get_material(i) is ShaderMaterial,
            "У каждой поверхности работает свой материал GPU-ветра")
    _check(Models.select_tree(30 * 96, 2, 1.0, "сосна") == "PineDetailed",
        "Вблизи взрослой сосне назначена детализированная модель")
    _check(Models.select_tree(30 * 96, 2, 0.1, "сосна") == "PineLight",
        "Вдали сосна переключается на облегчённую модель")
    _check(Models.select_tree(30 * 96, 2, 0.1, "берёза") == "BirchLight",
        "Вдали берёза использует отдельный низкополигональный LOD")
    _check(Models.select_tree(30 * 96, 2, 1.0, "дуб") == "OakDetailed",
        "У дуба собственная широколиственная модель")
    _check(Models.select_tree(30 * 96, 2, 1.0, "берёза", true)
        == "DeadBirch", "Зимняя берёза сохраняет ветвистую геометрию")
    _check(Models.select_tree(30 * 96, 2, 1.0, "дуб", false,
        "сухостой") == "DeadTree", "Сухостой не заменяется цилиндром")

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
        _check_natural_deadwood(tree_id)


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
        var falling := Felling.make_visual(original["world"], tree)
        _check(falling != null and falling.get_child_count() == 1,
            "Временная анимация собирается из реальной GLB-модели")
        if falling != null:
            _check(falling.get_child(0) is MeshInstance3D,
                "Валка использует один временный MeshInstance3D")
            falling.free()
        var fell_events: Array[Dictionary] = []
        nature.tree_felled.connect(func(previous: Dictionary) -> void:
            fell_events.append(previous))
        var previous_revision: int = nature.revision
        var hit: Dictionary = nature.fell_tree(tree_id)
        _check(nature.revision == previous_revision + 1,
            "Валка инвалидирует только затронутые природные чанки")
        _check(fell_events.size() == 1 and fell_events[0] == tree,
            "Визуальное событие содержит предыдущее дерево ровно один раз")
        _check(not hit.is_empty() and int(hit["wood_units"]) > 0,
            "Физическая валка переводит дерево в пень")
        _check(nature.wood_total() == stock,
            "Древесина не возникает и не исчезает при валке")
        _check(nature.canopy_pressure_at(
            Vector2i(int(tree["x"]), int(tree["y"]))) < canopy_before,
            "Валка освобождает свет для молодняка")
        _check(nature.fell_tree(tree_id).is_empty(),
            "Повторная рубка не дублирует древесину")
        _check(fell_events.size() == 1,
            "Повторная рубка не запускает падение заново")
        var tree_chunk: Vector2i = original["world"].config.chunk_of(
            Vector2i(int(tree["x"]), int(tree["y"])))
        var fallen_chunk := Renderer.create_chunk(
            original["world"], nature, tree_chunk)
        var found_log := false
        for child in fallen_chunk.get_children():
            if child.name == "бревно":
                found_log = true
        _check(found_log, "После физической валки отображается лежащее бревно")
        fallen_chunk.free()
        var extracted: int = maxi(1, int(hit["wood_units"]) / 2)
        _check(nature.take_fallen_wood(tree_id, extracted),
            "Часть лежащей древесины доступна для будущей перевозки")
        _check(nature.wood_total() == stock - extracted,
            "Изъятие ресурса сохраняет количественный баланс")
        _check(not nature.take_fallen_wood(tree_id, 1000000),
            "Нельзя получить больше древесины, чем осталось")
        var physical_remaining: int = nature.object_at(tree_id)["fallen_wood"]
        _check(nature.take_fallen_wood(tree_id, physical_remaining),
            "Можно забрать последний остаток древесины без повторной валки")
        var empty_chunk := Renderer.create_chunk(
            original["world"], nature, tree_chunk)
        var lingering_log := false
        for child in empty_chunk.get_children():
            if child.name == "бревно":
                lingering_log = true
        _check(not lingering_log,
            "После изъятия ресурса лежащее бревно исчезает, пень остаётся")
        empty_chunk.free()

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
    var rendered_stylized_trees := 0
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
                if instance.name.begins_with("glb_"):
                    rendered_glb += instance.multimesh.instance_count
                    if Models.STYLIZED.has(instance.name.substr(4)):
                        rendered_stylized_trees += instance.multimesh.instance_count
                if instance.name == "трава" or instance.name.begins_with("glb_Grass"):
                    rendered_grass += instance.multimesh.instance_count
            visible_chunk.free()
    _check(rendered_objects > 0 and rendered_grass > 0,
        "Трава и природные объекты создаются в видимых чанках")
    _check(rendered_glb > 0 and rendered_stylized_trees > 0,
        "На видимых чанках присутствуют новые деревья, а не только заглушки")

    var cache := RenderCache.new()
    var cached_chunk := Vector2i(2, 3)
    cache.put(cached_chunk, Node3D.new())
    _check(cache.has(cached_chunk),
        "Чанк природы может находиться в ограниченном GPU-кеше")
    cache.discard(cached_chunk)
    _check(not cache.has(cached_chunk),
        "Изменение природы удаляет только устаревший чанк из кеша")

    if tree_id > 0:
        var hit_world := _state()
        var hit_nature: RefCounted = hit_world["nature"]
        var initial_tree: Dictionary = hit_nature.object_at(tree_id)
        var total_before: int = hit_nature.wood_total()
        _check(hit_nature.hit_tree(tree_id, 0).is_empty(),
            "Нулевой удар не изменяет состояние")
        _check(hit_nature.hit_tree(tree_id, 1001).is_empty(),
            "Недопустимая сила удара отклоняется")

        var strike_events: Array[int] = []
        hit_nature.tree_struck.connect(
            func(_before: Dictionary, progress: int) -> void:
                strike_events.append(progress))
        var first_hit: Dictionary = hit_nature.hit_tree(tree_id, 250)
        _check(first_hit.get("cut_progress", -1) == 250,
            "Первый удар увеличивает физический прогресс рубки")
        _check(hit_nature.wood_total() == total_before,
            "Удары не создают и не уменьшают древесный запас")
        _check(strike_events == [250],
            "Повреждение передаётся единичным событием")

        var chips := Felling.make_hit_visual(hit_world["world"], initial_tree)
        _check(chips != null, "Одноразовые щепки создаются только для дерева")
        if chips != null:
            _check(chips.get_child_count() == 1,
                "Щепки используют один меш вместо множества нод")
            chips.free()

        var struck_cell := Vector2i(int(initial_tree["x"]),
            int(initial_tree["y"]))
        var struck_chunk: Vector2i = hit_world["world"].config.chunk_of(
            struck_cell)
        var damaged_visual := Renderer.create_chunk(
            hit_world["world"], hit_nature, struck_chunk)
        _check(damaged_visual.get_node_or_null("зарубка") != null,
            "На повреждённом дереве видна сохраняемая зарубка")
        damaged_visual.free()

        var damaged_snapshot: Dictionary = Save.capture(hit_world)
        var damaged_restore: Dictionary = Save.restore(damaged_snapshot)
        _check(not damaged_restore.is_empty(),
            "Мир с частично срубленным деревом загружается")
        if not damaged_restore.is_empty():
            var recovered: RefCounted = damaged_restore["nature"]
            _check(int(recovered.object_at(tree_id)["cut_progress"]) == 250,
                "Прогресс рубки сохраняется после перезапуска")
            var struck_after_restore: Array[int] = []
            recovered.tree_struck.connect(
                func(_previous: Dictionary, progress: int) -> void:
                    struck_after_restore.append(progress))
            recovered.hit_tree(tree_id, 250)
            recovered.hit_tree(tree_id, 250)
            var finishing: Dictionary = recovered.hit_tree(tree_id, 250)
            _check(struck_after_restore == [500, 750],
                "После загрузки продолжение ударов детерминировано")
            _check(finishing.get("felled", false),
                "Четвёртый удар завершает физическую валку")
            _check(recovered.wood_total() == total_before,
                "Все удары вместе не нарушают баланс древесины")
            _check(recovered.hit_tree(tree_id, 250).is_empty(),
                "Пень нельзя повторно рубить")

        # Форматы v1/v2 загружаются без дат разложения.
        var old_snapshot: Dictionary = damaged_snapshot.duplicate(true)
        old_snapshot["nature"]["version"] = 1
        for record in old_snapshot["nature"]["objects"]:
            record.resize(10)
        var old_restore: Dictionary = Save.restore(old_snapshot)
        _check(not old_restore.is_empty(),
            "Старые сохранения версии 1 остаются читаемыми")
        if not old_restore.is_empty():
            _check(int(old_restore["nature"].object_at(
                tree_id)["cut_progress"]) == 0,
                "У старых сохранений прогресс рубки равен нулю")

        var v2_snapshot: Dictionary = damaged_snapshot.duplicate(true)
        v2_snapshot["nature"]["version"] = 2
        for record in v2_snapshot["nature"]["objects"]:
            record.resize(11)
        var v2_restore: Dictionary = Save.restore(v2_snapshot)
        _check(not v2_restore.is_empty(),
            "Сохранения версии 2 с прогрессом рубки загружаются")
        if not v2_restore.is_empty():
            _check(int(v2_restore["nature"].object_at(
                tree_id)["cut_progress"]) == 250,
                "Промежуточные сохранения не теряют зарубки")

        var invalid_snapshot: Dictionary = damaged_snapshot.duplicate(true)
        invalid_snapshot["nature"]["objects"][0][10] = 1000
        _check(Save.restore(invalid_snapshot).is_empty(),
            "Недопустимый прогресс в сохранении отклоняется")

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
    var json_snapshot: Dictionary = JSON.parse_string(JSON.stringify(snapshot))
    var json_restored: Dictionary = Save.restore(json_snapshot)
    _check(not json_restored.is_empty(),
        "Мир с растительностью восстанавливается после записи и чтения JSON")
    if not json_restored.is_empty():
        _check(json_restored["nature"].to_data() == nature.to_data(),
            "JSON сохраняет все природные объекты без изменений")
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
