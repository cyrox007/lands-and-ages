extends RefCounted
## Глубинная геология: геологические провинции существуют независимо от камеры.
## Порода и рудная специализация зависят от seed и пространственно связаны.

const Terrain = preload("res://scripts/terrain.gd")

const RULES := [
    {"kind": "железная руда", "material": "железная руда",
        "rocks": ["осадочная", "метаморфическая"], "threshold": 0.56},
    {"kind": "медная руда", "material": "медная руда",
        "rocks": ["магматическая", "метаморфическая"], "threshold": 0.62},
    {"kind": "оловянная руда", "material": "оловянная руда",
        "rocks": ["магматическая", "метаморфическая"], "threshold": 0.59},
    {"kind": "каменный уголь", "material": "каменный уголь",
        "rocks": ["осадочная"], "threshold": 0.60}
]


static func _field(cell: Vector2i, seed: int, salt: int,
        scale: int) -> float:
    # Соседние клетки интерполируются внутри одной геологической области,
    # поэтому рудная жила не превращается в независимые случайные точки.
    var gx := floori(float(cell.x) / float(scale))
    var gy := floori(float(cell.y) / float(scale))
    var u := smoothstep(0.0, 1.0, float(posmod(cell.x, scale)) / float(scale))
    var v := smoothstep(0.0, 1.0, float(posmod(cell.y, scale)) / float(scale))
    var a := lerpf(Terrain.hash2(gx, gy, seed + salt),
        Terrain.hash2(gx + 1, gy, seed + salt), u)
    var b := lerpf(Terrain.hash2(gx, gy + 1, seed + salt),
        Terrain.hash2(gx + 1, gy + 1, seed + salt), u)
    return lerpf(a, b, v)


static func _rock_class(cell: Vector2i, seed: int) -> String:
    # Провинции чередуют осадочные бассейны, магматические области
    # и метаморфические зоны; поверхность может быть покрыта наносами.
    var value := _field(cell, seed, 41091, 72)
    if value < 0.38:
        return "осадочная"
    if value < 0.72:
        return "метаморфическая"
    return "магматическая"


static func prospect(world: RefCounted, surface: RefCounted,
        cell: Vector2i, rule: Dictionary) -> Dictionary:
    # Разведка не создаёт месторождение: только оценивает природные
    # параметры конкретной клетки и возвращает доступность залежи.
    if not world.config.contains_cell(cell):
        return {}
    var seed: int = world.config.world_seed
    var base: Dictionary = surface.profile_at(cell)
    if base.is_empty():
        return {}
    var rock := _rock_class(cell, seed)
    if rock not in rule["rocks"]:
        return {}
    var soil: String = base["substrate"]
    var depth: float = float(base["depth"])
    if str(rule["kind"]) == "каменный уголь":
        # Угольные пласты характерны для осадочных бассейнов,
        # а не для искусственно выбранной открытой гранитной скалы.
        if soil not in ["глина", "суглинок", "песок"] or depth < 0.10:
            return {}
    elif str(rule["kind"]) == "оловянная руда":
        # Оловянная минерализация возможна также в контактных
        # метаморфических зонах, но требует выхода плотных пород.
        if soil not in ["скала", "щебень"] or depth > 0.45:
            return {}
    elif depth > 0.85:
        return {}

    var kind: String = rule["kind"]
    var salt := 52100 + kind.hash()
    var regional := _field(cell, seed, salt, 46)
    var local := _field(cell, seed, salt + 709, 13)
    var grade := regional * 0.77 + local * 0.23
    # Нет порога — нет залежи, даже если региону не хватает сырья.
    if grade < float(rule["threshold"]):
        return {}
    var quality := clampi(roundi(360.0 + grade * 550.0), 1, 1000)
    var units := maxi(20, roundi(35.0 + grade * 155.0))
    return {
        "kind": kind, "material": str(rule["material"]), "bedrock": rock,
        "grade": snappedf(grade, 0.000001),
        "quality": quality, "units": units
    }
