extends "res://scripts/climate.gd"
## Изолированная исходная суточная формула климата до оптимизации.
## Хранит результаты в тех же полях экземпляра, что и новый Climate.
## Нужна только для сравнения производительности и точности в CI;
## код игры не использует и не загружает этот класс.


func _calculate_day(rows: Dictionary = {}) -> void:
	# Подлинное вычисление старой версии: сезон, ветровой период
	# и широтный дождевой множитель заново считаются на каждой
	# клетке. Для честного профиля поля пишутся непосредственно
	# в массивы _temperature/_rain/_wind/_storm, как в Climate.
	for y in range(_height):
		if not rows.is_empty() and not rows.has(y):
			continue
		var latitude := (float(y) + 0.5) / float(_height)
		for x in range(_width):
			var i := y * _width + x
			var season := sin(TAU * float(day % YEAR_DAYS) / float(YEAR_DAYS))
			var rain_factor := _seasonal_rain_factor(day, latitude)
			var amplitude := lerpf(13.0, 6.0, latitude) * \
				(1.0 - _marine[i] * 0.28)
			var front := _smooth_noise((float(x) + float(day) * 1.8) / 55.0,
				(float(y) - float(day) * 0.65) / 49.0, world.config.world_seed + 990)
			var local := _smooth_noise((float(x) + float(day) * 0.7) / 38.0,
				(float(y) + float(day) * 0.4) / 38.0, world.config.world_seed + 991)
			_temperature[i] = _mean[i] + season * amplitude + front * 3.1
			var threshold := 0.11 - _humidity[i] * 0.20
			var convection := clampf((_temperature[i] - 7.0) / 17.0, 0.0, 1.0) \
				* clampf((_humidity[i] - 0.24) / 0.52, 0.0, 1.0)
			var frontal_lift := clampf(0.55 + front * 0.60
				+ local * 0.38, 0.0, 1.0)
			_storm[i] = clampf(convection * frontal_lift, 0.0, 1.0)
			_rain[i] = clampf(maxf(0.0, local * 0.9 + front * 0.4 - threshold)
				* _humidity[i] * 2.5 * rain_factor
				+ _storm[i] * 1.35, 0.0, 3.0)
			_wind[i] = clampf(5.0 + absf(front) * 10.0
				+ _storm[i] * 5.0 + maxf(0.0, -local) * 3.0
				+ 2.5 * absf(sin(TAU * float(day % YEAR_DAYS) / YEAR_DAYS))
				+ _marine[i] * 1.5, 0.0, 24.0)
	revision += 1
	weather_changed.emit(day)
