extends SceneTree
## 11.9/P1 — ограничение числа природных коллизий и обновлений чанков.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Colliders = preload("res://scripts/nature_collision.gd")
const View = preload("res://scripts/world.gd")

var errors: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Сообщаем отдельно об избыточном обходе, ошибке радиуса и
	# потерянной коллизии, чтобы CI не скрывал физический дефект.
	if not ok:
		errors.append(reason)


func _models() -> Dictionary:
	# Маленький мир даёт 16 настоящих природных чанков, а тест
	# рассматривает девять вокруг камеры, без зависимости от GPU.
	var world := Map.new(Config.new(64, 64, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат создан")
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Физический реестр природы создан")
	nature._objects.clear()
	nature._chunks.clear()
	# Настоящее дерево в центральном чанке проверяет формы ствола,
	# которые создаёт существующий NatureCollision, а не макет.
	var cell := Vector2i(40, 40)
	var id: int = cell.y * world.config.width + cell.x + 1
	var tree := {
		"id": id, "kind": "дерево", "species": "сосна",
		"x": cell.x, "y": cell.y, "age_days": 20 * 96,
		"health": 1000, "wood_units": 40, "fallen_wood": 0,
		"state": "целое", "cut_progress": 0,
		"dead_since_day": -1, "fallen_since_day": -1,
		"fall_angle_deg": -1, "radius": 0.21
	}
	nature._objects[id] = tree
	nature._index(tree)
	return {"world": world, "surface": surface, "nature": nature,
		"tree_id": id}


func _collider_count(view: Node3D) -> int:
	# Считаем настоящие тела в узлах игровых чанков, не предполагая,
	# что пустой чанк имеет коллизионные формы.
	var count := 0
	for node in view._active.values():
		if node.get_node_or_null(Colliders.COLLISION_NAME) != null:
			count += 1
	return count


func _run() -> void:
	var models: Dictionary = _models()
	var world: RefCounted = models["world"]
	var nature: RefCounted = models["nature"]
	var surface: RefCounted = models["surface"]
	var before_map: Dictionary = world.to_data()
	var before_nature: Dictionary = nature.to_data()
	var before_surface: Dictionary = surface.to_snapshot()
	# Создаём игру без _ready: только физические модели и реальные
	# Node3D чанков. Тест не зависит от OpenGL или наличия GPU.
	var view := View.new()
	view._world_model = world
	view._nature = nature
	view._chunk_center = Vector2i(2, 2)
	view._view_mode = 0
	for cy in range(1, 4):
		for cx in range(1, 4):
			var coord := Vector2i(cx, cy)
			var node := Node3D.new()
			node.name = "Чанк_%d_%d" % [cx, cy]
			view.add_child(node)
			view._active[coord] = node

	# Холодный старт создаёт не более двух физических чанков за
	# один кадр. После пяти вызовов готовы все девять.
	for step in range(5):
		var previous: int = view._collider_chunks_created
		view._sync_nature_colliders()
		_check(view._collider_chunks_created - previous <=
			Colliders.MAX_NEW_CHUNKS_PER_FRAME,
			"Лимит создания коллизий за один кадр соблюдён")
	_check(_collider_count(view) == 9
		and view._collider_chunks_created == 9,
		"Вокруг камеры присутствуют девять физических чанков")
	var middle: Node3D = view._active[Vector2i(2, 2)]
	var trunk: Node = middle.get_node_or_null(Colliders.COLLISION_NAME)
	_check(trunk != null and trunk.get_child_count() == 1,
		"Центральный ствол имеет настоящую физическую форму")
	var initial_sweeps: int = view._collider_sweeps

	# При неподвижной камере 180 графических кадров не должны
	# запускать 180 повторных обходов природной физики.
	for frame in range(180):
		view._sync_nature_colliders()
	_check(view._collider_sweeps == initial_sweeps
		and view._collider_idle_skips >= 180,
		"Неподвижная камера не запускает лишние CPU-обходы")

	# При переходе к краю девять прежних чанков превращаются в
	# один близкий. Остальные формы должны исчезнуть в тот же тик.
	view._chunk_center = Vector2i(0, 0)
	view._sync_nature_colliders()
	_check(_collider_count(view) == 1
		and view._active[Vector2i(1, 1)].get_node_or_null(
			Colliders.COLLISION_NAME) != null,
		"Далёкие коллизии отключаются при движении камеры")
	var sweeps_after_pan: int = view._collider_sweeps
	view._sync_nature_colliders()
	_check(view._collider_sweeps == sweeps_after_pan,
		"После завершения панорамы повторный обход не нужен")

	# Возвращение к прежнему месту создаёт тела постепенно,
	# не увеличивая физическое число деревьев в NatureRegistry.
	view._chunk_center = Vector2i(2, 2)
	for frame in range(5):
		view._sync_nature_colliders()
	_check(_collider_count(view) == 9,
		"При обратном перемещении коллизии восстановлены")
	_check(nature.to_data() == before_nature,
		"Переключение LOD не изменило физические объекты")

	# Диагностический вид не содержит препятствий, а возврат в
	# природный режим ставит их обратно по текущему плану.
	view._view_mode = 1
	view._sync_nature_colliders()
	_check(_collider_count(view) == 0,
		"Диагностика освобождает близкие природные коллизии")
	view._view_mode = 0
	for frame in range(5):
		view._sync_nature_colliders()
	_check(_collider_count(view) == 9,
		"Возврат в природный вид восстанавливает столкновения")

	# Невидимые изменения немедленно инвалидируют старый GPU-кеш.
	# Они не должны занимать лимит двух дорогих обновлений в кадре.
	var distant := Vector2i(0, 0)
	var hidden := Node3D.new()
	view._render_cache.put(distant, hidden)
	_check(view._render_cache.has(distant),
		"Кеш невидимого чанка создан")
	var central := Vector2i(2, 2)
	var modified: Array[Vector2i] = [distant, central]
	view._on_nature_changed(modified, nature.revision + 1)
	_check(not view._render_cache.has(distant)
		and view._nature_dirty.has(central)
		and not view._nature_dirty.has(distant),
		"Невидимый кеш сброшен немедленно, видимый чанк поставлен в очередь")
	# Если открыт другой вид, даже отложенные обновления природы
	# освобождаются без дорогостоящей пересборки GPU-моделей.
	view._view_mode = 1
	view._flush_nature_visuals()
	_check(view._nature_dirty.is_empty(),
		"В невизуальном режиме очередь природы не занимает кадры")

	_check(world.to_data() == before_map
		and surface.to_snapshot() == before_surface
		and nature.to_data() == before_nature,
		"LOD, кеш и коллизии не влияют на физику и WorldSave")
	view.free()
	if not errors.is_empty():
		for reason in errors:
			push_error("11.9/P1: " + reason)
		quit(1)
		return
	print("11.9/P1: лимит коллизий, панорама, покой, LOD и кеш — успешно.")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
