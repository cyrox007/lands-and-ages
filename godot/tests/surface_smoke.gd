extends SceneTree
## Этап 4: независимость грунта от погоды, гидрологии и рендера.
const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")

var failures: Array[String] = []


func _check(ok: bool, description: String) -> void:
	if not ok:
		failures.append(description)


func _initialize() -> void:
	_run()


func _run() -> void:
	var world := WorldMap.new(Config.new(64, 48, 1729))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	# Повторная генерация проверяется на независимой карте с тем же seed.
	var other_world := WorldMap.new(Config.new(64, 48, 1729))
	var other_hydro := Hydrology.new(other_world)
	other_hydro.rebuild()
	var duplicate := Surface.new(other_world, other_hydro)
	duplicate.rebuild()
	var examples := {}
	var dry := Vector2i(-1, -1)
	for y in range(world.config.height):
		for x in range(world.config.width):
			var cell := Vector2i(x, y)
			var a: Dictionary = surface.profile_at(cell)
			var b: Dictionary = duplicate.profile_at(cell)
			_check(a == b, "Повторная генерация по seed совпадает")
			examples[a["substrate"]] = true
			_check(float(a["fertility"]) >= 0.0 and float(a["fertility"]) <= 1.0,
				"Плодородие ограничено")
			_check(float(a["depth"]) >= 0.0 and float(a["moisture"]) <= 1.0,
				"Толщина и влажность ограничены")
			if dry.x < 0 and not hydro.has_water(hydro.cell_index(cell)) \
					and a["substrate"] == "суглинок":
				dry = cell
	_check(examples.size() >= 3, "На карте есть несколько самостоятельных пород")
	_check(dry.x >= 0, "Найдена сухопутная почва для испытаний")
	_check(surface.profile_at(Vector2i(-1, 0)).is_empty(), "За пределами нет поверхности")
	if dry.x < 0:
		_finish()
		return

	var before: Dictionary = surface.profile_at(dry)
	var prior_height: float = world.height_at(Vector2(float(dry.x) + 0.5,
		float(dry.y) + 0.5))
	_check(surface.advance_day(2.2, 16.0), "Ливень принимается")
	var after_rain: Dictionary = surface.profile_at(dry)
	_check(after_rain["substrate"] == before["substrate"] \
		and after_rain["depth"] == before["depth"] \
		and after_rain["fertility"] == before["fertility"],
		"Дождь не меняет геологическую основу")
	_check(float(after_rain["moisture"]) > float(before["moisture"]),
		"Почва впитывает осадки")
	_check(not surface.advance_day(-1.0, 12.0), "Отрицательные осадки запрещены")
	_check(not surface.advance_day(0.0, INF), "Некорректная температура запрещена")
	for i in range(4):
		surface.advance_day(0.0, 25.0)
	_check(float(surface.profile_at(dry)["moisture"]) < float(after_rain["moisture"]),
		"Тёплая сухая погода уменьшает влажность")

	for i in range(3):
		surface.advance_day(1.1, -12.0)
	var winter: Dictionary = surface.profile_at(dry)
	_check(float(winter["snow"]) > 0.3 and float(winter["frost"]) > 0.5,
		"Накопление снега и промерзание")
	_check(winter["cover"] == "снег", "Снежный покров не меняет тип породы")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(surface.to_data()))
	var loaded := Surface.new(other_world, other_hydro)
	loaded.rebuild()
	_check(loaded.load_data(saved), "Физическое состояние восстанавливается")
	var restored: Dictionary = loaded.profile_at(dry)
	_check(absf(float(restored["moisture"]) - float(winter["moisture"])) <= 0.005,
		"Влажность сохраняется с точностью 8-битного слоя")
	_check(restored["substrate"] == winter["substrate"]
		and absf(float(restored["snow"]) - float(winter["snow"])) <= 0.005,
		"Снег и базовый грунт сохраняются")
	_check(not loaded.load_data({"version": 999}), "Чужой формат отвергается")
	var broken: Dictionary = saved.duplicate(true)
	broken["frost"] = "AA=="
	_check(not loaded.load_data(broken), "Неполный слой отклоняется")

	for i in range(5):
		surface.advance_day(0.0, 14.0)
	var thawed: Dictionary = surface.profile_at(dry)
	_check(float(thawed["snow"]) < float(winter["snow"])
		and float(thawed["frost"]) < float(winter["frost"]),
		"Оттепель тает снег и размораживает грунт")
	_check(is_equal_approx(prior_height, world.height_at(
		Vector2(float(dry.x) + 0.5, float(dry.y) + 0.5))),
		"Поверхностная погода не меняет геометрию рельефа")

	var first := Chunk.create_mesh(0, 0, 1, world, surface, 1)
	var second := Chunk.create_mesh(0, 0, 1, world, surface, 2)
	_check(first.get_surface_count() == 1 and second.get_surface_count() == 1,
		"GPU поддерживает режим грунтов и диагностическую влажность")
	_check(first.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		!= second.surface_get_arrays(0)[Mesh.ARRAY_COLOR],
		"Режимы используют разные физические окраски")
	var previous_revision: int = surface.revision
	_check(world.set_vertex(Vector2i(20, 20), 3.0), "Изменение физического рельефа")
	surface.ensure_ready()
	_check(surface.revision > previous_revision,
		"После правки рельефа свойства поверхности пересчитаны")
	_finish()


func _finish() -> void:
	if not failures.is_empty():
		for failure in failures:
			push_error("Поверхность: " + failure)
		quit(1)
		return
	print("Этап 4: грунты, вода, замерзание, сохранения и GPU — успешно.")
	quit(0)
