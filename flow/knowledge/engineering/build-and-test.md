# Сборка, тесты, запуск

## Команды

| Команда | Что делает |
|---|---|
| `make build` | сборка Debug в `DerivedData/` проекта; на экран — ошибки, предупреждения и итог, полный лог — `DerivedData/Logs/make-build.log` |
| `make test` | все тесты; на экран — ошибки, упавшие тесты, итог и «Тестов прошло: N из N» из `.xcresult`; полный лог — `DerivedData/Logs/make-test.log`, результат — `DerivedData/Logs/make-test.xcresult` |
| `make run` | сборка и запуск `Trash.app`. Приложение сразу сканирует реальный диск — только чтение. «Очистить» не нажимать: root-rule п.2 |
| `make clean` | удаление `DerivedData/` проекта |
| `make flow-check` | полный прогон линтеров flow: ссылки, глоссарий, размеры |
| `make flow-test` | тесты скриптов flow и команд хуков |

Голый `xcodebuild` с `build` / `test` / `clean` / `archive` блокирует guard-хук. Интроспекция — `-list`, `-showBuildSettings` — разрешена.

## Проект

- Xcode-проект `Trash.xcodeproj`, формат objectVersion 77 с синхронизируемыми папками `Trash/` и `TrashTests/`: файл внутри них попадает в сборку автоматически, регистрировать его в `project.pbxproj` не нужно. Файл вне этих папок в сборку не попадёт.
- Схема `Trash` — shared, лежит в `Trash.xcodeproj/xcshareddata/xcschemes/`. Тест-таргет `TrashTests` — hosted: `TEST_HOST` = `Trash.app`.
- Подпись — Automatic, команда `JN2VY57Y6Q`, bundle id `yaroslav.trash`.
- App Sandbox выключен (`ENABLE_APP_SANDBOX = NO`) — иначе нет доступа к `~/Library`. Hardened Runtime включён.
- Deployment target — macOS 14.0; `SWIFT_VERSION = 6.0`.
- `DerivedData/` проекта в `.gitignore`. Xcode из GUI собирает в свой DerivedData — это нормально, сборки не мешают друг другу.

## Тесты

- Тесты запускаются внутри приложения (hosted). Автоскан при запуске под тестами отключён — `ContentView.isRunningTests`.
- Swift Testing; тесты параллельны — каждый файловый тест работает в собственной временной папке.
- Тесты удаления — только во временной папке, никогда на реальном `~`.
