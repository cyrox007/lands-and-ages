extends "res://scripts/hydrology.gd"
## Эталон очереди Priority-Flood до оптимизации.
## Используется только в регрессионном тесте: порядок
## извлечения и разрешение равных высот должны совпадать
## с игровым алгоритмом на каждой клетке.


func _push(index: int) -> void:
	# Старый двоичный min-heap: сравнение через _precedes
	# выполняется заново на каждом уровне подъёма узла.
	_heap.append(index)
	var pos := _heap.size() - 1
	while pos > 0:
		var parent := int(float(pos - 1) / 2.0)
		if not _precedes(index, _heap[parent]):
			break
		_heap[pos] = _heap[parent]
		pos = parent
	_heap[pos] = index


func _pop() -> int:
	# При равной высоте раньше берётся меньший индекс клетки.
	# Для теста оставляем первоначальную реализацию без изменений.
	var first := _heap[0]
	var last: int = _heap.pop_back()
	if _heap.is_empty():
		return first
	var pos := 0
	var count := _heap.size()
	while 2 * pos + 1 < count:
		var child := 2 * pos + 1
		if child + 1 < count and _precedes(_heap[child + 1], _heap[child]):
			child += 1
		if not _precedes(_heap[child], last):
			break
		_heap[pos] = _heap[child]
		pos = child
	_heap[pos] = last
	return first
