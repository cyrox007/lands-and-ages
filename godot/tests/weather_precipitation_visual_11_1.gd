extends SceneTree
## 11.1 — реальные контрольные PNG разных осадков через Godot OpenGL.
## Программный GL проверяет внешний вывод, но не заменяет
## художественную оценку и замеры видеокарты ПК/Android.

const Visual = preload("res://scripts/weather_visual_state.gd")
const Effects = preload("res://scripts/weather_fx_controller.gd")
const VIEW_SIZE := Vector2i(1280, 720)

var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
    # Проверки собираются по всем кадрам, чтобы ошибка одного
    # режима не помешала записать остальные диагностические PNG.
    if not ok:
        failures.append(message)


func _output_path() -> String:
    # Адрес артефактов задаёт CI. Локальная отладка использует
    # папку user:// без привязки к конкретной рабочей машине.
    for argument in OS.get_cmdline_user_args():
        if argument.begins_with("--out="):
            return argument.trim_prefix("--out=")
    return "user://weather-11-1"


func _scene() -> Node3D:
    # Сравнимые камера, освещение и ориентиры остаются одинаковыми
    # для мороси, ливня, снега, метели и града.
    root.size = VIEW_SIZE
    var stage := Node3D.new()
    stage.name = "Приёмка осадков"
    root.add_child(stage)

    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color(0.25, 0.36, 0.44)
    stage.add_child(environment)

    var ground := MeshInstance3D.new()
    var plane := PlaneMesh.new()
    plane.size = Vector2(105, 105)
    ground.mesh = plane
    var soil := StandardMaterial3D.new()
    soil.albedo_color = Color(0.30, 0.38, 0.33)
    soil.roughness = 0.96
    ground.material_override = soil
    stage.add_child(ground)

    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-55.0, 22.0, 0.0)
    light.light_energy = 1.1
    stage.add_child(light)

    # Немного статичных ориентиров помогает оценить крупность
    # частиц и воспринимаемую плотность осадков при том же зуме.
    for i in range(9):
        var post := MeshInstance3D.new()
        var mesh := CylinderMesh.new()
        mesh.top_radius = 0.16
        mesh.bottom_radius = 0.21
        mesh.height = 3.5 + float(i % 3)
        post.mesh = mesh
        post.position = Vector3(float(i % 3) * 7.0 - 7.0,
            mesh.height * 0.5, float(i / 3) * 8.0 - 8.0)
        var material := StandardMaterial3D.new()
        material.albedo_color = Color(0.41, 0.34, 0.27)
        post.material_override = material
        stage.add_child(post)

    var camera := Camera3D.new()
    camera.position = Vector3(18.0, 16.0, 26.0)
    stage.add_child(camera)
    camera.look_at(Vector3(0.0, 5.0, 0.0))
    camera.current = true
    return stage


func _weather(temp: float, rain: float, snow: float,
        storm: float, gust: float) -> Dictionary:
    # Графика получает физически допустимый снимок, а не
    # самостоятельно выбирает тип или генерирует осадки.
    return Visual.from_weather({
        "temperature": temp, "rainfall": rain, "snowfall": snow,
        "storm_intensity": storm, "humidity": 0.86,
        "wind_speed": gust * 0.8, "wind_gust": gust,
        "wind_direction_x": 1.0, "wind_direction_y": 0.20
    })


func _render_weather(fx: Node3D, folder: String,
        name: String, state: Dictionary) -> Dictionary:
    # Полностью скрываем старые виды, чтобы снежинки длинной
    # жизни не оставались на кадре следующего режима.
    fx.set_effects_enabled(false)
    fx.apply_snapshot(state, Vector2.ZERO, 0.0, 30.0, 1729)
    await process_frame
    fx.set_effects_enabled(true)
    fx.apply_snapshot(state, Vector2.ZERO, 0.0, 30.0, 1729)

    # GPU-эмиттеру нужен физический цикл кадров для наполнения.
    # Это время только для съёмки и не является игровым таймером.
    await create_timer(2.5).timeout
    await process_frame
    await process_frame
    var shot := root.get_texture().get_image()
    var filename := folder.path_join(name + ".png")
    var saved := shot.save_png(filename)
    _check(saved == OK and FileAccess.file_exists(filename),
        "Сохранён кадр " + name)
    _check(shot.get_width() == VIEW_SIZE.x and
        shot.get_height() == VIEW_SIZE.y,
        "Кадр " + name + " имеет 1280×720")
    return {
        "name": name, "file": name + ".png",
        "bytes": FileAccess.get_file_as_bytes(filename).size(),
        "rain": state.get("rain", 0.0),
        "snow": state.get("snow", 0.0),
        "hail": state.get("hail", 0.0),
        "wet_snow": state.get("wet_snow", 0.0),
        "blizzard": state.get("blizzard", 0.0)
    }


func _run() -> void:
    # Единая сцена и неизменяемая камера позволяют автору
    # сравнить все первоначальные типы осадков бок о бок.
    var folder := _output_path()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
    var stage := _scene()
    var fx := Effects.new()
    stage.add_child(fx)
    fx.set_quality(2)
    var scenarios := [
        {"name": "морось", "state": _weather(14.0, 0.22, 0.0, 0.0, 4.0)},
        {"name": "дождь", "state": _weather(14.0, 0.95, 0.0, 0.10, 7.0)},
        {"name": "ливень", "state": _weather(14.0, 2.5, 0.0, 0.45, 17.0)},
        {"name": "снег", "state": _weather(-7.0, 0.0, 1.4, 0.0, 5.0)},
        {"name": "мокрый_снег", "state": _weather(0.4, 0.85, 0.75, 0.0, 9.0)},
        {"name": "метель", "state": _weather(-9.0, 0.0, 1.7, 0.0, 30.0)},
        {"name": "град", "state": _weather(13.0, 2.3, 0.0, 0.91, 25.0)}
    ]
    var images := []
    for scenario in scenarios:
        images.append(await _render_weather(fx, folder,
            scenario["name"], scenario["state"]))
    for entry in images:
        _check(int(entry["bytes"]) > 7000,
            "Отрисовка " + str(entry["name"]) + " не пуста")
    var manifest := {
        "stage": "11.1", "renderer": "Godot Compatibility / OpenGL",
        "hardware_accepted": false, "artistic_review_required": true,
        "captures": images, "checks_passed": failures.is_empty()
    }
    var report := FileAccess.open(folder.path_join("manifest.json"),
        FileAccess.WRITE)
    if report == null:
        failures.append("Невозможно создать манифест снимков")
    else:
        report.store_string(JSON.stringify(manifest, "\t"))
        report.close()
    if not failures.is_empty():
        for item in failures:
            printerr("Этап 11.1/GL: ", item)
        quit(1)
        return
    print("Этап 11.1/GL: семь контрольных кадров осадков — успешно")
    quit(0)


func _initialize() -> void:
    # Пуск кадра откладываем до готовности оконного SceneTree.
    call_deferred("_run")
