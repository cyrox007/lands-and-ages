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
    visuals.refresh(Vector2(128.0, 96.0), 66.0, 1.0)
    if visuals.active_count() > Visuals.MAX_VISIBLE \
            or visuals.available_models() != Visuals.MODELS.size():
        push_error("Превышен бюджет или отсутствуют модели")
        quit(1)
        return
    print("STAGE12-VISUAL-REPORT: ", JSON.stringify({
        "models": models, "visible": visuals.active_count(),
        "max_visible": Visuals.MAX_VISIBLE,
        "rendering": "реальные GLTF/GLB; ручная визуальная приёмка ещё нужна"
    }))
    print("STAGE12-VISUAL: успешно")
    quit(0)
