extends SceneTree
## #93: отмена уже выполняющейся подготовки PBR и воды без GPU-ресурсов.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Water = preload("res://scripts/water_mesh.gd")
const Worker = preload("res://scripts/chunk_build_worker.gd")
const Appearance = preload("res://scripts/landscape_appearance.gd")

var failures: Array[String] = []
var probes := 0
var stop_after := 0


func _check(ok: bool, reason: String) -> void:
	# Не останавливаем тест после первой ошибки: проверяем
	# отдельно грунт, береговой кеш, воду и результат воркера.
	if not ok:
		failures.append(reason)


func _stop() -> bool:
	# Управляемая отмена после нескольких проверок доказывает,
	# что остановлен именно выполняющийся цикл, а не только
	# задание, которое ещё не успело начаться.
	probes += 1
	return probes >= stop_after


func _cancel_after(limit: int) -> Callable:
	# У каждого сценария свой порог, поэтому проверка не зависит
	# от времени выполнения и скорости CI-машины.
	probes = 0
	stop_after = limit
	return Callable(self, "_stop")


func _initialize() -> void:
	# Используем действительные модели, чтобы поймать ошибки
	# интерфейсов и совместимость с физической гидрологией.
	var world := Map.new(Config.new(32, 32, 1729, 16, 16))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var before: Dictionary = world.to_data()
	var wet_before: Dictionary = hydro.water_count()
	var soil_before: Dictionary = surface.to_snapshot()
	var bounds: Rect2i = world.config.chunk_rect(Vector2i.ZERO)

	# Первый вызов проходит начальную проверку и останавливается
	# внутри цикла гидрологических проб, не возвращая полусетку.
	var shore := Appearance.near_water_grid(bounds, world, hydro,
		_cancel_after(4))
	_check(shore.is_empty() and probes >= 4,
		"Береговой кеш отменён в середине чтения физической воды")

	# Чанк прерывается как во время подготовки берегового кеша,
	# так и после него — во время создания цветовых PBR-вершин.
	var early: Array = Chunk.prepare_arrays(0, 0, 1, world, surface,
		0, null, hydro, true, _cancel_after(5))
	_check(early.is_empty() and probes >= 5,
		"Прерванное построение PBR не отдаёт частичный массив")
	var later: Array = Chunk.prepare_arrays(0, 0, 1, world, surface,
		0, null, hydro, true, _cancel_after(50))
	_check(later.is_empty() and probes >= 50,
		"Отмена после кеширования прерывает уже выполняемый чанк")
	var water: Array = Water.prepare_arrays(world, hydro,
		Vector2i.ZERO, surface, null, _cancel_after(3))
	_check(water.is_empty() and probes >= 3,
		"Вода прекращает работу между строками без частичного меша")

	# В обычном режиме новая проверка не меняет результат:
	# при отсутствии отмены получается та же геометрия.
	var normal: Array = Chunk.prepare_arrays(0, 0, 1, world,
		surface, 0, null, hydro)
	var untouched: Array = Chunk.prepare_arrays(0, 0, 1, world,
		surface, 0, null, hydro, true, Callable(self, "_never_stop"))
	_check(normal == untouched and normal.size() == Mesh.ARRAY_MAX,
		"Неотменённая подготовка побайтово идентична прежней")
	var water_normal: Array = Water.prepare_arrays(world, hydro,
		Vector2i.ZERO, surface)
	var water_untouched: Array = Water.prepare_arrays(world, hydro,
		Vector2i.ZERO, surface, null, Callable(self, "_never_stop"))
	_check(water_normal == water_untouched,
		"Неотменённая вода сохраняет прежние вершины и UV")

	# Настоящий worker проверяем до запуска и после завершения.
	# Отмена результата не должна оставлять массивы для GPU.
	var worker := Worker.new(Vector2i.ZERO, 0, world, surface, null, hydro)
	worker.cancel()
	worker.run()
	_check(worker.arrays.is_empty() and worker.water_arrays.is_empty(),
		"Worker не публикует результат отменённого задания")
	_check(world.to_data() == before
		and hydro.water_count() == wet_before
		and surface.to_snapshot() == soil_before,
		"Прерывание не меняет рельеф, гидрологию и грунт")

	if not failures.is_empty():
		for reason in failures:
			push_error("#93/CANCEL: " + reason)
		quit(1)
		return
	print("#93/CANCEL: отмена внутри CPU-проходов, точная геометрия и физика — успешно")
	quit(0)


func _never_stop() -> bool:
	# Эталонный обратный вызов нужен для доказательства того,
	# что сам механизм проверки не влияет на результаты рендера.
	return false
