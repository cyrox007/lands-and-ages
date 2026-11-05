extends SceneTree
## R3 — физическая выразительность гор и оврагов без потери старых сохранений.
## Проверяем профиль геометрии, единые источники высоты и восстановление.

const Config = preload("res://scripts/world_config.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Features = preload("res://scripts/relief_visual_features.gd")

var failures: Array[String] = []


func _check(valid: bool, message: String) -> void:
	## Вместо аварийного выхода сохраняем все проваленные инварианты.
	if not valid:
		failures.append(message)


func _section(kind: int, world_seed: int, version: int) -> Vector2:
	## Ищем одну реальную географическую форму указанного вида,
	## ориентируем сечение поперёк её оси и сравниваем физические высоты.
	for gy in range(4):
		for gx in range(4):
			if Terrain._form_index(gx, gy, world_seed) != kind:
				continue
			var angle: float = Terrain.hash2(gx, gy, world_seed + 13) * TAU
			var midpoint := Vector2(
				(float(gx) + 0.5 + (Terrain.hash2(gx, gy, world_seed + 11) - 0.5) * 0.32)
					* Terrain.FEATURE_STEP,
				(float(gy) + 0.5 + (Terrain.hash2(gx, gy, world_seed + 12) - 0.5) * 0.32)
					* Terrain.FEATURE_STEP)
			var transverse := Vector2(-sin(angle), cos(angle))
			var meander := 0.11 if kind == 4 else 0.16
			var core := midpoint - transverse * (30.0 * meander * sin(angle))
			var edge := core + transverse * (12.0 if kind == 4 else 9.0)
			var peak: float = Terrain._feature(
				core.x, core.y, gx, gy, world_seed, version).x
			var shoulder: float = Terrain._feature(
				edge.x, edge.y, gx, gy, world_seed, version).x
			return Vector2(peak, shoulder)
	return Vector2.ZERO


func _test_shape() -> void:
	## Версия 2 создаёт более выразительную **физическую** форму:
	## увеличение контраста между гребнем и склоном, дном и бровкой.
	var mountain_old: Vector2 = _section(4, 1729, Terrain.RELIEF_LEGACY)
	var mountain_new: Vector2 = _section(4, 1729, Terrain.RELIEF_SHARP)
	var ridge_gain: float = (mountain_new.x - mountain_new.y) 		- (mountain_old.x - mountain_old.y)
	_check(ridge_gain > 2.0, "Горный гребень физически острее пологого профиля")

	var ravine_old: Vector2 = _section(6, 1729, Terrain.RELIEF_LEGACY)
	var ravine_new: Vector2 = _section(6, 1729, Terrain.RELIEF_SHARP)
	var trench_gain: float = (ravine_new.y - ravine_new.x) 		- (ravine_old.y - ravine_old.x)
	_check(trench_gain > 0.35, "Овраг имеет более заметную физическую бровку")
	_check(mountain_new.x > 0.0 and ravine_new.x < 0.0,
		"Горы не превращаются в впадины, овраги не поднимаются над землёй")
	print("R3 сечение: горный контраст +", snappedf(ridge_gain, 0.001),
		"; овражный контраст +", snappedf(trench_gain, 0.001))


func _test_versions() -> void:
	## Старый JSON не содержит relief_version; его необходимо
	## прочесть по первоначальным формулам без дрейфа базовых высот.
	var old_config = Config.new(256, 192, 1729, 16, 32, 0.9, Config.RELIEF_LEGACY)
	var new_config = Config.new(256, 192, 1729, 16, 32, 0.9, Config.RELIEF_SHARP)
	_check(not old_config.to_data().has("relief_version"),
		"Старый формат JSON и подписи природных моделей не меняются")
	_check(int(new_config.to_data().get("relief_version", 0)) == 2,
		"Новый физический профиль явно закреплён в сохранении")

	var recovered_config = Config.from_data(old_config.to_data())
	_check(recovered_config != null and recovered_config.relief_version == 1,
		"Старое сохранение восстанавливает исходный профиль")
	var corrupt: Dictionary = new_config.to_data()
	corrupt["relief_version"] = 9
	_check(Config.from_data(corrupt) == null, "Неизвестная версия высот отвергается")

	var old_world = Map.new(old_config)
	var new_world = Map.new(new_config)
	var different := 0
	for point in [
		Vector2i(176, 35), Vector2i(182, 44),
		Vector2i(182, 108), Vector2i(190, 116),
		Vector2i(68, 75), Vector2i(136, 140)
	]:
		var old_height: float = old_world.vertex_at(point)
		_check(is_equal_approx(old_height,
			Terrain.vertex_height_on_map(point.x, point.y, 256, 192, 1729, 1)),
			"Старый мир использует исходный генератор высот")
		if absf(old_height - new_world.vertex_at(point)) > 0.01:
			different += 1
	_check(different > 0, "Новый физический рельеф отличается от старого")

	# Даже после физической деформации старый мир остаётся идентичен
	# при загрузке, включая уже накопленные изменения поверхности.
	var edit := Vector2i(113, 91)
	_check(old_world.set_vertex(edit, old_world.vertex_at(edit) + 0.5),
		"Изменение старого мира сохраняется поверх прежнего генератора")
	var saved_legacy: Variant = JSON.parse_string(JSON.stringify(old_world.to_data()))
	var restored_legacy = Map.from_data(saved_legacy)
	_check(restored_legacy != null and restored_legacy.to_data() == old_world.to_data(),
		"Исторический мир и его деформации восстанавливаются без дрейфа")
	var saved_new: Variant = JSON.parse_string(JSON.stringify(new_world.to_data()))
	var restored_new = Map.from_data(saved_new)
	_check(restored_new != null and restored_new.to_data() == new_world.to_data(),
		"Новый мир после загрузки сохраняет тот же профиль и seed")


func _test_physics_and_render() -> void:
	## Гидрология, грунты и меш должны видеть одну новую физическую карту,
	## а графическая маска обязана реагировать на настоящую деформацию.
	var world = Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro = Hydrology.new(world)
	hydro.rebuild()
	var surface = Surface.new(world, hydro)
	surface.rebuild()
	var before_world: Dictionary = world.to_data()
	var before_hydro: Dictionary = hydro.to_snapshot()
	var before_surface: Dictionary = surface.to_snapshot()
	var mesh_data: Array = Chunk.prepare_arrays(1, 1, 1,
		world, surface, 0, null, hydro)
	_check(mesh_data[Mesh.ARRAY_VERTEX].size() > 0,
		"Физическая карта становится допустимым GPU-ландшафтом")
	_check(world.to_data() == before_world
		and hydro.to_snapshot() == before_hydro
		and surface.to_snapshot() == before_surface,
		"Создание PBR-меша не изменяет физику")

	var vertex := Vector2i(24, 24)
	var original: float = world.vertex_at(vertex)
	var mask_before: Vector2 = Features.sample_at(world, vertex)
	_check(world.set_vertex(vertex, original + 2.0), "Изменение высоты атомарно")
	var mask_after: Vector2 = Features.sample_at(world, vertex)
	_check(mask_before != mask_after, "Маски формы пересчитываются от новой высоты")
	_check(world.vertex_at(vertex) == original + 2.0,
		"Деформация сохраняется в одном WorldMap")
	# После пересчёта водосбора гидрология читает ту же высоту:
	# локальные маски рендера не подменяют уровень настоящей воды.
	hydro.rebuild()
	surface.rebuild()
	var water: Dictionary = hydro.water_at(Vector2i(24, 24))
	_check(not water.is_empty() and is_finite(float(water["ground"])),
		"Гидрология пересчитала высоту грунта на деформированном участке")


func _initialize() -> void:
	## Запуск автоматических проверок без игровой сцены и внешних ассетов.
	_test_shape()
	_test_versions()
	_test_physics_and_render()
	if failures.is_empty():
		print("R3: геометрия, версии сохранений и физическая согласованность — успешно")
		quit(0)
		return
	for message in failures:
		printerr("R3: ", message)
	quit(1)
