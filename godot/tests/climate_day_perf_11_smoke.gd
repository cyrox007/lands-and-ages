extends SceneTree
## 11/CLIMATE-PERF: суточный климат 256×192 с прямым
## сравнением старой формулы, новых массивов и времени.
## Тест намеренно не подменяет гидрологию и не подгоняет погоду.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Climate = preload("res://scripts/climate.gd")
const WIDTH := 256
const HEIGHT := 192
const DAYS := [1, 24, 49, 73, 96]
var failures: Array[String] = []


func _check(ok: bool, description: String) -> void:
	# Каждое нарушение регистрируем отдельно, чтобы изменение
	# скорости не маскировало отличия физических данных.
	if not ok:
		failures.append(description)


func _reference_day(climate: RefCounted) -> Dictionary:
	# Независимая эталонная копия первоначального суточного
	# расчёта: сезон и дождевой множитель вычисляются В КАЖДОЙ
	# клетке. Никаких значений, подготовленных оптимизацией,
	# здесь не используем, кроме неизменных средних полей.
	var count: int = climate._width * climate._height
	var temperature := PackedFloat32Array()
	var rain := PackedFloat32Array()
	var wind := PackedFloat32Array()
	var storm := PackedFloat32Array()
	# Размер выделяем по каждому PackedFloat32Array напрямую:
	# временная переменная цикла использовала бы копию Variant.
	temperature.resize(count)
	rain.resize(count)
	wind.resize(count)
	storm.resize(count)
	var day: int = climate.day
	var seed: int = climate.world.config.world_seed
	for y in range(climate._height):
		var latitude := (float(y) + 0.5) / float(climate._height)
		for x in range(climate._width):
			var i := y * climate._width + x
			var season := sin(TAU * float(day % Climate.YEAR_DAYS) /
				float(Climate.YEAR_DAYS))
			var rain_factor := Climate._seasonal_rain_factor(day, latitude)
			var amplitude := lerpf(13.0, 6.0, latitude) * \
				(1.0 - climate._marine[i] * 0.28)
			var front := Climate._smooth_noise(
				(float(x) + float(day) * 1.8) / 55.0,
				(float(y) - float(day) * 0.65) / 49.0, seed + 990)
			var local := Climate._smooth_noise(
				(float(x) + float(day) * 0.7) / 38.0,
				(float(y) + float(day) * 0.4) / 38.0, seed + 991)
			temperature[i] = climate._mean[i] + season * amplitude + front * 3.1
			var threshold := 0.11 - climate._humidity[i] * 0.20
			var convection := clampf((temperature[i] - 7.0) / 17.0, 0.0, 1.0) * \
				clampf((climate._humidity[i] - 0.24) / 0.52, 0.0, 1.0)
			var frontal_lift := clampf(0.55 + front * 0.60 \
				+ local * 0.38, 0.0, 1.0)
			storm[i] = clampf(convection * frontal_lift, 0.0, 1.0)
			rain[i] = clampf(maxf(0.0, local * 0.9 + front * 0.4 - threshold) \
				* climate._humidity[i] * 2.5 * rain_factor \
				+ storm[i] * 1.35, 0.0, 3.0)
			wind[i] = clampf(5.0 + absf(front) * 10.0 \
				+ storm[i] * 5.0 + maxf(0.0, -local) * 3.0 \
				+ 2.5 * absf(sin(TAU * float(day % Climate.YEAR_DAYS) /
				Climate.YEAR_DAYS)) + climate._marine[i] * 1.5, 0.0, 24.0)
	return {"temperature": temperature, "rain": rain,
		"storm": storm, "wind": wind}


func _same_fields(climate: RefCounted, expected: Dictionary,
		day: int) -> void:
	# Сравнение всех 49 152 клеток каждого поля использует
	# равенство PackedFloat32Array, а не выборку трёх точек.
	# Так ловим любое смещение грозы, осадков или ветра.
	_check(climate._temperature == expected["temperature"],
		"Температура полностью совпадает на дне %d" % day)
	_check(climate._rain == expected["rain"],
		"Осадки полностью совпадают на дне %d" % day)
	_check(climate._wind == expected["wind"],
		"Ветер полностью совпадает на дне %d" % day)
	_check(climate._storm == expected["storm"],
		"Грозы полностью совпадают на дне %d" % day)


func _run() -> void:
	var world := Map.new(Config.new(WIDTH, HEIGHT, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var legacy_us := 0
	var optimized_us := 0
	for day in DAYS:
		# Сначала измеряем прежний код на тех же неизменных
		# средних климатических полях, затем текущую формулу.
		climate.day = day
		var before := Time.get_ticks_usec()
		var expected := _reference_day(climate)
		legacy_us += Time.get_ticks_usec() - before
		before = Time.get_ticks_usec()
		climate._calculate_day()
		optimized_us += Time.get_ticks_usec() - before
		_same_fields(climate, expected, day)

	# Частичная перестройка не должна менять погоду в строках,
	# которых не коснулось изменение грунта.
	climate.day = 37
	var unaffected: float = climate._rain[110 * WIDTH + 80]
	var selected := {0: true, 95: true, 191: true}
	var partial_reference: Dictionary = _reference_day(climate)
	climate._calculate_day(selected)
	for y in selected:
		for x in range(WIDTH):
			var i: int = y * WIDTH + x
			_check(climate._rain[i] == partial_reference["rain"][i],
				"Частичная пересборка осадков на широте %d" % y)
	_check(climate._rain[110 * WIDTH + 80] == unaffected,
		"Строка вне частичной перестройки не меняется")

	var ratio := float(optimized_us) / float(maxi(1, legacy_us))
	print("CLIMATE-PERF: 256×192, пять сезонов, старый расчёт=",
		legacy_us, " мкс, новый=", optimized_us, " мкс, коэффициент=", ratio)
	# Используем один runner без конкурирующей нагрузки; даже
	# фоновая CI-машина может менять абсолютную скорость, поэтому
	# сравниваем только тот же код и те же входные данные.
	_check(ratio < 0.90, "Климат стал заметно быстрее прежней формулы")
	if not failures.is_empty():
		for failure in failures.slice(0, 25):
			push_error("CLIMATE-PERF: " + failure)
		print("CLIMATE-PERF: ошибок ", failures.size())
		quit(1)
		return
	print("CLIMATE-PERF: полный климат неизменен, ускорение подтверждено — успешно")
	quit(0)


func _initialize() -> void:
	_run()
