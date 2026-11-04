extends SceneTree
## Количественный отчёт о демонстрационной карте, а не генератор государств.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Capacity = preload("res://scripts/world_capacity_audit.gd")
const REPORT_PATH := "res://tests/world-capacity-10.json"


func _run() -> void:
    var map := Map.new(Config.new())
    var hydro := Hydro.new(map)
    hydro.rebuild()
    var surface := Surface.new(map, hydro)
    surface.rebuild()
    var climate := Climate.new(map, hydro)
    climate.rebuild()
    climate.set_day(1)
    surface.advance_climate_day(climate)
    hydro.apply_rainfall_map(surface.runoff_map())
    var nature := Nature.new(map, hydro, surface, climate)
    nature.generate()
    var cases := []
    for radius in [9, 12, 16, 20]:
        cases.append(Capacity.report(map, hydro, surface, nature, radius))
    var result := {
        "stage": "10.0", "seed": map.config.seed,
        "width": map.config.width, "height": map.config.height,
        "goal": {"players": 6, "mature_settlements": 30},
        "metric_scale_approved": false,
        "radii_approved": false,
        "cases": cases
    }
    var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
    if file == null:
        push_error("Не удалось записать отчёт о вместимости")
        quit(1)
        return
    file.store_string(JSON.stringify(result, "  "))
    file.close()
    print("Этап 10.0: отчёт готов — ", REPORT_PATH)
    quit(0)


func _initialize() -> void:
    call_deferred("_run")
