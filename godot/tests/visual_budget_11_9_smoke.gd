extends SceneTree
## 11.9/P2 — полный визуальный бюджет при смене качества и сезонов.
## Показатели headless отражают контракт CPU/GPU-слотов, не FPS телефона.

const Budget = preload("res://scripts/world_visual_budget.gd")
const Atmosphere = preload("res://scripts/weather_atmosphere_controller.gd")
const View = preload("res://scripts/world.gd")
const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const NatureRenderer = preload("res://scripts/nature_renderer.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Save = preload("res://scripts/world_save.gd")
const RenderCache = preload("res://scripts/chunk_render_cache.gd")

var errors: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# CI сообщает каждый невыполненный физический и визуальный
	# контракт, не завершая сценарий после первой неудачи.
	if not ok:
		errors.append(reason)


func _policy() -> void:
	# Выбор автора — верхний предел, дальний обзор не повышает
	# качество, а единичная просадка не запускает смену профиля.
	var budget := Budget.new()
	_check(budget.resolve(2, 38.0, 0.0) == 2,
		"На ближнем плане подробный профиль доступен")
	_check(budget.resolve(2, 77.0, 0.0) == 1,
		"На среднем плане выделяется не более стандартного качества")
	_check(budget.resolve(2, 99.0, 0.0) == 0,
		"На дальнем плане принудительно снижается GPU-бюджет")
	_check(budget.resolve(0, 35.0, 0.0) == 0,
		"Автоматика не повышает пользовательский экономный профиль")
	_check(budget.resolve(2, 35.0, 31.0) == 2,
		"Один медленный кадр не меняет настройки")
	_check(budget.resolve(2, 35.0, 31.0) == 0,
		"Повторный p95 выше 29 мс снижает качество")
	for sample in range(7):
		_check(budget.resolve(2, 35.0, 16.0) == 0,
			"Качество не скачет до истечения периода восстановления")
	_check(budget.resolve(2, 35.0, 16.0) == 1,
		"После устойчивого FPS качество восстанавливается постепенно")
	for sample in range(8):
		budget.resolve(2, 35.0, 16.0)
	_check(budget.effective_quality == 2,
		"Ресурсный потолок возвращается после стабильных выборок")
	_check(Budget.nature_refresh_limit(31.0) == 1
		and Budget.nature_refresh_limit(16.0) == 2,
		"Перегрузка уменьшает обновления природы без голодания")
	_check(is_equal_approx(Budget.weather_sync_interval(40.0, 16.0), 0.35)
		and is_equal_approx(Budget.weather_sync_interval(78.0, 16.0), 0.65)
		and is_equal_approx(Budget.weather_sync_interval(99.0, 16.0), 0.95),
		"Частота климатических GPU-снимков зависит от масштаба")
	_check(Budget.particle_limit(0) < Budget.particle_limit(1)
		and Budget.particle_limit(1) < Budget.particle_limit(2)
		and Budget.particle_limit(2) == Budget.MAX_GPU_PARTICLES,
		"Лимиты реально выделенных частиц строго возрастают")


func _season_world(seed: int, day: int) -> Dictionary:
	# Все физические подсистемы создаются в одном календарном
	# дне: полный WorldSave должен быть внутренне согласован.
	var world := Map.new(Config.new(64, 48, seed, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(day), "Сезонный климат установлен")
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Сезонный природный мир создан")
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature,
		"weather": Weather.new(world, climate, surface, hydro),
		"natural": Natural.new(world, hydro, surface, climate),
		"disasters": Disasters.new(world, hydro, surface, climate),
		"fire": Fire.new(world, hydro, surface, climate, nature)
	}


func _emitter_sum(atmosphere: Node3D) -> int:
	# Считаем именно фактическое GPUParticles3D.amount, потому что
	# amount_ratio не уменьшает уже выделенные GPU-буферы.
	var count := 0
	for child in atmosphere.precipitation.get_children():
		if child is GPUParticles3D:
			count += child.amount
	return count


func _seasons(atmosphere: Node3D) -> void:
	# Два фиксированных seed, четыре сезона, три масштаба и
	# три пользовательских профиля: физика при смене графики
	# проверяется по полному WorldSave, а не только по высотам.
	var allocated_nodes: int = atmosphere.get_child_count()
	for seed in [1729, 2819]:
		for day in [1, 25, 49, 73]:
			var models: Dictionary = _season_world(seed, day)
			var world: RefCounted = models["world"]
			var climate: RefCounted = models["climate"]
			var nature: RefCounted = models["nature"]
			var initial: Dictionary = Save.capture(models)
			_check(not initial.is_empty(),
				"Физический WorldSave готов до смены графики")
			var before: String = JSON.stringify(initial)
			for quality in range(3):
				atmosphere.set_quality(quality)
				_check(_emitter_sum(atmosphere) == Budget.particle_limit(quality),
					"Размер GPU-пула точно соответствует качеству")
				_check(atmosphere.debug_budget()["gpu_emitters"] == Budget.MAX_GPU_EMITTERS,
					"В каждом сезоне создано ровно восемь эмиттеров")
				for zoom in [36.0, 76.0, 102.0]:
					# GPU-проба считывает настоящий климат. Травяной
					# покров и деревья создаются из того же NatureRegistry.
					atmosphere.sync_world(climate, world, Vector2(32.0, 24.0), zoom)
					var detail: float = View._detail_for_zoom(zoom)
					var chunk: Node3D = NatureRenderer.create_chunk(
						world, nature, Vector2i(1, 1), detail, models["fire"])
					_check(chunk != null and chunk.get_child_count() <= 40,
						"Природный GPU-чанк ограничен числом групп MultiMesh")
					chunk.free()
				_check(atmosphere.get_child_count() == allocated_nodes,
					"Переключение сезона не создаёт дополнительные семейства FX")
				_check(JSON.stringify(Save.capture(models)) == before,
					"Сезонные пресеты и масштабы не изменили WorldSave")
			_check(not Save.restore(JSON.parse_string(before)).is_empty(),
				"Мир после визуальных проверок корректно восстанавливается")


func _live_view() -> void:
	# Проверяем интеграцию с настоящей сценой: внешний контроль
	# качества применяет именно адаптивный бюджет, а сохранение
	# остаётся полностью физическим при смене дальности.
	var view := View.new()
	root.add_child(view)
	var before: String = JSON.stringify(Save.capture(view._storage_models()))
	view._set_atmosphere_quality(2)
	_check(view._applied_visual_quality == 2
		and _emitter_sum(view._atmosphere) == Budget.particle_limit(2),
		"Интерфейс игры включает подробный GPU-профиль")
	view._camera.size = 95.0
	view._apply_visual_budget()
	view._update_material_detail()
	_check(view._applied_visual_quality == 0
		and _emitter_sum(view._atmosphere) == Budget.particle_limit(0),
		"На дальнем масштабе реальная игровая сцена освобождает GPU-слоты")
	view._camera.size = 42.0
	view._mesh_budget_p95 = 31.0
	view._apply_visual_budget()
	view._apply_visual_budget()
	_check(view._applied_visual_quality == 0
		and view._visual_budget._pressure_cap == 0,
		"При устойчивой нагрузке реальная сцена снижает GPU и тени")
	for sample in range(16):
		view._mesh_budget_p95 = 16.0
		view._apply_visual_budget()
	_check(view._applied_visual_quality == 2
		and view._visual_budget._pressure_cap == 2,
		"После нормализации нагрузки восстанавливается максимум автора")
	view._set_atmosphere_quality(0)
	_check(view._applied_visual_quality == 0,
		"Автоматический профиль не нарушает ручной экономный выбор")
	_check(JSON.stringify(Save.capture(view._storage_models())) == before,
		"Настройки, кадры и тени не изменяют полный WorldSave")
	view.queue_free()


func _run() -> void:
	_policy()
	var atmosphere := Atmosphere.new()
	root.add_child(atmosphere)
	_seasons(atmosphere)
	atmosphere.queue_free()
	_live_view()
	await process_frame
	if not errors.is_empty():
		for reason in errors:
			push_error("11.9/P2: " + reason)
		quit(1)
		return
	print("11.9/P2: GPU-пулы, 2 seed, 4 сезона, 3 масштаба и WorldSave — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
