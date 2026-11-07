extends SceneTree
## Этап 11.3: выразительность смерча и пыли без дублирования физики.
## Погодный рендер принимает только готовые события NaturalDisasters.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Atmosphere = preload("res://scripts/weather_atmosphere_controller.gd")
const Visual = preload("res://scripts/weather_visual_state.gd")
const FX = preload("res://scripts/weather_fx_controller.gd")

var failures: Array[String] = []


func _check(value: bool, description: String) -> void:
	# Отдельная проверка сообщает, где именно разошлись геометрия,
	# источник физического события и ограничение GPU-бюджета.
	if not value:
		failures.append(description)


func _snapshot() -> Dictionary:
	# Один неизменяемый климатический снимок для всех сравнений.
	# В графических тестах погода не ускоряется и не пересчитывается.
	return Visual.from_weather({
		"temperature": 22.0, "humidity": 0.27, "rainfall": 0.0,
		"snowfall": 0.0, "storm_intensity": 0.0,
		"wind_speed": 20.0, "wind_gust": 26.0,
		"wind_direction_x": 1.0, "wind_direction_y": 0.0
	})


func _test_geometry(atmosphere: Node3D, world: RefCounted) -> void:
	# Проверяем настоящую GDScript/ShaderMaterial-воронку,
	# количество вершин и привязку к реальной карте.
	var fx: Node3D = atmosphere.precipitation
	var funnel: MeshInstance3D = fx._tornado_funnel
	_check(funnel != null and not funnel.visible,
		"Без физического смерча воронка не появляется")
	var geometry := funnel.mesh as ArrayMesh
	var arrays := geometry.surface_get_arrays(0)
	_check(geometry.get_surface_count() == 1
		and arrays[Mesh.ARRAY_VERTEX].size() ==
			FX.TORNADO_RINGS * (FX.TORNADO_SIDES + 1),
		"Одна постоянная сетка воронки имеет ограниченный размер")
	_check(arrays[Mesh.ARRAY_INDEX].size() ==
		(FX.TORNADO_RINGS - 1) * FX.TORNADO_SIDES * 6,
		"Воронка не размножает треугольники по кадрам")
	_check(funnel.material_override is ShaderMaterial,
		"Турбулентные завитки формируются одним процедурным материалом")
	var physical_before := JSON.stringify(world.to_data())
	var center := Vector2i(21, 18)
	var event: Dictionary = {
		"kind": "смерч", "day": 8, "cell": center,
		"severity": 0.94, "duration_days": 1
	}
	atmosphere.show_hazard(event, Vector2.RIGHT, world)
	fx.apply_snapshot(_snapshot(), Vector2(center), 2.0, 44.0, 1729)
	var position: Vector3 = world.config.to_scene(Vector2(center) + Vector2(0.5, 0.5),
		world.height_at(Vector2(center) + Vector2(0.5, 0.5)))
	_check(funnel.visible and funnel.position.distance_to(position) < 0.001,
		"Воронка видна в физическом эпицентре, а не в центре камеры")
	var gusts: GPUParticles3D = fx._gusts
	_check(gusts.emitting and gusts.position.distance_to(
		position + Vector3.UP * 10.0) < 0.001,
		"Ветровые потоки сгруппированы вокруг настоящего смерча")
	var phase_before: float = fx._tornado_phase
	fx._process(0.12)
	_check(fx._tornado_phase > phase_before,
		"Спираль вращается при поступлении игрового визуального времени")
	paused = true
	phase_before = fx._tornado_phase
	fx._process(0.72)
	paused = false
	_check(is_equal_approx(fx._tornado_phase, phase_before),
		"Во время паузы спираль и время ветрового события неподвижны")
	fx.apply_snapshot(_snapshot(), Vector2(center), 2.0, 110.0, 1729)
	_check(not funnel.visible,
		"Дальний LOD выключает воронку без пересчёта физики")
	fx.apply_snapshot(_snapshot(), Vector2(center), 2.0, 44.0, 1729)
	_check(funnel.visible, "Возвращение камеры восстанавливает текущий смерч")
	_check(JSON.stringify(world.to_data()) == physical_before,
		"Воронка, ветер и масштаб не изменяют исходную карту")


func _test_dust(atmosphere: Node3D, world: RefCounted) -> void:
	# Зависимость пыли от фактической массы грунта сравниваем при
	# одинаковой силе ветра, seed и неизменённой карте.
	var fx: Node3D = atmosphere.precipitation
	var before := JSON.stringify(world.to_data())
	var cell := Vector2i(24, 18)
	var hazard := {
		"kind": "пыльная буря", "day": 9, "cell": cell,
		"severity": 0.96, "sediment_volume": 0.0042
	}
	atmosphere.show_hazard(hazard, Vector2.RIGHT, world)
	fx.apply_snapshot(_snapshot(), Vector2(cell), 1.0, 44.0, 1729)
	var dust: GPUParticles3D = fx._dust
	var weak_ratio: float = dust.amount_ratio
	var weak_alpha: float = (dust.draw_pass_1.material
		as StandardMaterial3D).albedo_color.a
	var point := Vector2(cell) + Vector2(0.5, 0.5)
	_check(dust.position.distance_to(world.config.to_scene(point,
		world.height_at(point)) + Vector3.UP * 2.4) < 0.001,
		"Пыль не телепортируется к камере")
	hazard["sediment_volume"] = 0.0378
	atmosphere.show_hazard(hazard, Vector2.RIGHT, world)
	fx.apply_snapshot(_snapshot(), Vector2(cell), 1.0, 44.0, 1729)
	_check(dust.amount_ratio > weak_ratio * 3.0
		and (dust.draw_pass_1.material as StandardMaterial3D)
			.albedo_color.a > weak_alpha,
		"Завеса усиливается по физически перенесённому грунту")
	_check(dust.amount == 220,
		"Усиление пыли не увеличивает выделенный GPU-лимит")
	hazard["sediment_volume"] = 0.0
	atmosphere.show_hazard(hazard, Vector2.RIGHT, world)
	fx.apply_snapshot(_snapshot(), Vector2(cell), 1.0, 44.0, 1729)
	_check(not dust.emitting,
		"При нулевом переносе массы не появляется фиктивная пыль")
	_check(JSON.stringify(world.to_data()) == before,
		"Визуализация пылевого баланса не меняет физическую почву")


func _test_budget_and_load(atmosphere: Node3D) -> void:
	# Новая сетка не выделяет дополнительные GPU-эмиттеры;
	# на выгрузке перестают существовать все временные эффекты.
	var fx: Node3D = atmosphere.precipitation
	var budget: Dictionary = atmosphere.debug_budget()
	_check(int(budget["gpu_emitters"]) == 8
		and int(budget["gpu_max_particles"]) == 2300,
		"Графика смерча и пыли укладывается в старый бюджет")
	_check(int(budget["catalog_entries"]) == 13,
		"Новая спираль зарегистрирована в каталоге ассетов")
	atmosphere.set_effects_enabled(false)
	_check(not fx._tornado_funnel.visible and not fx._dust.emitting,
		"Скрытие атмосферы останавливает воронку и пыль")
	atmosphere.set_effects_enabled(true)
	atmosphere.clear_after_load(8)
	_check(not fx._tornado_funnel.visible and not fx._dust.emitting
		and is_zero_approx(fx._event_life),
		"Сохранение и загрузка не запускают прежнее бедствие")
	_check(fx.get_child_count() == 10,
		"Десять фиксированных узлов: восемь GPU и две сетки бедствий")


func _run() -> void:
	# Отдельно проверяются геометрия, масса и сброс эффектов.
	# Смерч или пыль не объявляются доказанной природной физикой
	# по этому тесту — её проверяют прежние 11.3/V2.6–V2.9.
	var world := Map.new(Config.new(64, 48, 1729, 8, 16))
	var atmosphere := Atmosphere.new()
	root.add_child(atmosphere)
	_test_geometry(atmosphere, world)
	_test_dust(atmosphere, world)
	_test_budget_and_load(atmosphere)
	if failures.is_empty():
		print("Этап 11.3/ART: физическая локализация, спираль и пылевой баланс — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.3/ART: ", reason)
	quit(1)


func _initialize() -> void:
	# Инициализация сцены требуется для создания GPU-эмиттеров.
	call_deferred("_run")
