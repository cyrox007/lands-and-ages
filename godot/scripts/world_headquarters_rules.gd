extends RefCounted
## Контракт трёхмерного центра поселения: строительство, уровни и повреждения.
## Состояния относятся к физической модели, а не к кадрам анимации.

const FOOTPRINT := Vector2i(2, 2)
const BUILD_DAYS := 8
const MAX_LEVEL := 4
const RADII := [9, 12, 16, 20]
const CONSUMERS := [
    "", "центр поселения I", "центр поселения II",
    "центр поселения III", "центр поселения IV"
]
const REPAIR := "восстановление центра"
const CONSTRUCTING := ["строительство", "улучшение", "восстановление"]
const RUINS := ["свежие руины", "старые руины", "заросшие руины"]
const STATES := [
    "строительство", "улучшение", "готово", "повреждено",
    "свежие руины", "старые руины", "заросшие руины", "восстановление"
]


static func initial(id: String, cell: Vector2i, day: int) -> Dictionary:
    # Новое здание оплачивается до создания записи. Ни один метод
    # графики не может вызвать начальное создание самостоятельно.
    return {
        "id": id + ":центр", "x": cell.x, "y": cell.y,
        "level": 1, "target_level": 1, "paid_level": 1,
        "state": "строительство", "progress": 0, "integrity": 100,
        "ruin_days": 0, "repairs": 0, "last_day": day
    }


static func footprint(cell: Vector2i) -> Array[Vector2i]:
    # Фундамент занимает четыре смежные клетки и сохраняет
    # неизменные координаты при улучшении и разрушении.
    return [cell, cell + Vector2i(1, 0), cell + Vector2i(0, 1),
        cell + Vector2i(1, 1)]


static func radius(state: Dictionary) -> int:
    # Уровень определяет территорию, но не меняет проходимость земли.
    # Профили расширения — рабочие значения до масштабной приёмки #103.
    return RADII[int(state.get("level", 1)) - 1] if not state.is_empty() else 9


static func visual_stage(state: Dictionary) -> String:
    # Вид не движется независимо от календаря: стадии зависят только
    # от оплаченной работы, сохранённой в физическом реестре.
    var phase := str(state.get("state", ""))
    if phase not in CONSTRUCTING:
        return phase
    var progress := int(state.get("progress", 0))
    if progress < 2:
        return "фундамент"
    if progress < 4:
        return "каркас"
    if progress < 6:
        return "стены"
    return "крыша"


static func advance(state: Dictionary, day: int) -> bool:
    # Обновление возможно только после нового физического дня.
    # Повторный вызов не ускоряет стройку и не создаёт материалы.
    if state.is_empty() or day <= int(state["last_day"]):
        return false
    var delta := day - int(state["last_day"])
    state["last_day"] = day
    var phase := str(state["state"])
    if phase in CONSTRUCTING:
        state["progress"] = mini(BUILD_DAYS, int(state["progress"]) + delta)
        if int(state["progress"]) >= BUILD_DAYS:
            if phase == "улучшение":
                state["level"] = int(state["target_level"])
            if phase == "восстановление":
                state["integrity"] = 100
            state["target_level"] = int(state["level"])
            state["state"] = "готово"
    elif phase in RUINS:
        state["ruin_days"] = mini(10000000,
            int(state["ruin_days"]) + delta)
        if int(state["ruin_days"]) >= 30:
            state["state"] = "заросшие руины"
        elif int(state["ruin_days"]) >= 4:
            state["state"] = "старые руины"
    return true


static func damage(state: Dictionary, amount: int) -> bool:
    # Повреждение не доступно во время стройки и не может восстановить
    # здание отрицательным уроном. При нулевой прочности остаётся участок.
    if state.is_empty() or amount <= 0 \
            or str(state["state"]) not in ["готово", "повреждено"]:
        return false
    state["integrity"] = maxi(0, int(state["integrity"]) - amount)
    if int(state["integrity"]) == 0:
        state["state"] = "свежие руины"
        state["ruin_days"] = 0
    else:
        state["state"] = "повреждено"
    return true


static func valid(state: Dictionary, parent_id: String,
        day: int, industry: RefCounted) -> bool:
    # Враждебный JSON проверяем целиком до применения. Значения,
    # изменения которых означали бы бесплатный уровень, сверяем
    # с реально оплаченной историей consumer в отраслевом реестре.
    var keys := [
        "id", "x", "y", "level", "target_level", "paid_level",
        "state", "progress", "integrity", "ruin_days", "repairs", "last_day"
    ]
    if state.size() != keys.size() or str(state.get("id", "")) \
            != parent_id + ":центр" or industry == null:
        return false
    for key in keys:
        if not state.has(key):
            return false
        if key in ["id", "state"]:
            continue
        var number: Variant = state[key]
        if not (number is int or number is float) \
                or not is_finite(float(number)) \
                or float(number) != float(int(number)):
            return false
    var level := int(state["level"])
    var target := int(state["target_level"])
    var paid := int(state["paid_level"])
    var progress := int(state["progress"])
    var integrity := int(state["integrity"])
    var ruin_days := int(state["ruin_days"])
    var repairs := int(state["repairs"])
    var phase := str(state["state"])
    if level < 1 or level > MAX_LEVEL or paid < level \
            or paid > MAX_LEVEL or target < level or target > paid \
            or progress < 0 or progress > BUILD_DAYS \
            or integrity < 0 or integrity > 100 \
            or ruin_days < 0 or ruin_days > 10000000 \
            or repairs < 0 or repairs > 10000 \
            or int(state["last_day"]) > day or int(state["last_day"]) < 0 \
            or phase not in STATES:
        return false
    if phase == "улучшение" and (target != level + 1 \
            or progress >= BUILD_DAYS or integrity != 100):
        return false
    if phase == "строительство" and (level != 1 or target != 1 \
            or progress >= BUILD_DAYS or integrity != 100):
        return false
    if phase == "восстановление" and (target != level \
            or progress >= BUILD_DAYS):
        return false
    if phase not in CONSTRUCTING and (target != level \
            or progress != BUILD_DAYS):
        return false
    if phase == "готово" and integrity != 100:
        return false
    if phase == "повреждено" and (integrity <= 0 or integrity >= 100):
        return false
    if phase in RUINS and integrity != 0:
        return false
    for tier in range(1, paid + 1):
        if int(industry.completed.get(CONSUMERS[tier], 0)) < 1:
            return false
    return int(industry.completed.get(REPAIR, 0)) >= repairs
