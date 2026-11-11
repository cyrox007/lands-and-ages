extends SceneTree
## Визуальная приёмка: настоящий кадр Godot с импортированными
## анимированными животными. Плоскость допустима ТОЛЬКО как пол.

const Actor = preload("res://scripts/wildlife_visual_actor.gd")
const Visuals = preload("res://scripts/wildlife_visuals.gd")


func _initialize() -> void:
    # Кадр снимаем после нескольких кадров активного рендера,
    # а не рисуем внешней библиотекой фиктивные скриншоты.
    call_deferred("_capture")


func _capture() -> void:
    DisplayServer.window_set_size(Vector2i(960, 540))
    var stage := Node3D.new()
    get_root().add_child(stage)

    var camera := Camera3D.new()
    camera.position = Vector3(0.0, 2.45, 6.8)
    camera.current = true
    stage.add_child(camera)
    camera.look_at(Vector3(0.0, 1.0, 0.0))

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-42.0, -32.0, 0.0)
    sun.light_energy = 1.9
    stage.add_child(sun)

    var ambient := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.74, 0.84, 0.91)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(1.0, 0.98, 0.90)
    environment.ambient_light_energy = 0.65
    ambient.environment = environment
    stage.add_child(ambient)

    # Нейтральный пол нужен для проверки контакта лап с землёй.
    # Животные загружаются исключительно из GLTF/GLB ассетов.
    var ground := MeshInstance3D.new()
    var plane := PlaneMesh.new()
    plane.size = Vector2(18.0, 10.0)
    ground.mesh = plane
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.36, 0.48, 0.27)
    ground.material_override = material
    stage.add_child(ground)

    var actors := [
        {"kind": "олень", "x": -2.6},
        {"kind": "волк", "x": -0.85},
        {"kind": "лиса", "x": 0.65},
        {"kind": "кабан", "x": 2.30}
    ]
    for item in actors:
        var species: String = item["kind"]
        var info: Dictionary = Visuals.MODELS[species]
        var scene := ResourceLoader.load(Visuals.ROOT + str(info["file"])) \
            as PackedScene
        var actor := Actor.new()
        if not actor.configure(species, scene, str(info["source"]),
                float(info["height"])):
            push_error("Нельзя показать настоящее животное: " + species)
            quit(1)
            return
        actor.position = Vector3(float(item["x"]), 0.03, 0.0)
        stage.add_child(actor)
        actor.set_motion("ходьба")
    # Реальное движение скелетов проходит перед созданием кадра.
    for i in range(24):
        await process_frame
    var image: Image = get_root().get_texture().get_image()
    if image == null or image.is_empty():
        push_error("Godot не предоставил настоящий кадр")
        quit(1)
        return
    var output := ProjectSettings.globalize_path(
        "res://output/fauna_real_models.png")
    if image.save_png(output) != OK:
        push_error("Не удалось сохранить кадр Godot")
        quit(1)
        return
    print("STAGE12-FAUNA-CAPTURE: успешно; ", output,
        "; размер=", image.get_width(), "x", image.get_height())
    quit(0)
