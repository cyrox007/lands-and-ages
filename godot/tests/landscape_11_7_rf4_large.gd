extends SceneTree
## 11.7/RF4 — физический кратер и WorldSave на карте 512×384.
## Это нагрузка на модель и память CI, но не измерение FPS устройств.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

const Width := 512
const Height := 384
const Seed := 4471

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Сохраняем каждое нарушение, чтобы отчёт отличал ошибки
	# большой гидрологии от сохранения или физического леса.
	if not ok:
		failures.append(reason)


func _models() -> Dictionary:
	# Настоящий большой мир: не используем заранее готовую картинку
	# и не вырезаем маленькую область для искусственного теста.
	var world := Map.new(Config.new(Width, Height, Seed, 16, 64))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат первого дня не установлен")
	_check(surface.advance_climate_day(climate), "Грунт не получил календарь")
	_check(hydro.apply_rainfall_map(surface.runoff_map()),
		"Водосбор не получил реальные осадки")
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Не создан физический природный реестр")
	var weather := Weather.new(world, climate, surface, hydro)
	var processes := Processes.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "weather": weather,
		"natural": processes, "disasters": disasters, "fire": fire,
		"runner": Runner.new(world, hydro, surface, climate,
			weather, processes, disasters, nature, fire)
	}


func _safe_center(world: RefCounted) -> Vector2:
	# Кратер должен быть целиком внутри карты и иметь запас высот,
	# чтобы атомарность отказа не мешала испытывать синхронизацию.
	for y in range(100, Height - 100, 19):
		for x in range(100, Width - 100, 19):
			var center := Vector2(float(x) + 0.5, float(y) + 0.5)
			var valid := true
			for oy in [-10, -5, 0, 5, 10]:
				for ox in [-10, -5, 0, 5, 10]:
					var h: float = world.vertex_at(Vector2i(x + ox, y + oy))
					if h < Map.MIN_HEIGHT + 3.0 \
							or h > Map.MAX_HEIGHT - 3.0:
						valid = false
			if valid:
				return center
	_check(false, "Не найден участок для геологического события")
	return Vector2(256.5, 192.5)


func _path() -> String:
	# Не пишем показатели в репозиторий: CI сохраняет самостоятельный
	# JSON-артефакт, локальная проверка остаётся в user://.
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			return argument.trim_prefix("--out=")
	return "user://landscape-11-7-rf4-large.json"


func _run() -> void:
	# Фиксируем стенд, пик времени пересборки и снимок после
	# деформации. CPU-продолжительность зависит от машины CI.
	var started := Time.get_ticks_usec()
	var state: Dictionary = _models()
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var nature: RefCounted = state["nature"]
	var model_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var center := _safe_center(world)
	var tree_count: int = nature.count()
	var wood_before: int = nature.wood_total()
	var before_revision: int = world.revision
	started = Time.get_ticks_usec()
	var impact: Dictionary = Landscape.new(world).apply(
		"кратер", center, 10.0, 0.55)
	_check(not impact.is_empty() and int(impact.get("vertices", 0)) > 100,
		"Кратер не изменил физические вершины большой карты")
	_check(world.revision == before_revision + 1,
		"Кратер изменил ревизию несколько раз")
	var damage: Dictionary = nature.apply_landscape_impact(
		"кратер", center, 10.0, 0.85, state["climate"].day)
	_check(nature.count() == tree_count and nature.wood_total() == wood_before,
		"На большой карте появились или исчезли природные ресурсы")
	_check(state["runner"].synchronize_world(),
		"После кратера не синхронизированы глобальные водосборы")
	var rebuild_ms := float(Time.get_ticks_usec() - started) / 1000.0
	_check(hydro._terrain_revision == world.revision
		and state["surface"]._terrain_revision == world.revision
		and state["climate"]._terrain_revision == world.revision,
		"Большие климат, почвы и гидрология разошлись по ревизиям")
	_check(world.take_dirty_chunks().is_empty(),
		"Большая карта сохранила грязные чанки после синхронизации")

	# Даже локальный кратер может перенаправить большой водосбор.
	# Чистая перестройка Priority-Flood проверяет, что частичное
	# обновление высот не оставило старые границы рек или бассейнов.
	started = Time.get_ticks_usec()
	var reference := Hydro.new(world)
	_check(reference.load_snapshot(hydro.to_snapshot()),
		"Водосбор нельзя пересоздать из физического мира и осадков")
	_check(reference._downstream == hydro._downstream
		and reference._ground == hydro._ground,
		"Глобальная маршрутизация воды отличается от чистой пересборки")
	var reference_ms := float(Time.get_ticks_usec() - started) / 1000.0

	# Полный WorldSave сохраняет 196608 клеток вместе с конечным
	# лесом, погодой, наносами и геометрическими вершинами кратера.
	started = Time.get_ticks_usec()
	var snapshot: Dictionary = Save.capture(state)
	_check(not snapshot.is_empty(), "Не удалось сохранить большую карту")
	var restored: Dictionary = {}
	if not snapshot.is_empty():
		var data: Variant = JSON.parse_string(JSON.stringify(snapshot))
		if data is Dictionary:
			restored = Save.restore(data)
	_check(not restored.is_empty(), "Большая карта не загружается обратно")
	var restore_ms := float(Time.get_ticks_usec() - started) / 1000.0
	if not restored.is_empty():
		_check(restored["world"].to_data() == world.to_data()
			and restored["nature"].to_data() == nature.to_data()
			and restored["hydro"].to_snapshot() == hydro.to_snapshot()
			and restored["surface"].to_snapshot() == state["surface"].to_snapshot(),
			"Большой WorldSave потерял геологию, ресурсы или водосбор")
		# После загрузки новая реальная физическая модель может
		# продолжить день, не запускается вымышленная старая анимация.
		state["runner"].run_day()
		restored["runner"].run_day()
		_check(state["world"].to_data() == restored["world"].to_data()
			and state["nature"].to_data() == restored["nature"].to_data(),
			"Большая карта расходится после следующего игрового дня")

	var report := {
		"stage": "11.7", "subtask": "RF4", "scenario": "large-map",
		"map_width": Width, "map_height": Height,
		"cells": Width * Height, "seed": Seed,
		"model_cpu_ms": model_ms,
		"geology_sync_cpu_ms": rebuild_ms,
		"hydrology_reference_cpu_ms": reference_ms,
		"save_restore_cpu_ms": restore_ms,
		"tree_count": tree_count, "world_revision": world.revision,
		"impact_vertices": impact.get("vertices", 0),
		"boulders_rebased": damage.get("boulders_rebased", 0),
		"headless_cpu_ci": true,
		"android_pc_fps_verified": false,
		"checks_passed": failures.is_empty()
	}
	var path := _path()
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	_check(file != null, "Не создан отчёт большого мира")
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if not failures.is_empty():
		for failure in failures:
			push_error("11.7/RF4/LARGE: " + failure)
		quit(1)
		return
	print("11.7/RF4/LARGE: 512×384, кратер, Priority-Flood и WorldSave — успешно")
	quit(0)


func _initialize() -> void:
	# Физическая карта работает без окна и видеокарты; это
	# отдельная проверка от визуального CI и маршрута устройства.
	call_deferred("_run")
