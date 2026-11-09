# Анимированные 3D-модели животных (CC0)

В этом каталоге **не создаются кубы вместо животных**. Настоящие
скелетные модели GLTF/GLB устанавливаются командой:

```bash
python3 tools/install_fauna_assets.py
```

Модели авторов Quaternius и Gobkit лицензированы CC0 1.0. Перед
передачей в игру сохраняются файл, первоисточник, версия, SHA-256,
число костей и число анимаций в `asset_provenance.json`.

Источники:
- [Quaternius Ultimate Animated Animals (CC0)](https://quaternius.com/packs/ultimateanimatedanimals.html)
- [Gobkit Free Animal Pack Vol.2 (CC0)](https://gobkit.itch.io/gobkit-free-animal-pack-vol-2)
- [Зеркало файлов Quaternius](https://github.com/agentkaerf/FreeModels/tree/main/Ultimate%20Animated%20Animals%20-%20July%202021)

**Важно:** пока это стилизованные проверяемые 3D-ассеты, а не
утверждённое финальное художественное качество всей фауны. Без файлов
игра не подменяет животных кубами: их визуальный экземпляр не
создаётся. Нельзя закрывать 12.9, пока не утверждены все виды,
анимации, звук, реальная сцена охоты и кадры из Godot.

В экспорт Godot готовые бинарные файлы необходимо включать после
установки ассетов. Выпуск без них не считается графически полным.
