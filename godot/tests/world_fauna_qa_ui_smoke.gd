extends SceneTree
## Сквозная приёмка 12.9: настоящая кнопка в игровом мире,
## физическая охота, положение слушателя и отсутствие дублей.

const View = preload("res://scripts/world.gd")
const Save = preload("res://scripts/world_save.gd")


func _initialize() -> void:
    # Кнопки и мир создаются после запуска главного дерева.
    call_deferred("_run")


func _run() -> void:
    # Используем ту же сцену, что запускает игрок на ПК/Android.
    # Не подменяем животных пустыми тестовыми узлами.
    var view := View.new()
    get_root().add_child(view)
    await process_frame
    # При потоковой камере рабочая позиция может отличаться от
    # реально показанного кадра. Фауна обязана оставаться у
    # видимой камеры до завершения загрузки новых чанков.
    var actual_center: Vector2 = view._center
    var camera := Camera3D.new()
    view.add_child(camera)
    camera.size = 28.0
    view._display_camera = camera
    view._display_center = Vector2(25.5, 30.5)
    var shown: Dictionary = view._fauna_view_state()
    if shown["center"] != view._display_center \
            or absf(float(shown["size"]) - 28.0) > 0.001:
        push_error("Фауна выбрана по невидимой расчётной камере")
        view.queue_free()
        quit(1)
        return
    view._display_camera = null
    camera.queue_free()
    var direct: Dictionary = view._fauna_view_state()
    if direct["center"] != actual_center \
            or absf(float(direct["size"]) - view._camera.size) > 0.001:
        push_error("Обычная камера ошибочно подменена потоковой")
        view.queue_free()
        quit(1)
        return
    var focus := view.find_child("FaunaInspect", true, false) as Button
    var hunt := view.find_child("FaunaHuntQA", true, false) as Button
    if focus == null or hunt == null \
            or view._fauna_audio_listener == null:
        print("STAGE12-FAUNA-UI-DIAG: ", JSON.stringify({
            "focus": focus != null, "hunt": hunt != null,
            "listener": view._fauna_audio_listener != null,
            "world": view._world_model != null
        }))
        push_error("В игровом интерфейсе отсутствует приёмка фауны 12.9")
        view.queue_free()
        quit(1)
        return
    var before: Dictionary = Save.capture(view._storage_models())
    if before.is_empty():
        push_error("Перед осмотром не получена физическая модель WorldSave")
        view.queue_free()
        quit(1)
        return
    # Настоящая кнопка должна выбрать существующую пару,
    # сдвинуть камеру, но оставить физическое состояние прежним.
    focus.pressed.emit()
    var spot: Dictionary = view._wildlife_visuals.inspection_spot()
    var listener: AudioListener3D = view._fauna_audio_listener
    if spot.is_empty() or view._wildlife_visuals.active_count() == 0 \
            or Save.capture(view._storage_models()) != before \
            or listener.position.distance_to(
                view._world_model.config.to_scene(view._center,
                    view._world_model.height_at(view._center))) > 0.001:
        push_error("Осмотр не показал реальных животных или изменил WorldSave")
        view.queue_free()
        quit(1)
        return
    # Следующее нажатие запускает только настоящее списание
    # через FoodWeb. Ни камера, ни звук не создают добычу.
    var region: Vector2i = spot["region"]
    var prey_kind := str(spot["prey"])
    var count_before: int = view._wildlife.population_at(region, prey_kind)
    hunt.pressed.emit()
    var count_after: int = view._wildlife.population_at(region, prey_kind)
    if count_before - count_after != 1 \
            or view._fauna_qa_day != view._food_web.last_day:
        push_error("Приёмочная кнопка не завершила физический захват добычи")
        view.queue_free()
        quit(1)
        return
    # Дважды нажать в одни сутки можно, но второе действие
    # обязано быть отказом без дополнительного расхода особей.
    hunt.pressed.emit()
    if view._wildlife.population_at(region, prey_kind) != count_after:
        push_error("Повторная приёмка дважды списала живую добычу")
        view.queue_free()
        quit(1)
        return
    print("STAGE12-FAUNA-UI-REPORT: ", JSON.stringify({
        "actual_capture": true, "one_capture_per_day": true,
        "inspection_preserved_world": true,
        "audio_listener_near_ground": true,
        "fauna_follows_display_camera": true,
        "visible": view._wildlife_visuals.active_count(),
        "manual_hardware_acceptance": false
    }))
    print("STAGE12-FAUNA-UI: успешно")
    view.queue_free()
    await process_frame
    quit(0)
