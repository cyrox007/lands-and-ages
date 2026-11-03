extends SceneTree
## Проверка естественных границ без запрета водного транспорта.
## Море, озёра и суша не подменяют технические границы мира.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Boundary = preload("res://scripts/world_boundary.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Terrain = preload("res://scripts/terrain.gd")
const WaterMesh = preload("res://scripts/water_mesh.gd")

var failures: Array[String] = []


func _check(condition: bool, note: String) -> void:
	if not condition:
		failures.append(note)


func _initialize() -> void:
	_run()


func _run() -> void:
	var cfg := Config.new()
	var world := WorldMap.new(cfg)
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var sea := 0
	var land := 0
	var wet_location := Vector2i(-1, -1)
	var ocean_chunk := Vector2i(-1, -1)
	for y in range(cfg.height):
		for x in range(cfg.width):
			var cell := Vector2i(x, y)
			var water: Dictionary = hydro.water_at(cell)
			if bool(water["ocean"]):
				sea += 1
				wet_location = cell
				ocean_chunk = cfg.chunk_of(cell)
				_check(not bool(water["lake"]) and not bool(water["river"]),
					"Морская клетка не маскируется озером или рекой")
				_check(is_equal_approx(float(water["water_level"]), Boundary.SEA_LEVEL),
					"Морская поверхность имеет единый уровень")
			else:
				land += 1
	_check(sea > 200, "На стандартной карте есть открытое море")
	_check(land > 8000, "Суша занимает значительную часть карты")
	_check(Boundary.traversal_gate(cfg, Vector2(25, 25), false, false) == "внутри мира",
		"Суша внутри карты доступна")
	_check(Boundary.traversal_gate(cfg, Vector2(25, 25), true, false)
		== "требуется способ пересечения воды", "Вода требует подходящего перемещения")
	_check(Boundary.traversal_gate(cfg, Vector2(25, 25), true, true) == "внутри мира",
		"Плавание через воду внутри карты разрешено")
	_check(Boundary.traversal_gate(cfg, Vector2(-0.1, 25), true, true)
		== "за пределами мира", "Плавание за левый край запрещено")
	_check(Boundary.traversal_gate(cfg, Vector2(cfg.width, 25), true, true)
		== "за пределами мира", "Корабль не может выйти через правую границу")
	_check(Boundary.traversal_gate(cfg, Vector2(25, cfg.height), false, false)
		== "за пределами мира", "Пешком нельзя выйти за верхнюю границу")

	var styles := {}
	for side in range(4):
		var point := Vector2(cfg.width / 2.0, cfg.height / 2.0)
		match side:
			0:
				point.x = 0.0
			1:
				point.x = cfg.width - 0.01
			2:
				point.y = 0.0
			3:
				point.y = cfg.height - 0.01
		var geo := Boundary.geography_at(point.x, point.y,
			cfg.width, cfg.height, cfg.seed)
		styles[str(geo["zone"])] = true
		_check(float(geo["influence"]) >= 0.75, "Периферия географически выражена")
	_check(styles.has(Boundary.COAST), "Побережье присутствует")
	_check(styles.has(Boundary.RIDGE) or styles.has(Boundary.HIGHLANDS),
		"Горы или скалы образуют альтернативный рубеж")

	# Центральный рельеф не зависит от краёв, при расширении меняется лишь обрамление.
	var expanded := WorldMap.new(Config.new(320, 240, cfg.seed))
	for point in [Vector2i(80, 70), Vector2i(130, 95), Vector2i(150, 125)]:
		_check(is_equal_approx(world.vertex_at(point), expanded.vertex_at(point)),
			"Внутренние формы не меняются при расширении мира")
	_check(is_finite(world.vertex_at(Vector2i(0, 0))),
		"Высоты внешних вершин определены")
	_check(not is_equal_approx(world.vertex_at(Vector2i(1, 1)),
		Terrain.height_at(1.0, 1.0, cfg.seed)),
		"Природное обрамление действительно участвует в высотах")

	if wet_location.x >= 0:
		var water_mesh := WaterMesh.create_mesh(world, hydro, ocean_chunk)
		_check(water_mesh.get_surface_count() > 0,
			"Море отображается отдельным GPU-мешем")
		var saved := JSON.parse_string(JSON.stringify(world.to_data()))
		var loaded = WorldMap.from_data(saved)
		_check(loaded != null, "Карта с естественной границей восстанавливается")
		if loaded != null:
			var other := Hydrology.new(loaded)
			other.rebuild()
			_check(other.water_at(wet_location) == hydro.water_at(wet_location),
				"Морская граница воспроизводится при загрузке")

	# Старые экспериментальные генераторы намеренно не поддерживаются.
	var old: Dictionary = world.to_data()
	old["version"] = 1
	_check(WorldMap.from_data(old) == null, "Снимки прототипов отвергаются явно")
	var obsolete: Dictionary = cfg.to_data()
	obsolete["generator_version"] = 2
	_check(Config.from_data(obsolete) == null,
		"Ненужный выбор генератора удалён из формата")

	# Связь воды с границей должна быть воспроизводимой и у других seed.
	for seed in [43, 127, 833, 2001]:
		var item := WorldMap.new(Config.new(64, 48, seed))
		var first := Hydrology.new(item)
		first.rebuild()
		var second := Hydrology.new(WorldMap.new(Config.new(64, 48, seed)))
		second.rebuild()
		_check(first.water_count() == second.water_count(), "Вода воспроизводится при seed")

	if not failures.is_empty():
		for note in failures:
			push_error("Граница: " + note)
		quit(1)
		return
	print("Этап 3.1: естественный край, доступная вода, сохранения и GPU — успешно.")
	quit(0)
