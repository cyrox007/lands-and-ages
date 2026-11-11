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
var _contact_player: AudioStreamPlayer3D
var contact_sound_plays := 0


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
    # Наличие отдельного Skeleton3D рядом со статичным мешем
    # не является доказательством настоящей скелетной модели.
    var skinned := false
    for candidate in meshes:
        var mesh_node := candidate as MeshInstance3D
        if mesh_node.skin != null or not mesh_node.skeleton.is_empty():
            skinned = true
            break
    if not skinned:
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
    # Старый FBX-конвертер Gobkit сохраняет меш в сантиметрах
    # с масштабом узла 100. В Godot его Skin после импортирования
    # дополнительно усиливает перемещения костей; ограничиваем
    # визуальный масштаб, не вмешиваясь в настоящий Skeleton3D.
    if source == "Gobkit":
        _visual.scale *= 0.013
    # Длинный единый клип допускает нарезку на действия.
    # Отдельные idle/walk/attack/death нельзя перематывать
    # по временным отрезкам от другой анимации.
    _master = str(_player.get_animation_list()[0])
    var clips: PackedStringArray = _player.get_animation_list()
    var master_animation: Animation = _player.get_animation(_master)
    _packed = clips.size() == 1 and master_animation != null \
        and master_animation.length >= 4.9
    _player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
    set_motion("покой")
    return true


func set_motion(next: String) -> void:
    # Для самостоятельных клипов Quaternius ищем анимацию по
    # смыслу, а Gobkit делим единую временную дорожку на диапазоны.
    if _player == null:
        return
    # Бег — ускоренная реальная скелетная локомоция. Если
    # отдельного run/gallop нет, используем настоящий walk,
    # а не придумываем анимацию или двигаем статичный куб.
    var action := next if next in ["покой", "ходьба", "бег",
        "атака", "смерть"] else "покой"
    if state == action and _elapsed > 0.0:
        return
    state = action
    _elapsed = 0.0
    if _packed:
        _player.play(_master)
        _player.pause()
        return
    var target: Array = {"покой": ["idle"], "ходьба": ["walk", "gallop"],
        "бег": ["run", "gallop", "sprint", "walk"],
        "атака": ["attack", "bite"], "смерть": ["death", "dead", "die"]}[action]
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
    # Отдельные импортированные клипы тоже обрабатываются
    # в ручном режиме: без advance() была бы статичная поза,
    # несмотря на успешный импорт и вызов play().
    if _player == null or not is_visible_in_tree():
        return
    if not _packed:
        _player.advance(delta)
        return
    # Упакованный единый клип выбирает свой реальный диапазон
    # ключевых кадров, не проигрывая все действия подряд.
    # У упакованных моделей отдельной дорожки бега нет:
    # повторяем только диапазон настоящей ходьбы.
    var clip := "ходьба" if state == "бег" else state
    var frames: Array = PACKED_ACTIONS[clip]
    var start: float = float(frames[0]) / PACKED_FPS
    var length: float = float(frames[1] - frames[0] + 1) / PACKED_FPS
    _elapsed = fmod(_elapsed + delta, length)
    _player.seek(start + _elapsed, true)


func has_attack_animation() -> bool:
    # Показываем атаку только при наличии настоящего клипа.
    # Обычный idle-файл не может выдавать себя за охоту.
    if _player == null:
        return false
    if _packed:
        return true
    for name in _player.get_animation_list():
        var title := str(name).to_lower()
        if title.contains("attack") or title.contains("bite"):
            return true
    return false


func attack_duration() -> float:
    # Упакованный Gobkit проигрывает только диапазон реальных
    # кадров атаки, отдельные GLTF — собственный исходный клип.
    if not has_attack_animation():
        return 0.0
    if _packed:
        var frames: Array = PACKED_ACTIONS["атака"]
        return float(frames[1] - frames[0] + 1) / PACKED_FPS
    for name in _player.get_animation_list():
        var label := str(name).to_lower()
        if label.contains("attack") or label.contains("bite"):
            var animation: Animation = _player.get_animation(str(name))
            if animation != null and is_finite(animation.length):
                return maxf(0.1, animation.length)
    return 0.0


static func _contact_audio() -> AudioStreamWAV:
    # Короткий приглушённый шум соприкосновения создаём один раз
    # для видимого актёра. Не выдаём его за голос какого-либо
    # животного и не используем внешние файлы без лицензии.
    var clip := AudioStreamWAV.new()
    clip.format = AudioStreamWAV.FORMAT_16_BITS
    clip.mix_rate = 16000
    clip.stereo = false
    var frames := 2400
    var samples := PackedByteArray()
    samples.resize(frames * 2)
    var filtered_noise := 0.0
    for i in range(frames):
        # Затухание убирает резкий щелчок на конце, а низкий тон
        # и фильтрованный шорох дают короткий негромкий контакт.
        var time := float(i) / float(clip.mix_rate)
        var progress := float(i) / float(frames)
        var envelope := pow(1.0 - progress, 3.0)
        var noise_value := sin(float(i) * 12.9898 + 31.4) * 43758.5453
        var random_value := (noise_value - floorf(noise_value)) * 2.0 - 1.0
        filtered_noise = lerpf(filtered_noise, random_value, 0.12)
        var low := sin(TAU * (110.0 * time - 70.0 * time * time))
        var sample := clampi(roundi((0.50 * low + 0.24 * filtered_noise)
            * envelope * 11000.0), -32768, 32767)
        # AudioStreamWAV хранит PCM16 little-endian: сначала
        # младший байт, затем старший, без преобразования в текст.
        samples[i * 2] = sample & 255
        samples[i * 2 + 1] = (sample >> 8) & 255
    clip.data = samples
    return clip


func play_contact_sound() -> bool:
    # Источник 3D находится на самом хищнике, не в центре камеры.
    # Без SceneTree не запускаем звук. Генерация выполняется лишь
    # при первом подтверждённом визуальном контакте.
    if not is_inside_tree():
        return false
    if _contact_player == null:
        _contact_player = AudioStreamPlayer3D.new()
        _contact_player.name = "ContactSound"
        _contact_player.volume_db = -18.0
        _contact_player.max_distance = 24.0
        _contact_player.stream = _contact_audio()
        add_child(_contact_player)
    _contact_player.play()
    contact_sound_plays += 1
    return true


func motion_time() -> float:
    # Тест приёмки читает фактический ход клипа, а не надпись
    # состояния «ходьба», которая может не двигать ни одну кость.
    return _player.current_animation_position if _player != null else 0.0


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
