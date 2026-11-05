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

	# Под сплошной облачностью солнце и окружающий свет ослабевают.
	# При ясной погоде точно возвращаются исходные значения сцены.
	return {
		"sun_energy": lerpf(1.25, 0.62, dimming),
		"sun_color": Color(1.0, 0.94, 0.84).lerp(
			Color(0.72, 0.78, 0.86), cold_tint),
		"ambient_energy": lerpf(0.61, 0.43, dimming),
		"sky_color": Color(0.54, 0.65, 0.69).lerp(
			Color(0.34, 0.39, 0.46), dimming),
		"cloud_coverage": clampf(maxf(cloud, storm * 0.88), 0.0, 1.0),
		"wind": clampf(float(snapshot.get("wind", 0.0)), 0.0, 1.0)
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
