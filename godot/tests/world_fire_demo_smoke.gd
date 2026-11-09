extends SceneTree
## Этап 11: сквозной пожар — реальное дерево, повреждение,
## отдельный файл WorldSave, восстановление без повторного поджога
## и корректный профиль времени одного физического дня.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")
const Demo = preload("res://scripts/world_fire_demo.gd")
const View = preload("res://scripts/world.gd")

const TEST_PATH := "user://fire-demo-integration-smoke.json"
var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Сохраняем все нарушения, а не скрываем следующими тестами
	# ошибку физического огня, файла или учёта времени.
	if not ok:
		failures.append(reason)


func _models() -> Dictionary:
	# Реальный лес и физическая поверхность одного seed — та же
	# модель, что в игре. Только в тесте задаём сухую погоду,
	# чтобы проверить полный маршрут, не зависящий от случайного дождя.
	var world := Map.new(Config.new(96, 80, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(1)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Создан настоящий лес")
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "fire": fire,
		"weather": Weather.new(world, climate, surface, hydro),
		"natural": Processes.new(world, hydro, surface, climate),
		"disasters": Disasters.new(world, hydro, surface, climate)}


func _visible_chunks(world: RefCounted) -> Array:
	# Для детерминированного теста разрешаем все чанки карты;
	# в настоящем интерфейсе выбор ограничен видимыми чанками.
	var chunks := []
	for y in range(world.config.chunk_count().y):
		for x in range(world.config.chunk_count().x):
			chunks.append(Vector2i(x, y))
	return chunks


func _test_event_roundtrip() -> void:
	var state: Dictionary = _models()
	var climate: RefCounted = state["climate"]
	var surface: RefCounted = state["surface"]
	var nature: RefCounted = state["nature"]
	var fire: RefCounted = state["fire"]
	# Исключаем случайный дождь и снег, сохраняя настоящий
	# физический порог воспламенения FireRegistry.
	surface._moisture.fill(0.02)
	surface._snow.fill(0.0)
	climate._rain.fill(0.0)
	var before: Dictionary = Save.capture(state)
	_check(not before.is_empty(), "Исходный мир имеет валидный WorldSave")
	var target: Dictionary = Demo.choose_tree(
		nature, fire, _visible_chunks(state["world"]), Vector2(48.0, 40.0))
	if target.is_empty():
		_check(false, "Найден настоящий горючий объект для сценария")
		return
	var cell: Vector2i = target["cell"]
	var id: int = target["id"]
	_check(not Demo.ignition_confirmed([], cell),
		"Одна команда теста ещё не означает реальное возгорание")

	# Суточный огонь запускается в обычном физическом реестре.
	# Оставляем полный порядок климата, почвы и роста природы,
	# как в существующих проверках F1/F6.
	climate.set_day(2)
	surface.advance_climate_day(climate)
	surface._moisture.fill(0.02)
	surface._snow.fill(0.0)
	climate._rain.fill(0.0)
	nature.advance_day(2)
	var events: Array[Dictionary] = fire.advance_day(2, [], cell)
	_check(Demo.ignition_confirmed(events, cell)
		and fire.is_burning(id), "Возгорание произошло в настоящем реестре")
	var after: Dictionary = Save.capture(state)
	_check(not after.is_empty() and after["fire"] != before["fire"],
		"После огня сохранение содержит изменённую физику")
	_check(not Demo.physical_equal(before, after),
		"До и после — разные физические состояния")

	# Сохраняем на диск и читаем новые экземпляры всех моделей,
	# не используя ссылку на старую карту или память сцены.
	_check(Save.write_file(state, TEST_PATH),
		"Файл испытания записан атомарно через WorldSave")
	var restored: Dictionary = Save.read_file(TEST_PATH)
	_check(not restored.is_empty(), "Мир действительно прочитан из файла")
	if restored.is_empty():
		return
	var copied: Dictionary = Save.capture(restored)
	_check(Demo.physical_equal(after, copied),
		"Весь физический снимок восстановлен точно")
	_check(restored["fire"].is_burning(id)
		and restored["fire"].total_ignitions == fire.total_ignitions,
		"Очаг и счётчик возгораний восстановлены без повторного поджога")
	var loaded_again: Dictionary = Save.read_file(TEST_PATH)
	_check(not loaded_again.is_empty()
		and loaded_again["fire"].total_ignitions == fire.total_ignitions,
		"Повторная загрузка не порождает новый пожар")
	print("FIRE-DEMO: день=", climate.day, ", клетка=", cell,
		", возгораний=", fire.total_ignitions,
		", снимки совпадают=", Demo.physical_equal(after, copied))


func _test_physics_profile() -> void:
	# Независимый полный суточный расчёт измеряет реальные этапы.
	# Ни растительность, ни огонь не должны попадать в профиль дважды.
	var state: Dictionary = _models()
	var runner := Runner.new(state["world"], state["hydro"],
		state["surface"], state["climate"], state["weather"],
		state["natural"], state["disasters"], state["nature"], state["fire"])
	runner.run_day()
	var elapsed := 0
	for kind in runner.last_profile_us:
		elapsed += int(runner.last_profile_us[kind])
	var hotspot: Dictionary = Demo.slowest_phase(runner.last_profile_us)
	_check(runner.last_duration_us > 0 and elapsed > 0
		and elapsed <= runner.last_duration_us + 500,
		"Сумма измеренных этапов не содержит двойного учёта")
	_check(runner.last_profile_us.has("согласование")
		and runner.last_profile_us.has("геологические следы")
		and str(hotspot["name"]) != ""
		and int(hotspot["us"]) > 0,
		"Физика показывает настоящий наиболее затратный этап")
	_check(runner.test_fire_cell == Vector2i(-1, -1),
		"Случайный день не наследует пробный пожар")
	print("DAY-PROFILE: всего=", runner.last_duration_us,
		" мкс, стадии=", elapsed, " мкс, максимум=", hotspot)


func _test_scene_ui() -> void:
	# В игре сценарий должен быть виден без технической панели,
	# но не запускаться сам при обычном создании мира.
	var view := View.new()
	view.stream_camera = false
	get_root().add_child(view)
	var button := view.find_child("Сквозной пожар", true, false) as Button
	_check(button != null and button.visible,
		"В основном интерфейсе доступен сценарий пожара")
	_check(view._fire_demo.is_empty()
		and not view._fire_demo_active(),
		"Простой запуск игры не поджигает лес и не меняет день")
	view.queue_free()


func _run() -> void:
	_test_event_roundtrip()
	_test_physics_profile()
	_test_scene_ui()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	if not failures.is_empty():
		for reason in failures:
			push_error("FIRE-DEMO: " + reason)
		quit(1)
		return
	print("FIRE-DEMO: пожар, WorldSave, интерфейс и профиль суток — успешно")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
