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
