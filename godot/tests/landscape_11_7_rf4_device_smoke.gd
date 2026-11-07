extends SceneTree
## 11.7/RF4: проверка маршрута аппаратного профилирования в живой сцене.
## Программный GL проверяет контракт JSON, но не заменяет ПК/Android.

const View = preload("res://scripts/world.gd")
const Runner = preload("res://scripts/world_benchmark_runner.gd")
var failures: Array[String] = []


func _check(ok: bool, message: String) -> void:
	# Сохраняем ошибки каждой фазы для диагностики CI, не скрывая
	# неудачную деформацию за последующим удачным событием.
	if not ok:
		failures.append(message)


func _initialize() -> void:
	# Сцена должна успеть создать реальные чанки и физические
	# подсистемы до первого измеряемого воздействия.
	call_deferred("_run")


func _run() -> void:
	var view := View.new()
	root.add_child(view)
	for frame in range(240):
		await process_frame
		if view._day_runner != null and not view._active.is_empty():
			break
	_check(view._day_runner != null, "Физическая сцена загружена")
	if view._day_runner != null:
		var report: Dictionary = await Runner.new().run_landscape(view)
		_check(report.get("stage") == "11.7/RF4",
			"Версия маршрута соответствует RF4")
		_check(report.get("headless") == true,
			"Headless не выдаётся за аппаратный рендер")
		var events: Array = report.get("events", [])
		_check(events.size() == 3, "Три геологических события")
		var revisions := 0
		for event in events:
			if event.get("applied", false):
				revisions += 1
				_check(int(event.get("vertices", 0)) > 0,
					"Физическое событие действительно изменило вершины")
				_check(float(event.get("sync_cpu_ms", -1)) >= 0.0,
					"Синхронизация измерена в миллисекундах")
				_check(float(event.get("frame_interval_p95_ms", -1)) >= 0.0,
					"Интервал кадра получен из игрового цикла")
				_check(not event.get("queue_timeout", true),
					"Очередь %s: pending=%d jobs=%d rebuild=%d nature=%d" % [
						event["kind"], int(event["remaining_pending"]),
						int(event["remaining_jobs"]), int(event["remaining_rebuilds"]),
						int(event["remaining_nature"])])
		_check(revisions == 3, "Все три деформации физически применились")
		_check(int(report.get("final_revision", 0))
			- int(report.get("initial_revision", 0)) == 3,
			"Ревизия WorldMap соответствует числу событий")
		_check(JSON.parse_string(JSON.stringify(report)) is Dictionary,
			"Отчёт корректно сериализуется для ПК и Android")
	view.queue_free()
	await process_frame
	if not failures.is_empty():
		for message in failures:
			push_error("11.7/RF4/DEVICE: " + message)
		quit(1)
		return
	print("11.7/RF4/DEVICE: маршрут геологии и JSON успешно проверены.")
	quit(0)
