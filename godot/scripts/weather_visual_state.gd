extends RefCounted
## Этап 11.0: снимок погоды для рендера без изменения физики мира.
## Снимок можно строить в главном потоке после завершения суточного расчёта.


static func from_weather(weather: Dictionary) -> Dictionary:
	## Приводим физические значения к ограниченным параметрам частиц.
	## Эта функция ничего не записывает в климат, поверхность или воду.
	var rainfall := maxf(0.0, float(weather.get("rainfall", 0.0)))
	var snowfall := maxf(0.0, float(weather.get("snowfall", 0.0)))
	var wind := maxf(0.0, float(weather.get("wind_speed", 0.0)))
	var storm := clampf(float(weather.get("storm_intensity", 0.0)), 0.0, 1.0)
	# Направление и максимум порыва берём из Climate; отсутствие поля
	# означает отсутствие данных, а не выдуманный западный ветер.
	var direction := Vector2(float(weather.get("wind_direction_x", 0.0)),
		float(weather.get("wind_direction_y", 0.0)))
	if direction.length_squared() > 0.000001:
		direction = direction.normalized()
	var gust := maxf(wind, float(weather.get("wind_gust", wind)))
	# Плотность облачного фронта зависит от физической влажности,
	# осадков и грозовой неустойчивости, а не случайной текстуры.
	var humidity := clampf(float(weather.get("humidity", 0.0)), 0.0, 1.0)
	var precipitation := clampf((rainfall + snowfall) / 2.4, 0.0, 1.0)
	var clouds := clampf(smoothstep(0.58, 0.92, humidity) * 0.56
		+ precipitation * 0.34 + storm * 0.42, 0.0, 1.0)
	return {
		"rain": clampf(rainfall / 2.4, 0.0, 1.0),
		"snow": clampf(snowfall / 2.4, 0.0, 1.0),
		"wind": clampf(wind / 24.0, 0.0, 1.0),
		"gust": clampf(gust / 36.0, 0.0, 1.0),
		"wind_x": direction.x, "wind_y": direction.y,
		"storm": storm,
		"cloud": clouds,
		"rainfall": rainfall,
		"snowfall": snowfall
	}


static func sample(climate: RefCounted, config: RefCounted,
		center: Vector2, zoom: float) -> Dictionary:
	## Усредняем пять точек в видимой области: это не даёт одной клетке
	## принудительно включить дождь над всей камерой у края фронта.
	## Радиус ограничен, чтобы не читать всю огромную карту по кадрам.
	var distance := clampf(zoom * 0.32, 4.0, 24.0)
	var offsets := [
		Vector2.ZERO, Vector2(distance, 0.0),
		Vector2(-distance, 0.0), Vector2(0.0, distance),
		Vector2(0.0, -distance)
	]
	var total_rain := 0.0
	var total_snow := 0.0
	var total_wind := 0.0
	var total_gust := 0.0
	var flow := Vector2.ZERO
	var total_storm := 0.0
	var total_cloud := 0.0
	for offset in offsets:
		# Граничные камеры всегда берут корректную существующую клетку.
		var point: Vector2 = config.clamp_point(center + offset)
		var weather: Dictionary = from_weather(
			climate.weather_at(config.cell_at(point)))
		total_rain += float(weather["rainfall"])
		total_snow += float(weather["snowfall"])
		total_wind += float(weather["wind"])
		total_gust += float(weather["gust"])
		# Векторы усредняем с весом скорости: два встречных ветра
		# взаимно компенсируются, не создавая фиктивного направления.
		flow += Vector2(float(weather["wind_x"]),
			float(weather["wind_y"])) * float(weather["wind"])
		total_storm += float(weather["storm"])
		total_cloud += float(weather["cloud"])
	var count := float(offsets.size())
	var direction := flow.normalized() if flow.length_squared() > 0.000001 \
		else Vector2.ZERO
	return {
		"rain": clampf(total_rain / count / 2.4, 0.0, 1.0),
		"snow": clampf(total_snow / count / 2.4, 0.0, 1.0),
		"wind": clampf(total_wind / count, 0.0, 1.0),
		"gust": clampf(total_gust / count, 0.0, 1.0),
		"wind_x": direction.x, "wind_y": direction.y,
		"storm": clampf(total_storm / count, 0.0, 1.0),
		"cloud": clampf(total_cloud / count, 0.0, 1.0)
	}
