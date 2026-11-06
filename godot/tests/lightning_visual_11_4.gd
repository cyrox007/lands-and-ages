extends SceneTree
## Этап 11.4: сравнение настоящего кадра Godot до удара и
## с каналом молнии. Программный OpenGL не равен приёмке GPU.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const LightningFX = preload("res://scripts/lightning_fx_controller.gd")
const CAPTURE_SIZE := Vector2i(1280, 720)

var _errors: Array[String] = []


func _check(valid: bool, reason: String) -> void:
	# Фиксируем проблемы отдельных кадров и файлов отдельно,
	# чтобы CI показывал причину отсутствующей визуализации.
	if not valid:
		_errors.append(reason)


func _output_folder() -> String:
	# Путь задаётся CI, при ручном запуске снимки останутся
	# в user:// и не будут записаны в исходники проекта.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			return arg.trim_prefix("--out=")
	return "user://lightning-11-4"


func _make_scene() -> Dictionary:
	# Неизменные камера, земля и макеты деревьев дают возможность
	# сравнить вспышку и канал на одном и том же фоне.
	root.size = CAPTURE_SIZE
	var map := Map.new(Config.new(32, 24, 1729, 8, 16))
	var scene := Node3D.new()
	scene.name = "Приёмка молний"
	root.add_child(scene)
	var world_env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.09, 0.14, 0.21)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.36, 0.43, 0.52)
	environment.ambient_light_energy = 0.3
	world_env.environment = environment
	scene.add_child(world_env)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(75, 75)
	ground.mesh = plane
	ground.position = Vector3(16, 0, 12)
	var soil := StandardMaterial3D.new()
	soil.albedo_color = Color(0.22, 0.29, 0.31)
	ground.material_override = soil
	scene.add_child(ground)

	for index in range(8):
		# Простые геометрические ориентиры не подменяют
		# художественные модели леса, но показывают масштаб.
		var trunk := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.32
		cylinder.bottom_radius = 0.48
		cylinder.height = 5.5
		trunk.mesh = cylinder
		trunk.position = Vector3(
			5.0 + float(index % 4) * 7.0, 2.75,
			6.0 + float(floori(float(index) / 4.0)) * 13.0)
		scene.add_child(trunk)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.35
	sun.rotation_degrees = Vector3(-55.0, 40.0, 0.0)
	scene.add_child(sun)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 77.0
	camera.position = Vector3(55, 39, 55)
	scene.add_child(camera)
	camera.look_at(Vector3(16, 18, 12))
	camera.make_current()

	var fx := LightningFX.new()
	scene.add_child(fx)
	return {"scene": scene, "map": map, "fx": fx}


func _save_capture(folder: String, name: String) -> Image:
	# Снимок снимается после отрисованного игрового кадра,
	# а не из заранее нарисованного PNG.
	await process_frame
	await process_frame
	var image: Image = root.get_texture().get_image()
	_check(image.get_width() == CAPTURE_SIZE.x and
		image.get_height() == CAPTURE_SIZE.y,
		"Размер кадра молнии должен быть 1280×720")
	var path := folder.path_join(name + ".png")
	_check(image.save_png(path) == OK and FileAccess.file_exists(path),
		"Невозможно сохранить " + name)
	return image


func _pixel_difference(before: Image, after: Image) -> int:
	# Сравниваем разряд с тем же ракурсом без молнии;
	# число изменившихся пикселей доказывает реальный вывод.
	var count := 0
	for y in range(70, CAPTURE_SIZE.y - 40, 8):
		for x in range(40, CAPTURE_SIZE.x - 40, 8):
			var a: Color = before.get_pixel(x, y)
			var b: Color = after.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.17:
				count += 1
	return count


func _run() -> void:
	# Все эффекты строятся из одного физического события в
	# диагностической сцене и не изменяют географическую модель.
	var folder := _output_folder()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var state := _make_scene()
	var fx: Node3D = state["fx"]
	var map: RefCounted = state["map"]
	var before: Image = await _save_capture(folder, "до_удара")
	var hit: Dictionary = {
		"day": 7, "cell": Vector2i(16, 12),
		"cause": "молния", "strength": 0.91,
		"ignition_potential": 0.17
	}
	var events: Array[Dictionary] = [hit]
	_check(fx.show_strikes(events, map, Vector2(16, 12), 52, 7) == 1,
		"Для съёмки запущен именно зарегистрированный удар")
	var after: Image = await _save_capture(folder, "разряд")
	var changed := _pixel_difference(before, after)
	_check(changed >= 15,
		"Молния и свет должны менять изображение заметно")
	var report := {
		"stage": "11.4", "renderer": "Godot Compatibility/OpenGL",
		"hardware_accepted": false, "artistic_review_required": true,
		"captures": ["до_удара.png", "разряд.png"],
		"changed_sample_pixels": changed,
		"checks_passed": _errors.is_empty()
	}
	var file := FileAccess.open(folder.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		_errors.append("Нет файла контрольного манифеста")
	else:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	if _errors.is_empty():
		print("Этап 11.4/GL: видимый разряд и сравнение кадров — успешно")
		quit(0)
		return
	for reason in _errors:
		printerr("Этап 11.4/GL: ", reason)
	quit(1)


func _initialize() -> void:
	# Съёмку запускаем после создания оконного SceneTree.
	call_deferred("_run")
