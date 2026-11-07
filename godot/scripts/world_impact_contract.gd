extends RefCounted
## Контракт подтверждённого мощного физического воздействия.
## Визуальные события, координаты камеры и неподтверждённые намерения
## не могут создать геологическое повреждение или дополнительный ресурс.

const MAX_CHANGED_VERTICES := 65000
const NATURAL_KINDS := ["обвал", "оползень", "землетрясение"]
const SUPPORTED_KINDS := [
	"обвал", "оползень", "землетрясение",
	"кратер", "поднятие", "просадка"
]


static func confirmed(event: Dictionary) -> Dictionary:
	# Принимаем только конечный результат физического изменения,
	# а не запрос на эффект. Отдельные лес, грунт и WorldMap
	# используют общий набор координат и интенсивности.
	var kind: Variant = event.get("kind")
	var cell: Variant = event.get("cell")
	var vertices: Variant = event.get("vertices")
	var severity: Variant = event.get("severity")
	if not (kind is String) or not SUPPORTED_KINDS.has(kind):
		return {}
	if not (cell is Vector2i):
		return {}
	if not (vertices is int or vertices is float) \
			or not is_finite(float(vertices)) \
			or float(vertices) != float(int(vertices)) \
			or int(vertices) <= 0 or int(vertices) > MAX_CHANGED_VERTICES:
		return {}
	if not (severity is int or severity is float) \
			or not is_finite(float(severity)) \
			or float(severity) <= 0.0 or float(severity) > 1.0:
		return {}

	# Только реальная геология способна потребовать физическую
	# зону повреждений; произвольный эффект не может расширить
	# радиус или передать новый тип катастрофы.
	var radius := 7.0 if kind == "землетрясение" else (
		6.0 if kind == "оползень" else 5.0)
	return {
		"kind": kind,
		"cell": cell,
		"vertices": int(vertices),
		"severity": float(severity),
		"radius": radius
	}


static func natural_deformation(event: Dictionary) -> Dictionary:
	# Дневной Runner регистрирует только природные события
	# NaturalDisasters/NaturalProcesses. Ручные кратеры и подъёмы
	# уже имеют собственный проверенный путь LandscapeEvents.
	var impact: Dictionary = confirmed(event)
	if impact.is_empty() or not NATURAL_KINDS.has(impact["kind"]):
		return {}
	return impact
