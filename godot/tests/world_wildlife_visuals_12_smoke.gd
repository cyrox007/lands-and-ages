extends SceneTree
## Проверка 12.9: реальные меши, скелеты и анимации CC0-животных.
## Имитировать результат коробками или пустыми сценами запрещено.

const Actor = preload("res://scripts/wildlife_visual_actor.gd")
const Visuals = preload("res://scripts/wildlife_visuals.gd")
const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Wildlife = preload("res://scripts/wildlife_populations.gd")
const FoodWeb = preload("res://scripts/wildlife_food_web.gd")


func _initialize() -> void:
    # Анимации должны стартовать внутри SceneTree. Применяем
    # отложенный вызов уже после создания окна и дерева сцены.
    call_deferred("_check")


func _check() -> void:
    var models := {}
    for kind in Visuals.MODELS:
        var entry: Dictionary = Visuals.MODELS[kind]
        var path := Visuals.ROOT + str(entry["file"])
        var asset := ResourceLoader.load(path) as PackedScene
        if asset == null:
            push_error("Не установлен настоящий CC0-меш: " + kind)
            quit(1)
            return
        var actor := Actor.new()
        get_root().add_child(actor)
        if not actor.configure(kind, asset, str(entry["source"]),
                float(entry["height"])) \
                or actor.bone_count() < 8 or actor.animation_count() < 1:
            push_error("Нет деформируемого скелета/анимаций: " + kind)
            actor.queue_free()
            quit(1)
            return
        # Скелет и анимации должны работать не только на этапе
        # импорта: проверяем переходы между реальными клипами.
        actor.set_motion("ходьба")
        # Реальный ход анимации требует обработки кадров, а не
        # простого изменения имени текущего состояния.
        var started: float = actor.motion_time()
        actor._process(0.25)
        if actor.motion_time() <= started + 0.001:
            push_error("Анимация не продвинулась по времени: " + kind)
            actor.queue_free()
            quit(1)
            return
        await process_frame
        if actor.state != "ходьба":
            push_error("Не удалось включить анимацию ходьбы: " + kind)
            quit(1)
            return
        actor.set_motion("покой")
        if actor.state != "покой":
            push_error("Не удалось вернуть анимацию покоя: " + kind)
            quit(1)
            return
        var skeleton_count := actor.bone_count()
        var animation_count := actor.animation_count()
        models[kind] = {"bones": skeleton_count,
            "clips": animation_count}
        actor.queue_free()
        await process_frame
    # Кроме индивидуальных мешей, проверяем, что визуальный
    # слой не создаёт животных без физических стад и лимитирует узлы.
    var world = Map.new(Config.new(256, 192, 1729))
    var hydro = Hydro.new(world)
    hydro.rebuild()
    var ground = Surface.new(world, hydro)
    ground.rebuild()
    var climate = Climate.new(world, hydro)
    climate.rebuild()
    var nature = Nature.new(world, hydro, ground, climate)
    nature.generate()
    var fauna = Wildlife.new(world, hydro, ground, climate, nature)
    fauna.generate()
    var predators = FoodWeb.new(world, climate, fauna)
    predators.generate()
    var visuals := Visuals.new()
    get_root().add_child(visuals)
    visuals.configure(world, hydro, ground, fauna, predators)
    var center := Vector2(128.0, 96.0)
    var radius := minf(Visuals.MAX_RENDER_RANGE, 66.0 * 0.62)
    visuals.refresh(center, 66.0, 1.0)
    var candidates: Array[Dictionary] = visuals._nearest_candidates(
        center, radius)
    var selected := mini(Visuals.MAX_VISIBLE, candidates.size())
    if selected == 0 or visuals.active_count() != selected:
        push_error("Ближайшие живые животные не появились у камеры")
        quit(1)
        return
    for i in range(selected):
        if not visuals._visible.has(candidates[i]["key"]):
            push_error("Далёкий регион вытеснил ближайшее животное")
            quit(1)
            return
    var previous := {}
    for key in visuals._visible:
        previous[key] = (visuals._visible[key] as Node3D).position
    # Камера может двигаться внутри ареала, но видимая особь
    # не должна телепортироваться в новую случайную точку.
    visuals.refresh(center + Vector2(1.5, 1.5), 66.0, 1.0)
    for key in visuals._visible:
        if previous.has(key) and previous[key] != (
                visuals._visible[key] as Node3D).position:
            push_error("Дикое животное переместилось вслед за камерой")
            quit(1)
            return
    if visuals.active_count() > Visuals.MAX_VISIBLE \
            or visuals.available_models() != Visuals.MODELS.size():
        push_error("Превышен бюджет или отсутствуют модели")
        quit(1)
        return
    # Многократное перемещение камеры по карте не должно
    # вытеснять ближайшие 3D-модели и создавать лишние узлы.
    var camera_checks := 0
    for next_center in [
            Vector2(55.0, 40.0), Vector2(180.0, 80.0),
            Vector2(120.0, 160.0), Vector2(240.0, 180.0)]:
        var expected: Array[Dictionary] = visuals._nearest_candidates(
            next_center, radius)
        visuals.refresh(next_center, 66.0, 1.0)
        if visuals.active_count() != mini(
                Visuals.MAX_VISIBLE, expected.size()):
            push_error("Камера создала слишком много скелетных животных")
            quit(1)
            return
        for i in range(mini(Visuals.MAX_VISIBLE, expected.size())):
            if not visuals._visible.has(expected[i]["key"]):
                push_error("При перемещении камеры показан не ближайший зверь")
                quit(1)
                return
        camera_checks += 1
    # Наблюдаем реальную локальную прогулку уже существующего
    # животного: соседние клетки обязаны быть сухопутными, а
    # скелетная ходьба включается только в момент перемещения.
    visuals.refresh(center, 66.0, 1.0)
    var prey_before: Dictionary = fauna.to_data()
    var predators_before: Dictionary = predators.to_data()
    var sample_key := ""
    for key in visuals._visible:
        var motion: Dictionary = visuals._movement[key]
        if visuals._walk_target(str(key), motion) != motion["cell"]:
            sample_key = str(key)
            break
    if sample_key.is_empty():
        push_error("На реальной карте нет проходимой клетки для прогулки")
        quit(1)
        return
    var sample := visuals._visible[sample_key] as Node3D
    var initial: Vector3 = sample.position
    var moved := false
    var animated := false
    for step in range(120):
        var prior: Vector3 = sample.position
        visuals._process(0.10)
        if sample.position.distance_to(prior) \
                > Visuals.LOCAL_WALK_SPEED * 0.10 + 0.001:
            push_error("Животное телепортировалось за один кадр")
            quit(1)
            return
        if bool(visuals._movement[sample_key]["walking"]):
            animated = true
            if sample.get("state") != "ходьба":
                push_error("Анимация ходьбы не включилась при движении")
                quit(1)
                return
        if sample.position.distance_to(initial) > 0.1:
            moved = true
    if not animated or not moved \
            or sample.position.distance_to(initial) \
                > Visuals.MAX_WANDER_CELLS + 2.0:
        push_error("Нет достоверной локальной прогулки по суше")
        quit(1)
        return
    if fauna.to_data() != prey_before \
            or predators.to_data() != predators_before:
        push_error("Графическая прогулка изменила число животных")
        quit(1)
        return
    # Настоящее событие дня подаётся через world.gd, а здесь
    # проверяем обработчик: слабая опасность игнорируется, сильная
    # запускает именно анимированный бег по соседней сухой клетке.
    var fleeing_key := ""
    for key in visuals._visible:
        var motion: Dictionary = visuals._movement[key]
        if visuals._flee_target(motion, motion["cell"]) != motion["cell"]:
            fleeing_key = str(key)
            break
    if fleeing_key.is_empty():
        push_error("Не найдено живое животное с безопасным путём бегства")
        quit(1)
        return
    var flee_actor := visuals._visible[fleeing_key] as Node3D
    var flee_cell: Vector2i = visuals._movement[fleeing_key]["cell"]
    if visuals.react_hazards([{
            "kind": "шторм", "cell": flee_cell, "severity": 0.2
            }]) != 0:
        push_error("Слабый ветер ошибочно вызвал паническое бегство")
        quit(1)
        return
    var reacted: int = visuals.react_hazards([{
        "kind": "шторм", "cell": flee_cell, "severity": 0.90
    }])
    if reacted < 1 or reacted > Visuals.MAX_VISIBLE \
            or flee_actor.get("state") != "бег":
        push_error("Реальная опасность не запустила скелетный бег")
        quit(1)
        return
    var fled := false
    var flee_origin: Vector3 = flee_actor.position
    for i in range(24):
        var prior: Vector3 = flee_actor.position
        visuals._process(0.10)
        if flee_actor.position.distance_to(prior) \
                > Visuals.FLEE_SPEED * 0.10 + 0.001:
            push_error("Бегство телепортировало животное")
            quit(1)
            return
        if not bool(visuals._movement[fleeing_key]["flee"]):
            fled = flee_actor.position.distance_to(flee_origin) > 0.1
            break
    if not fled or flee_actor.get("state") != "покой" \
            or fauna.to_data() != prey_before \
            or predators.to_data() != predators_before:
        push_error("Бегство изменило физическую фауну или не завершилось")
        quit(1)
        return
    print("STAGE12-VISUAL-REPORT: ", JSON.stringify({
        "models": models, "visible": visuals.active_count(),
        "max_visible": Visuals.MAX_VISIBLE,
        "nearest_candidates": candidates.size(),
        "camera_checks": camera_checks,
        "walked": moved, "walk_animation": animated,
        "hazard_flee": fled, "flee_actors": reacted,
        "rendering": "реальные GLTF/GLB; ручная визуальная приёмка ещё нужна"
    }))
    print("STAGE12-VISUAL: успешно")
    quit(0)
