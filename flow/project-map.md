# Карта проекта

Вспомогательная карта — когда глоссария недостаточно или задача задевает несколько слоёв.

## Слои

| Слой | Папка | Что там | Модуль |
|---|---|---|---|
| Точка входа | `Trash/App/` | `@main` App, окно | `main-window` |
| Модели | `Trash/Models/` | категории, результаты скана, отчёт очистки | `scanning`, `cleanup` |
| Сервисы | `Trash/Services/` | сканер, удаление, защита от удаления лишнего | `scanning`, `cleanup` |
| Состояние UI | `Trash/ViewModels/` | `CleanupViewModel` | `main-window` |
| Вью | `Trash/Views/` | окно, боковая панель, список, нижняя панель | `main-window` |
| Ресурсы | `Trash/Assets.xcassets` | иконка, акцентный цвет | — |
| Тесты | `TrashTests/` | Swift Testing | по теме теста |
| Сборка | `Makefile`, `Trash.xcodeproj` | команды `make`, настройки проекта | `engineering/build-and-test.md` |

## Потоки

- **Скан:** `ContentView` `.task` → `CleanupViewModel.scan()` → `TaskGroup` → `CleanupScanner.scan(_:)` на каждую категорию → `results`.
- **Очистка:** `CleanupBar` → диалог подтверждения → `CleanupViewModel.cleanSelected(permanently:)` → `Cleaner.clean` → `SafetyGuard.canDelete` → `FileManager` → `CleanupReport` → алерт.

## Правило слоёв

- Вью не сканируют и не удаляют и не вызывают сервисы напрямую — только через view model. Допустимы вызовы `NSWorkspace`: иконка файла, «Показать в Finder», открытие настроек.
- Сканер только читает. Удаляет только `Cleaner`, и только после `SafetyGuard`.
