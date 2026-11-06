extends Node3D
## Этап 11.0: единая точка управления погодными визуальными эффектами.
## Физические источники не создаются и не сохраняются в этом узле:
## Climate, NaturalDisasters и WeatherEvents остаются единственной истиной.

const Precipitation = preload("res://scripts/weather_fx_controller.gd")
const Lightning = preload("res://scripts/lightning_fx_controller.gd")
const Catalog = preload("res://scripts/weather_effect_catalog.gd")

const QUALITY_NAMES := ["Экономно", "Стандарт", "Подробно"]

var precipitation: Node3D
var lightning: Node3D
var _quality := 1
var _enabled := true
var _last_visual_day := -1


func _ready() -> void:
	# Создаём контроллеры один раз. Другие сцены могут продолжать
	# пользоваться существующими методами Precipitation/Lightning,
	# но решение о качестве и отключении принимает только этот узел.
	precipitation = Precipitation.new()
	precipitation.name = "Осадки, ветер и пыль"
	add_child(precipitation)
	lightning = Lightning.new()
	lightning.name = "Разряды и гром"
	add_child(lightning)
	set_quality(_quality)


func set_quality(level: int) -> void:
	# Профиль ограничивает GPU-бюджеты всех погодных семейств.
	# Изменение качества не вызывает расчёт игрового дня и
	# не читает физические массивы работающего фонового потока.
	_quality = clampi(level, 0, 2)
	if precipitation != null:
		precipitation.set_quality(_quality)
	if lightning != null:
		lightning.set_quality(_quality)


func set_effects_enabled(enabled: bool) -> void:
	# Переключение диагностического слоя или режима замера
	# останавливает все частицы, световые каналы и звук вместе.
	# Историю ударов удерживаем, чтобы при возвращении к карте
	# не показать снова уже произошедшую молнию.
	if _enabled == enabled:
		return
	_enabled = enabled
	if precipitation != null:
		precipitation.set_effects_enabled(enabled)
	if not enabled and lightning != null:
		lightning.clear(_last_visual_day)


func sync_world(climate: RefCounted, world: RefCounted,
		center: Vector2, zoom: float) -> void:
	# Только здесь читаем готовые климатические поля; вызывающий
	# World делает это после завершения суточного WorkerThreadPool.
	# Даже при выключенных частицах снимок остаётся доступен
	# для климатического освещения и водного шейдера.
	if precipitation == null or world == null or climate == null:
		return
	precipitation.sync_world(climate, world, center, zoom)


func show_lightning(strikes: Array[Dictionary], world: RefCounted,
		center: Vector2, zoom: float, day: int,
		allow_visuals: bool = true) -> int:
	# Предоставляем LightingFX только завершённые физические
	# события одного дня. При отключённой графике день отмечаем
	# обработанным, чтобы вспышка не возникла после её включения.
	_last_visual_day = maxi(_last_visual_day, day)
	if lightning == null:
		return 0
	return lightning.show_strikes(strikes, world, center, zoom, day,
		_enabled and allow_visuals)


func show_hazard(hazard: Dictionary, direction: Vector2) -> void:
	# Штормовые частицы — реакция на NaturalDisasters.
	# Это единая диспетчеризация существующих эффектов; новых
	# случайных бедствий или урона здесь не создаётся.
	if not _enabled or precipitation == null:
		return
	var severity := clampf(float(hazard.get("severity", 0.0)), 0.0, 1.0)
	match str(hazard.get("kind", "")):
		"шторм":
			precipitation.show_storm_event(severity, direction)
		"шквал":
			precipitation.show_squall_event(severity, direction)
		"ураган":
			precipitation.show_hurricane_event(severity, direction)
		"смерч":
			precipitation.show_tornado_event(severity, direction)
		"пыльная буря":
			precipitation.show_dust_storm_event(severity, direction)


func clear_after_load(last_day: int) -> void:
	# В новом или загруженном мире нельзя оставлять маску
	# прежнего Climate, порывы, световые импульсы и звук.
	# Сохранённая история молний не воспроизводится повторно.
	_last_visual_day = last_day
	if precipitation != null:
		precipitation.clear_visuals()
	if lightning != null:
		lightning.clear(last_day)


func effect_catalog() -> Array[Dictionary]:
	# Возвращаем копию каталога, чтобы диагностика и тесты
	# не могли редактировать исходные сведения о ресурсах.
	return Catalog.entries().duplicate(true)


func debug_budget() -> Dictionary:
	# Проверяем фактическое число созданных GPU-эмиттеров,
	# а не декларируемое количество, которое могло устареть.
	var count := 0
	var allocated := 0
	if precipitation != null:
		for child in precipitation.get_children():
			if child is GPUParticles3D:
				count += 1
				allocated += child.amount
	return {
		"quality": _quality,
		"enabled": _enabled,
		"gpu_emitters": count,
		"gpu_max_particles": allocated,
		"lightning_slots": Lightning.MAX_VISIBLE_BOLTS,
		"catalog_entries": Catalog.entries().size(),
		"last_visual_day": _last_visual_day
	}
