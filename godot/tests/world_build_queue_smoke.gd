extends SceneTree
## Этап 8.6: приоритетная очередь GPU без потери обязательных пересборок.

const View = preload("res://scripts/world.gd")
const Queue = preload("res://scripts/chunk_build_queue.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _test_priority() -> void:
	var pending: Array[Vector2i] = [
		Vector2i(4, 5), Vector2i(5, 5),
		Vector2i(6, 5), Vector2i(5, 6)]
	var active := {Vector2i(5, 5): true}
	Queue.prioritize(pending, Vector2(88.0, 88.0),
		Vector2.RIGHT, 16, active)
	_check(pending[0] == Vector2i(6, 5),
		"Пустой чанк по направлению движения получает первый приоритет")
	_check(pending[pending.size() - 1] == Vector2i(5, 5),
		"Отрисовка отсутствующих участков важнее обновления старого меша")
	var repeat: Array[Vector2i] = pending.duplicate()
	Queue.prioritize(repeat, Vector2(88.0, 88.0),
		Vector2.RIGHT, 16, active)
	_check(repeat == pending, "Очередь имеет детерминированный порядок")
	_check(Queue.budget_us(12.0, false) == 4200,
		"При устойчивых кадрах остаётся обычный бюджет")
	_check(Queue.budget_us(23.0, false) == 2500,
		"При тяжёлых кадрах бюджет снижается")
	_check(Queue.budget_us(29.0, false) == 1400,
		"При перегрузке защищаем время кадра")
	_check(Queue.budget_us(12.0, true) == 1400,
		"Во время перемещения камера важнее создания очередного меша")
	_check(Queue.budget_us(10.0, true, 1000) == 1000,
		"Предел заданного бюджета никогда не превышается")


func _test_real_scene() -> void:
	var scene := View.new()
	get_root().add_child(scene)
	if scene._world_model == null or scene._camera == null:
		_check(false, "Тестовая сцена полностью инициализирована")
		scene.queue_free()
		return

	var baseline: Dictionary = scene._world_model.to_data()
	scene._change_zoom(0.1)
	_check(not scene._pending.is_empty(), "Ближняя камера создала очередь")
	if scene._pending.is_empty():
		scene.queue_free()
		return

	var focus: Vector2i = scene._pending[0]
	scene._pending.pop_front()
	scene._create_chunk(focus)
	var old_node: Node3D = scene._active[focus]
	_check(scene._chunk_rebuilds == 1,
		"Первый видимый чанк реально построен")

	scene._refresh_visible(true)
	_check(scene._rebuild_pending.has(focus) and scene._pending.has(focus),
		"После изменения природы видимый чанк обязательно обновляется")

	# Предыдущая реализация могла потерять эту задачу при небольшом сдвиге.
	scene._move_center(Vector2(1.2, 0.0))
	_check(scene._rebuild_pending.has(focus) and scene._pending.has(focus),
		"Панорама внутри чанка не отменяет физическую пересборку")
	_check(scene._active[focus] == old_node,
		"Старый видимый меш остаётся до замены, без пустоты")

	scene._pending.erase(focus)
	scene._create_chunk(focus)
	_check(scene._active[focus] != old_node and
		old_node.is_queued_for_deletion(),
		"Готовый новый меш заменяет старый")
	_check(not scene._rebuild_pending.has(focus),
		"После построения отметка обязательной пересборки удаляется")
	_check(scene._chunk_rebuilds == 2,
		"Обычная и обязательная пересборка учитываются раздельно")

	# Невозможная координата в очереди не может создать меш вне мира.
	var stale := Vector2i(-4, -4)
	scene._pending.insert(0, stale)
	var skipped_before: int = scene._skipped_stale_jobs
	scene._process(1.0 / 60.0)
	_check(scene._skipped_stale_jobs > skipped_before,
		"Старая задача удаляется без обращения к генератору меша")
	_check(not scene._active.has(stale),
		"Невидимый чанк не попадает в активные узлы")

	scene._refresh_visible(true)
	var current: Node3D = scene._active[focus]
	scene._move_center(Vector2(95.0, 0.0))
	_check(not scene._active.has(focus),
		"При быстром перемещении старый участок исключается из видимых")
	_check(not scene._render_cache.has(focus),
		"Устаревший меш не переносится в кеш GPU")
	_check(current.is_queued_for_deletion(),
		"Устаревший меш освобождается после выхода из кадра")
	_check(scene._world_model.to_data() == baseline,
		"Алгоритм не меняет высоты и формат сохранений")
	print("Этап 8.6: построено ", scene._chunk_rebuilds,
		", отброшено устаревших задач ", scene._skipped_stale_jobs,
		", бюджет при движении ", scene._mesh_build_budget_us, " мкс")
	scene.queue_free()


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_test_priority()
	_test_real_scene()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 8.6: " + reason)
		quit(1)
		return
	print("Этап 8.6: приоритеты, бюджет и обязательные GPU-пересборки — успешно.")
	quit(0)
