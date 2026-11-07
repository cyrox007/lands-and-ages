extends SceneTree
## R3/R5 — геометрия гор и оврагов в единственной актуальной модели.
## Старые сохранения не мигрируем; новая физика и PBR едины.

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


func _section(kind: int, world_seed: int) -> Vector2:
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
				core.x, core.y, gx, gy, world_seed).x
			var shoulder: float = Terrain._feature(
				edge.x, edge.y, gx, gy, world_seed).x
			return Vector2(peak, shoulder)
	return Vector2.ZERO


func _test_shape() -> void:
	# Физический гребень должен сильно превышать предгорья.
	# Овраг остаётся долиной с настоящими кромками и стоком.
	var mountain: Vector2 = _section(4, 1729)
	var ravine: Vector2 = _section(6, 1729)
	_check(mountain.x - mountain.y >= 12.0,
		"Высокий хребет существенно выше физического предгорья")
	_check(ravine.y - ravine.x >= 0.65,
		"Овраг имеет заметные физические бровки")
	_check(mountain.x > 18.0 and ravine.x < 0.0,
		"Горы имеют вершины, овраги сохраняют отрицательный разрез")


func _test_versions() -> void:
	# Версионируем только действующую геометрию. Старый JSON
	# отклоняем с ошибкой, не симулируем полугодовые миграции.
	var config := Config.new(256, 192, 1729, 16, 32)
	_check(int(config.to_data().get("terrain_version", -1)) ==
		Config.TERRAIN_VERSION, "Сохранение указывает только R5")
	var rejected: Dictionary = config.to_data()
	rejected.erase("terrain_version")
	_check(Config.from_data(rejected) == null,
		"Устаревшее сохранение без нового рельефа отвергнуто")
	rejected["terrain_version"] = 2
	_check(Config.from_data(rejected) == null,
		"Устаревший номер геометрии отвергнут")
	_check(Config.from_data(config.to_data()) != null,
		"Актуальный физический конфиг восстанавливается")

	var world := Map.new(config)
	var edited := Vector2i(113, 91)
	_check(world.set_vertex(edited, world.vertex_at(edited) + 0.5),
		"Деформация хранится поверх единственного генератора")
	var saved: Variant = JSON.parse_string(JSON.stringify(
		world.to_data(), "", true, true))
	var restored = Map.from_data(saved)
	_check(restored != null and restored.to_data() == world.to_data(),
		"Текущий WorldMap и деформации восстановлены без дрейфа")

func _test_physics_and_render() -> void:
	## Гидрология, грунты и меш должны видеть одну новую физическую карту,
	## а графическая маска обязана реагировать на настоящую деформацию.
	var world = Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro = Hydrology.new(world)
	hydro.rebuild()
	var surface = Surface.new(world, hydro)
	surface.rebuild()
	# Инициализируем локальный сток до снимка Hydrology:
	# пустой PackedFloat32Array нельзя кодировать как base64.
	hydro.apply_rainfall_map(surface.runoff_map())
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
	_check(is_equal_approx(world.vertex_at(vertex), original + 2.0),
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
