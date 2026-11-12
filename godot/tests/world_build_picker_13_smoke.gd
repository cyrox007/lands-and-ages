extends SceneTree
## Проверка выбора клеток по лучу реального рельефа этапа 13.4.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Picker = preload("res://scripts/world_build_picker.gd")


func _initialize() -> void:
    # CI получает ненулевой статус, если экранная координата
    # не соответствует физической клетке карты.
    var ok := _verify()
    print("STAGE13-PLACEMENT: успешно" if ok else
        "STAGE13-PLACEMENT: ошибка")
    quit(0 if ok else 1)


func _verify() -> bool:
    # Вертикальный луч обязан попадать в ту же клетку независимо
    # от фактической высоты и процедурного seed мира.
    for seed in [1729, 1730, 1901]:
        var world = Map.new(Config.new(64, 64, seed))
        for cell in [Vector2i(3, 4), Vector2i(32, 32),
                Vector2i(62, 61)]:
            var origin := Vector3(cell.x + 0.5, 80.0, cell.y + 0.5)
            if Picker.ray_cell(world, origin, Vector3.DOWN) != cell:
                push_error("Неверная клетка карты для seed " + str(seed))
                return false
        # Нельзя строить за пределами мира или кликом в небо.
        if Picker.ray_cell(world, Vector3(-4.0, 80.0, 16.0),
                Vector3.DOWN) != Vector2i(-1, -1) \
                or Picker.ray_cell(world, Vector3(16.0, 80.0, 16.0),
                    Vector3.UP) != Vector2i(-1, -1):
            push_error("Луч разрешил постройку за миром или над горизонтом")
            return false
    return true
