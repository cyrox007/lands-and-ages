extends SceneTree
## Детерминированная проверка первого контракта природных источников.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Resources = preload("res://scripts/natural_resource_registry.gd")

func _initialize() -> void:
    # Ошибки отражаются кодом возврата CI, а не только текстом журнала.
    var result := _check()
    print("STAGE12-RESOURCES: успешно" if result else "STAGE12-RESOURCES: ошибка")
    quit(0 if result else 1)

func _check() -> bool:
    # Два независимых реестра должны создавать идентичный снимок.
    var world = Map.new(Config.new())
    var first = Resources.new(world)
    var second = Resources.new(world)
    var cell := Vector2i(7, 11)
    for registry in [first, second]:
        if not registry.add_source("порода", "гранит", cell, 120, 750):
            return false
        if registry.add_source("порода", "гранит", cell, 120, 750):
            return false
        if registry.add_source("древесина", "бревно", cell, 10, 500):
            return false
    if first.to_data() != second.to_data():
        return false
    var id := Resources.source_id("порода", cell)
    if first.extract(id, 50) != 50 or first.extract(id, 1000) != 70:
        return false
    if first.extract(id, 1) != 0:
        return false
    var saved: Dictionary = first.to_data()
    var restored = Resources.new(world)
    if not restored.load_data(saved):
        return false
    if restored.to_data() != saved:
        return false
    # Повреждённый снимок не должен стирать уже загруженные источники.
    var bad: Dictionary = saved.duplicate(true)
    bad["sources"][0]["remaining_units"] = -1
    if restored.load_data(bad) or restored.to_data() != saved:
        return false
    var copy: Dictionary = restored.source_at("порода", cell)
    copy["remaining_units"] = 999
    return int(restored.source_at("порода", cell)["remaining_units"]) == 0
