extends RefCounted
## Расстановка естественных строительных ресурсов поверх физической геологии.
## Равномерные квоты применяются лишь среди геологически допустимых участков.

const Terrain = preload("res://scripts/terrain.gd")
const STEP := 4
const MIN_DISTANCE_SQUARED := 36

const MATERIALS := [
    {"kind": "камень", "material": "строительный камень", "quota": 3},
    {"kind": "щебень", "material": "щебень", "quota": 2},
    {"kind": "песок", "material": "песок", "quota": 2},
    {"kind": "глина", "material": "глина", "quota": 2}
]

static func _suitability(kind: String, substrate: String,
        depth: float, slope: float, wet: float) -> float:
    # Камень связан с выходами коренной породы и обломочным материалом.
    # Глину и песок не создаём на чистом скальном выходе.
    match kind:
        "камень":
            if substrate not in ["скала", "щебень"]:
                return -1.0
            return 1.0 - slope * 0.30
        "щебень":
            if substrate not in ["щебень", "скала"]:
                return -1.0
            return 0.9 - slope * 0.35
        "песок":
            if substrate != "песок" or depth < 0.05:
                return -1.0
            return 0.8 - wet * 0.20
        "глина":
            if substrate != "глина" or depth < 0.05:
                return -1.0
            return 0.8 + wet * 0.10
    return -1.0

static func _pick(candidates: Array, count: int) -> Array:
    # Сначала выбираем наиболее пригодные места, затем выдерживаем
    # дистанцию, чтобы не превращать залежи в ряд соседних квадратов.
    candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        if a["score"] == b["score"]:
            return int(a["id"]) < int(b["id"])
        return float(a["score"]) > float(b["score"])
    )
    var chosen: Array = []
    for item in candidates:
        var cell: Vector2i = item["cell"]
        var separated := true
        for previous in chosen:
            var delta: Vector2i = cell - previous["cell"]
            if delta.length_squared() < MIN_DISTANCE_SQUARED:
                separated = false
                break
        if separated:
            chosen.append(item)
        if chosen.size() >= count:
            break
    return chosen

static func populate(world: RefCounted, hydro: RefCounted,
        surface: RefCounted, registry: RefCounted) -> Dictionary:
    # Детерминированный полный обход: результат не зависит от камеры,
    # порядка загрузки чанков и частоты кадров.
    hydro.ensure_ready()
    surface.ensure_ready()
    var regions := {}
    var seed: int = world.config.world_seed
    for y in range(2, world.config.height - 1, STEP):
        for x in range(2, world.config.width - 1, STEP):
            var cell := Vector2i(x, y)
            var index: int = y * world.config.width + x
            if hydro.has_water(index):
                continue
            var profile: Dictionary = surface.profile_at(cell)
            if profile.is_empty() or bool(profile.get("wetland", false)):
                continue
            var slope := 1.0 - world.normal_at(cell).y
            if slope > 0.48:
                continue
            var region: Vector2i = world.config.region_of(cell)
            if not regions.has(region):
                regions[region] = {}
            for rule in MATERIALS:
                var kind: String = rule["kind"]
                var suitability := _suitability(kind,
                    str(profile["substrate"]), float(profile["depth"]),
                    slope, float(profile["moisture"]))
                if suitability < 0.0:
                    continue
                var noise := Terrain.hash2(x, y, seed + 12000 + kind.hash())
                var candidate := {
                    "cell": cell, "id": index,
                    "score": suitability + noise * 0.30,
                    "quantity": 80 + roundi(noise * 180.0),
                    "quality": 400 + roundi(noise * 500.0)
                }
                if not regions[region].has(kind):
                    regions[region][kind] = []
                regions[region][kind].append(candidate)

    var totals := {}
    var missing := {}
    # Квоты обеспечивают базовое сырьё, если регион действительно
    # содержит подходящие залежи. Нет ресурса — фиксируем дефицит,
    # а не подменяем рельеф искусственным месторождением.
    var keys := regions.keys()
    keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.y < b.y or (a.y == b.y and a.x < b.x)
    )
    for region in keys:
        for rule in MATERIALS:
            var kind: String = rule["kind"]
            var choices: Array = _pick(regions[region].get(kind, []),
                int(rule["quota"]))
            if choices.is_empty():
                if not missing.has(kind):
                    missing[kind] = 0
                missing[kind] += 1
            for item in choices:
                if registry.add_source(kind, str(rule["material"]),
                        item["cell"], int(item["quantity"]),
                        int(item["quality"])):
                    totals[kind] = int(totals.get(kind, 0)) + 1
    return {"sources": totals, "missing_regions": missing,
        "sampled_regions": keys.size()}
