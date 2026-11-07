extends SceneTree
## 11.5/F6 — настоящее возгорание и камерные эффекты пожара.
## Проверяем физический источник, пламя/дым, звук, свет, LOD,
## паузу и полную неизменность WorldSave после визуального цикла.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Renderer = preload("res://scripts/nature_renderer.gd")
const Controller = preload("res://scripts/fire_presentation_controller.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Save = preload("res://scripts/world_save.gd")
const View = preload("res://scripts/world.gd")

var failures: Array[String] = []


func _check(value: bool, reason: String) -> void:
	# Все ошибки попадают в один CI-отчёт: выключенный звук
	# не должен скрыть регрессию физического WorldSave.
	if not value:
		failures.append(reason)


func _models() -> Dictionary:
	# Настоящие климат, вода и лес дают проверяемый физический
	# источник, а не подложенный отдельный список огненных FX.
	var world := Map.new(Config.new(96, 80, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Погодный первый день создан")
	_check(surface.advance_climate_day(climate), "Почва первого дня создана")
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Настоящий лес создан")
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "fire": fire,
		"weather": Weather.new(world, climate, surface, hydro),
		"natural": Processes.new(world, hydro, surface, climate),
		"disasters": Disasters.new(world, hydro, surface, climate)
	}


func _tree(nature: RefCounted) -> Dictionary:
	# Выбираем взрослое дерево с настоящим конечным топливом,
	# как в проверенном сценарии первого физического пожара.
	for record in nature.to_data()["objects"]:
		if record[1] != "дерево" or record[9] != "целое":
			continue
		if int(record[3]) < 10 or int(record[4]) < 10 \
				or int(record[3]) >= 86 or int(record[4]) >= 70 \
				or int(record[7]) < 35:
			continue
		return nature.object_at(int(record[0]))
	return {}


func _day(state: Dictionary, day: int, moisture: float) -> void:
	# Дневной FireRegistry имеет право гореть только после
	# климатического и природного расчёта очередных суток.
	var climate: RefCounted = state["climate"]
	var surface: RefCounted = state["surface"]
	_check(climate.set_day(day), "Климат пересчитан для дня %d" % day)
	_check(surface.advance_climate_day(climate),
		"Почва пересчитана для дня %d" % day)
	surface._moisture.fill(moisture)
	surface._snow.fill(0.0)
	climate._rain.fill(0.0)
	state["nature"].advance_day(day)


func _real_fire(controller: Node3D) -> void:
	var state: Dictionary = _models()
	var fire: RefCounted = state["fire"]
	var nature: RefCounted = state["nature"]
	var world: RefCounted = state["world"]
	var source: Dictionary = _tree(nature)
	if source.is_empty():
		_check(false, "Есть взрослое горючее дерево")
		return
	var id: int = int(source["id"])
	var cell := Vector2i(int(source["x"]), int(source["y"]))
	var point := Vector2(cell) + Vector2(0.5, 0.5)
	var chunk: Vector2i = world.config.chunk_of(cell)
	var initial: Dictionary = Save.capture(state)
	_check(fire.burning_visual_strength(id) == 0.0,
		"До физического поджога нет силы пламени")
	controller.sync_view(0.4, fire, nature, world, point, 50.0)
	_check(controller.debug_budget()["source_id"] == -1
		and not controller._light.visible,
		"Пустой физический реестр не создаёт свет и звук")
	var cold_scans: int = controller.debug_budget()["scans"]
	for frame in range(180):
		controller.sync_view(1.0 / 60.0, fire, nature, world, point, 50.0)
	_check(int(controller.debug_budget()["scans"]) - cold_scans < 16,
		"Камера не сканирует пустой пожарный реестр каждый кадр")

	_day(state, 2, 0.02)
	var events: Array[Dictionary] = fire.advance_day(2, [], cell)
	_check(not events.is_empty() and fire.is_burning(id),
		"Дерево загорелось через настоящий FireRegistry")
	var strength: float = fire.burning_visual_strength(id)
	_check(strength >= 0.25 and strength <= 1.0,
		"Визуальная интенсивность ограничена реальным топливом")
	var before_fx: Dictionary = Save.capture(state)

	var scene: Node3D = Renderer.create_chunk(world, nature, chunk, 1.0, fire)
	var flame := scene.get_node_or_null("пламя") as MultiMeshInstance3D
	var smoke := scene.get_node_or_null("дым") as MultiMeshInstance3D
	_check(flame != null and smoke != null,
		"Физический очаг создал настоящие огненный и дымовой MultiMesh")
	if flame != null:
		var custom: Color = flame.multimesh.get_instance_custom_data(0)
		_check(is_equal_approx(custom.a, strength),
			"Размер и визуальное состояние огня зависят от топлива")
	scene.free()

	controller.sync_view(0.4, fire, nature, world, point, 48.0)
	var report: Dictionary = controller.debug_budget()
	_check(int(report["source_id"]) == id
		and int(report["lights"]) == 1
		and int(report["audio_players"]) == 1,
		"Включён только один локальный свет и один звук настоящего очага")
	_check(controller._light.visible
		and controller._light.position.distance_to(
			world.config.to_scene(point, world.height_at(point)) +
			Vector3.UP * 1.3) < 0.001,
		"Освещение находится у настоящего ствола, а не у камеры")
	_check(controller._audio.stream is AudioStreamWAV
		and controller._sound.data.size() ==
			roundi(float(Controller.SOUND_RATE) * Controller.SOUND_SECONDS) * 2,
		"Треск синтезирован один раз из оригинального моно PCM")
	_check(controller._audio.playing,
		"Пространственный треск включается только у видимого огня")

	controller.set_quality(0)
	_check(not controller._light.visible
		and controller._audio != null,
		"Экономный режим выключил свет без удаления аудиоплеера")
	controller.set_quality(2)
	_check(controller._light.visible,
		"Возврат подробного профиля восстановил локальный свет")

	paused = true
	controller._process(0.3)
	_check(controller._audio.stream_paused
		and controller._light.light_energy == 0.0,
		"Пауза останавливает звук и пульсацию света")
	paused = false
	controller._process(0.3)
	_check(not controller._audio.stream_paused
		and controller._light.light_energy > 0.0,
		"После паузы свет и звук продолжаются без новой физики")

	controller.sync_view(0.4, fire, nature, world, point, 102.0)
	_check(controller.debug_budget()["source_id"] == -1
		and not controller._audio.playing,
		"Дальний LOD освобождает локальный свет и звук")
	controller.sync_view(0.4, fire, nature, world, point, 48.0)
	_check(controller.debug_budget()["source_id"] == id,
		"Возврат камеры показывает существующий, а не новый пожар")
	_check(Save.capture(state) == before_fx,
		"Пауза, звук, свет, качество и камера не меняют WorldSave")

	# Реальный дождевой эффект останавливает огонь; после
	# потухшего физического источника новые эффекты невозможны.
	_day(state, 3, 1.0)
	fire.advance_day(3)
	_check(not fire.is_burning(id),
		"Мокрый грунт физически тушит пожар")
	controller.sync_view(0.4, fire, nature, world, point, 48.0)
	_check(controller.debug_budget()["source_id"] == -1
		and not controller._light.visible
		and not controller._audio.playing,
		"После тушения нет фиктивного света или треска")
	_check(not initial.is_empty() and not Save.capture(state).is_empty(),
		"Физический мир остаётся сохраняемым после тушения")


func _visual_cap() -> void:
	# Насыщенный искусственный лес — только испытательный набор.
	# Физические записи FireRegistry остаются владельцами топлива;
	# мы проверяем, что GPU не размножает свет/дым пропорционально
	# максимальным 1024 потенциальным очагам мира.
	var state: Dictionary = _models()
	var nature: RefCounted = state["nature"]
	var fire: RefCounted = state["fire"]
	var world: RefCounted = state["world"]
	nature._objects.clear()
	nature._chunks.clear()
	var chunk := Vector2i(2, 2)
	for offset in range(24):
		var cell := Vector2i(32 + offset % 6, 32 + offset / 6)
		var id: int = cell.y * world.config.width + cell.x + 1
		var item := {
			"id": id, "kind": "дерево", "species": "сосна",
			"x": cell.x, "y": cell.y, "age_days": 20 * 96,
			"health": 1000, "wood_units": 80,
			"fallen_wood": 0, "state": "целое",
			"cut_progress": 0, "dead_since_day": -1,
			"fallen_since_day": -1, "fall_angle_deg": -1,
			"radius": 0.21
		}
		nature._objects[id] = item
		nature._index(item)
		# Прямой тестовый fixture воспроизводит допустимые записи
		# сериализуемого реестра, но не является вторым игровым огнём.
		fire._burning[id] = {"fuel": 500, "since": 1}
	_check(fire.burning_count() == 24,
		"Физических очагов больше лимита рендера")
	var close := Renderer.create_chunk(world, nature, chunk, 1.0, fire)
	var far := Renderer.create_chunk(world, nature, chunk, 0.1, fire)
	for kind in ["пламя", "дым"]:
		var near_node := close.get_node_or_null(kind) as MultiMeshInstance3D
		var distant_node := far.get_node_or_null(kind) as MultiMeshInstance3D
		_check(near_node != null and distant_node != null,
			"Дым и огонь доступны в обоих уровнях детализации")
		if near_node != null and distant_node != null:
			_check(near_node.multimesh.instance_count ==
				Renderer.MAX_FLAME_PLUMES_NEAR
				and distant_node.multimesh.instance_count ==
				Renderer.MAX_FLAME_PLUMES_FAR,
				"LOD ограничивает видимые огненные экземпляры, не очаги")
	_check(fire.burning_count() == 24,
		"Скрытие лишних языков пламени не уничтожило физический огонь")
	close.free()
	far.free()


func _live_scene() -> void:
	# Проверяем сборку настоящего World, чтобы контроллер не жил
	# только в автономном тесте и не был забытым модулем.
	var view := View.new()
	view.stream_camera = false
	root.add_child(view)
	_check(view._fire_presentation != null
		and view._fire_presentation._light is OmniLight3D
		and view._fire_presentation._audio is AudioStreamPlayer3D,
		"Игровая сцена создала один постоянный свет и звук пожара")
	var saved: Dictionary = Save.capture(view._storage_models())
	_check(not saved.is_empty(), "Живая сцена имеет полный WorldSave")
	var fx: Node3D = view._fire_presentation
	fx.clear_visuals()
	_check(Save.capture(view._storage_models()) == saved,
		"Очистка FX после загрузки не затрагивает физический мир")
	view.queue_free()


func _run() -> void:
	var controller := Controller.new()
	root.add_child(controller)
	_real_fire(controller)
	_visual_cap()
	controller.queue_free()
	_live_scene()
	await process_frame
	if not failures.is_empty():
		for issue in failures:
			push_error("11.5/F6: " + issue)
		quit(1)
		return
	print("11.5/F6: пламя, дым, свет, треск, пауза, LOD и WorldSave — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
