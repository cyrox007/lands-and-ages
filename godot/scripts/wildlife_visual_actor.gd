extends Node3D
## Один видимый зверь: реальный импортированный SkinnedMesh и Skeleton3D.
## Примитивы (BoxMesh, SphereMesh и т. п.) никогда не используются.

const PACKED_FPS := 24.0
const PACKED_ACTIONS := {
    "покой": [0, 29],
    "атака": [30, 59],
    "смерть": [60, 89],
    "ходьба": [90, 119]
}

var species := ""
var source_name := ""
var state := "покой"
var _player: AnimationPlayer
var _packed := false
var _master := ""
var _elapsed := 0.0
var _visual: Node3D


func configure(species_name: String, scene: PackedScene,
        source: String, target_height: float) -> bool:
    # Ресурс обязан быть готовой сценой настоящего анимированного
    # животного. Резервной геометрии «на случай отсутствия» нет.
    if scene == null or _visual != null:
        return false
    var source_node: Node = scene.instantiate()
    if not (source_node is Node3D):
        source_node.free()
        return false
    _visual = source_node
    species = species_name
    source_name = source
    add_child(_visual)
    var skeletons := _visual.find_children("*", "Skeleton3D", true, false)
    var players := _visual.find_children("*", "AnimationPlayer", true, false)
    var meshes := _visual.find_children("*", "MeshInstance3D", true, false)
    if skeletons.is_empty() or players.is_empty() or meshes.is_empty():
        _visual.queue_free()
        _visual = null
        return false
    _player = players[0] as AnimationPlayer
    if _player.get_animation_list().is_empty():
        _visual.queue_free()
        _visual = null
        return false
    # Высота настоящего меша определяет масштаб конкретного вида,
    # чтобы корова не оказалась меньше зайца при общем масштабе.
    var lowest := INF
    var highest := -INF
    for candidate in meshes:
        var mesh_node := candidate as MeshInstance3D
        if mesh_node.mesh == null:
            continue
        var box: AABB = mesh_node.mesh.get_aabb()
        # Вычисляем локальную цепочку костей и мешей без
        # global_transform: актёр может ещё не быть в SceneTree.
        var local_to_root := Transform3D.IDENTITY
        var cursor: Node3D = mesh_node
        while cursor != null and cursor != _visual:
            local_to_root = cursor.transform * local_to_root
            cursor = cursor.get_parent() as Node3D
        for y in [box.position.y, box.end.y]:
            var height: float = (local_to_root * Vector3(
                box.get_center().x, y, box.get_center().z)).y
            lowest = minf(lowest, height)
            highest = maxf(highest, height)
    if is_finite(highest - lowest) and highest - lowest > 0.001:
        _visual.scale *= target_height / (highest - lowest)
    _packed = source == "Gobkit"
    _master = str(_player.get_animation_list()[0])
    _player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
    set_motion("покой")
    return true


func set_motion(next: String) -> void:
    # Для самостоятельных клипов Quaternius ищем анимацию по
    # смыслу, а Gobkit делим единую временную дорожку на диапазоны.
    if _player == null:
        return
    var action := next if next in ["покой", "ходьба", "атака", "смерть"] \
        else "покой"
    if state == action and _elapsed > 0.0:
        return
    state = action
    _elapsed = 0.0
    if _packed:
        _player.play(_master)
        _player.pause()
        return
    var target: Array = {"покой": ["idle"], "ходьба": ["walk", "gallop"],
        "атака": ["attack", "bite"], "смерть": ["death", "die"]}[action]
    var selection := ""
    for name in _player.get_animation_list():
        for word in target:
            if str(name).to_lower().contains(word):
                selection = str(name)
                break
        if not selection.is_empty():
            break
    _player.play(selection if not selection.is_empty() else _master)


func _process(delta: float) -> void:
    # При проигрывании упакованных клипов обновляем только
    # видимый скелет. Логика питания и размножения здесь не живёт.
    if not _packed or _player == null or not is_visible_in_tree():
        return
    var frames: Array = PACKED_ACTIONS[state]
    var start: float = float(frames[0]) / PACKED_FPS
    var length: float = float(frames[1] - frames[0] + 1) / PACKED_FPS
    _elapsed = fmod(_elapsed + delta, length)
    _player.seek(start + _elapsed, true)


func bone_count() -> int:
    # Приёмка проверяет настоящую структуру скелета,
    # а не наличие узла с убедительным названием.
    if _visual == null:
        return 0
    var skeletons := _visual.find_children("*", "Skeleton3D", true, false)
    return int((skeletons[0] as Skeleton3D).get_bone_count()) \
        if not skeletons.is_empty() else 0


func animation_count() -> int:
    # Не считаем статичную модель «анимированной».
    return _player.get_animation_list().size() if _player != null else 0
