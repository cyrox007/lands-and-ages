extends SceneTree
## 11/CLIMATE-PERF: измерение и полное физическое сравнение
## старой и новой реализации на одной карте 256×192.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const Legacy = preload("res://tests/climate_day_legacy_reference.gd")
const WIDTH := 256
const HEIGHT := 192
const DAYS := [1, 24, 49, 73, 96]
var failures: Array[String] = []


func _check(condition: bool, description: String) -> void:
	# Ошибки физических полей перечисляем по компоненту и дню,
	# даже если остальные компоненты продолжают работать.
	if not condition:
		failures.append(description)


func _same_fields(old: RefCounted, current: RefCounted, day: int) -> void:
	# Сравниваем все 49 152 значения каждого массива — в точности,
	# без допусков и усреднения. Сохранения и реальные механики
	# используют именно эти исходные значения температуры, дождя,
	# ветра и силы грозы.
	_check(old._temperature == current._temperature,
		"Температура полностью совпадает на дне %d" % day)
	_check(old._rain == current._rain,
		"Осадки полностью совпадают на дне %d" % day)
	_check(old._wind == current._wind,
		"Ветер полностью совпадает на дне %d" % day)
	_check(old._storm == current._storm,
		"Грозы полностью совпадают на дне %d" % day)


func _run() -> void:
	var world := Map.new(Config.new(WIDTH, HEIGHT, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	# Оба экземпляра получают одни и те же карты и одинаковый
	# способ записи в собственные PackedFloat32Array. Отличие
	# только в повторном вычислении сезонных коэффициентов.
	var original := Legacy.new(world, hydro)
	var optimized := Climate.new(world, hydro)
	original.rebuild()
	optimized.rebuild()
	_same_fields(original, optimized, 0)
	var old_us := 0
	var new_us := 0
	# Два последовательных сезонных цикла уменьшают влияние
	# одиночной перегрузки GitHub runner; результаты считаются
	# по сумме длительностей 10 одинаковых физических дней.
	for pass_index in range(2):
		for day in DAYS:
			# Меняем порядок этапов во втором цикле, чтобы
			# систематический прогрев не делал новую формулу быстрее
			# только из-за порядка измерения.
			var start: int = Time.get_ticks_usec()
			if pass_index == 0:
				original.set_day(day)
				old_us += Time.get_ticks_usec() - start
				start = Time.get_ticks_usec()
				optimized.set_day(day)
				new_us += Time.get_ticks_usec() - start
			else:
				optimized.set_day(day)
				new_us += Time.get_ticks_usec() - start
				start = Time.get_ticks_usec()
				original.set_day(day)
				old_us += Time.get_ticks_usec() - start
			_same_fields(original, optimized, day)

	# Частичная перестройка не должна менять погоду вне выбранных
	# широт даже в середине другого сезона.
	var untouched: float = optimized._rain[110 * WIDTH + 80]
	original.day = 37
	optimized.day = 37
	var rows := {0: true, 95: true, 191: true}
	original._calculate_day(rows)
	optimized._calculate_day(rows)
	_same_fields(original, optimized, 37)
	_check(optimized._rain[110 * WIDTH + 80] == untouched,
		"Строка вне частичной перестройки остаётся прежней")

	var ratio := float(new_us) / float(maxi(1, old_us))
	print("CLIMATE-PERF: 256×192, 10 суточных шагов, старая формула=",
		old_us, " мкс, новая=", new_us, " мкс, коэффициент=", ratio)
	# Требование касается только фактически измеренного времени
	# климата. Полный игровой день, GPU и аппаратный FPS не входят
	# в этот тест и не считаются ускоренными автоматически.
	_check(ratio < 0.90, "Суточный климат быстрее прежней формулы минимум на 10%")
	if not failures.is_empty():
		for failure in failures.slice(0, 25):
			push_error("CLIMATE-PERF: " + failure)
		print("CLIMATE-PERF: нарушений ", failures.size())
		quit(1)
		return
	print("CLIMATE-PERF: поля климата неизменны, ускорение подтверждено — успешно")
	quit(0)


func _initialize() -> void:
	_run()
