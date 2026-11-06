extends RefCounted
## Этап 11.2/L4: только визуальные параметры света из снимка Climate.
## Отдельные погодные события, облака и разряды здесь не создаются.


static func from_snapshot(snapshot: Dictionary) -> Dictionary:
	## Превращаем уже рассчитанную облачность/грозу в освещение.
	## Копируем числовые значения: рендер не владеет словарём климата.
	var cloud := clampf(float(snapshot.get("cloud", 0.0)), 0.0, 1.0)
	var storm := clampf(float(snapshot.get("storm", 0.0)), 0.0, 1.0)
	var dimming := clampf(cloud * 0.58 + storm * 0.48, 0.0, 1.0)
	var cold_tint := clampf(cloud * 0.19 + storm * 0.68, 0.0, 1.0)
	# Дымка не возникает случайно: влажный тихий фронт даёт
	# мягкую воздушную перспективу, осадки и гроза — более плотную.
	# Порывы уменьшают локальный стелющийся туман, но не убирают
	# завесу ливня. Все величины ограничены для мобильного GPU.
	var rain := clampf(float(snapshot.get("rain", 0.0)), 0.0, 1.0)
	var snow := clampf(float(snapshot.get("snow", 0.0)), 0.0, 1.0)
	var wind := clampf(float(snapshot.get("wind", 0.0)), 0.0, 1.0)
	# Разорванные облака сами по себе НЕ создают серую завесу.
	# Приземный туман требует фактической влажности выше 84% и
	# слабого ветра; ливень и гроза добавляют свою дождевую дымку.
	var humidity := clampf(float(snapshot.get("humidity", 0.0)), 0.0, 1.0)
	var quiet_mist := smoothstep(0.84, 0.96, humidity) * (
		1.0 - storm) * (1.0 - wind * 0.70)
	var fog_strength := clampf(quiet_mist * 0.38 +
		rain * 0.26 + snow * 0.17 + storm * 0.32, 0.0, 1.0)
	# Солнечные окна ярче всего при разорванной облачности,
	# а во время сплошной грозы исчезают без искусственных вспышек.
	var sunbreak := (smoothstep(0.13, 0.42, cloud)
		* (1.0 - smoothstep(0.73, 0.98, cloud))
		* (1.0 - storm * 0.94))

	# Под сплошной облачностью солнце и окружающий свет ослабевают.
	# При ясной погоде точно возвращаются исходные значения сцены.
	return {
		"sun_energy": lerpf(1.38, 0.62, dimming),
		"sun_color": Color(1.0, 0.94, 0.84).lerp(
			Color(0.72, 0.78, 0.86), cold_tint),
		"ambient_energy": lerpf(0.37, 0.32, dimming),
		"sky_color": Color(0.54, 0.65, 0.69).lerp(
			Color(0.34, 0.39, 0.46), dimming),
		"cloud_coverage": clampf(maxf(cloud, storm * 0.88), 0.0, 1.0),
		"cloud_sunbreak": sunbreak,
		"wind": wind,
		"wind_x": float(snapshot.get("wind_x", 0.0)),
		"wind_y": float(snapshot.get("wind_y", 0.0)),
		# Общий Environment затуманивает грунт, воду и лес одинаково.
		# Экспоненциальная дымка не расходует объёмные froxel-буферы.
		"fog_strength": fog_strength,
		"fog_density": 0.001 + fog_strength * 0.013,
		"fog_height_density": fog_strength * 0.0035,
		"fog_color": Color(0.67, 0.76, 0.80).lerp(
			Color(0.37, 0.43, 0.51), clampf(storm * 0.9 + cloud * 0.20, 0.0, 1.0)),
		"fog_sun_scatter": 0.32 * sunbreak + 0.08 * (1.0 - storm)
	}


static func blend(current: Dictionary, target: Dictionary, delta: float) -> Dictionary:
	## Сглаживаем только визуальные параметры при перемещении камеры
	## или смене физического погодного фронта; источник Climate не трогаем.
	## Экспоненциальная доля почти независима от FPS и не скачет,
	## когда снимок климата обновился не на границе игрового кадра.
	if target.is_empty():
		return current.duplicate(true)
	if current.is_empty():
		return target.duplicate(true)
	if not is_finite(delta) or delta <= 0.0:
		return current.duplicate(true)
	var alpha := 1.0 - exp(-minf(delta, 5.0) / 0.85)
	var result := {}
	for key in target:
		# Color и float поддерживают одинаковую логику интерполяции.
		# Эти величины уходят только в uniform-ы и источники света.
		if target[key] is Color:
			result[key] = (current[key] as Color).lerp(target[key], alpha)
		else:
			result[key] = lerpf(float(current[key]), float(target[key]), alpha)
	return result
