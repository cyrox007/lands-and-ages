extends RefCounted
## Единый адаптивный бюджет визуализации 11.9/P2.
## Не хранит и не меняет WorldMap, Climate, NatureRegistry или WorldSave.
## Профиль автора — верхняя граница, а не разрешение повышать качество.

const BASE_PARTICLE_COUNTS := [640, 320, 220, 180, 240, 180, 300, 220]
const PARTICLE_FRACTIONS := [0.45, 0.72, 1.0]
const MAX_GPU_EMITTERS := 8
const MAX_GPU_PARTICLES := 2300
const MAX_NEW_CHUNKS_PER_FRAME := 2
const MAX_NATURE_REFRESHES_PER_FRAME := 2

var effective_quality := 1
var _pressure_cap := 2
var _slow_samples := 0
var _stable_samples := 0
var quality_changes := 0


static func particle_amounts(quality: int) -> Array[int]:
	# Сумма фактически выделенных GPU-слотов, а не коэффициентов
	# amount_ratio. Число эмиттеров постоянно при любом качестве.
	var level := clampi(quality, 0, 2)
	var factor: float = PARTICLE_FRACTIONS[level]
	var amounts: Array[int] = []
	for base in BASE_PARTICLE_COUNTS:
		amounts.append(maxi(1, roundi(float(base) * factor)))
	return amounts


static func particle_limit(quality: int) -> int:
	# Тот же контракт использует отладочный HUD и CI; отсутствие
	# события не разрешает выделять больше чем восемь пулов.
	var total := 0
	for count in particle_amounts(quality):
		total += count
	return total


static func zoom_cap(zoom: float) -> int:
	# Дальний обзор снижает число GPU-слотов даже при дорогом
	# пользовательском пресете, не скрывая сам физический снег.
	if not is_finite(zoom):
		return 0
	if zoom >= 90.0:
		return 0
	if zoom >= 70.0:
		return 1
	return 2


func resolve(user_quality: int, zoom: float, p95_ms: float) -> int:
	# Перегрузку фиксируем по нескольким 150-мс выборкам:
	# одиночный длинный кадр от загрузки нового чанка не должен
	# менять качество и перезапускать все восемь эмиттеров.
	if is_finite(p95_ms) and p95_ms >= 23.0:
		_slow_samples += 1
		_stable_samples = 0
		if _slow_samples >= 2:
			_pressure_cap = 0 if p95_ms >= 29.0 else mini(_pressure_cap, 1)
			_slow_samples = 0
	elif is_finite(p95_ms) and p95_ms > 0.0 and p95_ms <= 18.0:
		_stable_samples += 1
		_slow_samples = 0
		if _stable_samples >= 8:
			_pressure_cap = mini(2, _pressure_cap + 1)
			_stable_samples = 0
	else:
		# Между 18 и 23 мс ничего не переключаем: это гистерезис.
		_slow_samples = 0
		_stable_samples = 0

	var next_quality := mini(mini(clampi(user_quality, 0, 2),
		zoom_cap(zoom)), _pressure_cap)
	if next_quality != effective_quality:
		effective_quality = next_quality
		quality_changes += 1
	return effective_quality


static func nature_refresh_limit(p95_ms: float) -> int:
	# Минимум одна пересборка за кадр: даже на слабом устройстве
	# физические изменения видимой природы не должны зависнуть.
	return 1 if is_finite(p95_ms) and p95_ms >= 22.0 else 		MAX_NATURE_REFRESHES_PER_FRAME


static func weather_sync_interval(zoom: float, p95_ms: float) -> float:
	# Вдали и при перегрузке реже обновляем визуальную маску из
	# климатического поля. Сама климатическая физика идёт ежедневно.
	if zoom >= 90.0 or (is_finite(p95_ms) and p95_ms >= 29.0):
		return 0.95
	if zoom >= 70.0 or (is_finite(p95_ms) and p95_ms >= 23.0):
		return 0.65
	return 0.35


func debug_state() -> Dictionary:
	# Эти сведения — ограничение рендера, не измерение GPU/VRAM.
	return {
		"effective_quality": effective_quality,
		"pressure_cap": _pressure_cap,
		"gpu_emitters_limit": MAX_GPU_EMITTERS,
		"gpu_particles_limit": particle_limit(effective_quality),
		"nature_refreshes_limit": MAX_NATURE_REFRESHES_PER_FRAME,
		"quality_changes": quality_changes
	}
