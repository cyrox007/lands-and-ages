extends RefCounted
## Числовые производственные контракты: сырьё, продукты и потребители.
## Технология определяет допуск, а не создаёт материалы или работников.

const RECIPES := {
    "обжиг кирпича": {
        "tier": 0, "inputs": {"глина": 3, "древесина": 3},
        "outputs": {"обожжённый кирпич": 3}
    },
    "тесать камень": {
        "tier": 0, "inputs": {"камень": 2},
        "outputs": {"каменные блоки": 2}
    },
    "дорожная подсыпка": {
        "tier": 0, "inputs": {"щебень": 2, "песок": 1},
        "outputs": {"дорожное покрытие": 3}
    },
    "связующий раствор": {
        "tier": 0, "inputs": {"глина": 1, "песок": 2},
        "outputs": {"строительный раствор": 2}
    },
    "выжиг древесного угля": {
        "tier": 1, "inputs": {"древесина": 3},
        "outputs": {"древесный уголь": 2}
    },
    "плавка железа": {
        "tier": 1, "inputs": {"железная руда": 3, "древесный уголь": 2},
        "outputs": {"железо": 2}
    },
    "плавка меди": {
        "tier": 1, "inputs": {"медная руда": 3, "древесный уголь": 2},
        "outputs": {"медь": 2}
    },
    "плавка олова": {
        "tier": 1, "inputs": {"оловянная руда": 3, "древесный уголь": 2},
        "outputs": {"олово": 2}
    },
    "бронзовый сплав": {
        "tier": 2, "inputs": {"медь": 2, "олово": 1},
        "outputs": {"бронза": 3}
    },
    "железные инструменты": {
        "tier": 2, "inputs": {"железо": 2, "древесина": 1},
        "outputs": {"железные инструменты": 1}
    },
    "медные изделия": {
        "tier": 1, "inputs": {"медь": 2},
        "outputs": {"медные изделия": 2}
    },
    "бронзовые инструменты": {
        "tier": 2, "inputs": {"бронза": 2, "древесина": 1},
        "outputs": {"бронзовые инструменты": 1}
    }
}

const CONSUMERS := {
    "кирпичная мастерская": {
        "tier": 0, "inputs": {"обожжённый кирпич": 3}
    },
    "каменный фундамент": {
        "tier": 0, "inputs": {"каменные блоки": 2, "строительный раствор": 2}
    },
    "участок дороги": {
        "tier": 0, "inputs": {"дорожное покрытие": 3}
    },
    "кузница инструментов": {
        "tier": 2, "inputs": {"каменные блоки": 2, "железные инструменты": 1}
    },
    "медная мастерская": {
        "tier": 1, "inputs": {"медные изделия": 2}
    },
    "бронзовая мастерская": {
        "tier": 2, "inputs": {"бронзовые инструменты": 1}
    }
}

const RAW_MATERIALS := [
    "древесина", "камень", "щебень", "песок", "глина",
    "железная руда", "медная руда", "оловянная руда", "каменный уголь"
]


static func materials() -> Dictionary:
    # Допустимые складские товары выводятся только из источников и
    # рецептов, чтобы ошибки в названиях обнаруживались тестами.
    var known := {}
    for kind in RAW_MATERIALS:
        known[kind] = true
    for recipe in RECIPES.values():
        for material in recipe["outputs"]:
            known[material] = true
    return known


static func validate() -> bool:
    # Все продукты обязаны иметь реальный источник и хотя бы одного
    # конечного потребителя, а каждый шаг — положительный расход.
    var available := {}
    for raw in RAW_MATERIALS:
        available[raw] = true
    for count in range(RECIPES.size()):
        var changed := false
        for recipe in RECIPES.values():
            var ingredients: Dictionary = recipe["inputs"]
            if ingredients.is_empty() or recipe["outputs"].is_empty():
                return false
            var can_make := true
            for material in ingredients:
                if int(ingredients[material]) <= 0:
                    return false
                if not available.has(material):
                    can_make = false
            for material in recipe["outputs"]:
                if int(recipe["outputs"][material]) <= 0:
                    return false
                if can_make and not available.has(material):
                    available[material] = true
                    changed = true
        if not changed:
            break
    for recipe in RECIPES.values():
        for material in recipe["inputs"]:
            if not available.has(material):
                return false
        for material in recipe["outputs"]:
            if not available.has(material):
                return false
    for consumer in CONSUMERS.values():
        for material in consumer["inputs"]:
            if int(consumer["inputs"][material]) <= 0 or not available.has(material):
                return false
    return true


static func required_technology(recipe_id: String) -> int:
    # Один реестр определяет допуски для UI и физических списаний.
    var rule: Dictionary = RECIPES.get(recipe_id, {})
    return int(rule.get("tier", -1))
