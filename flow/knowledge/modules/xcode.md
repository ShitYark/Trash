# Xcode

Поиск мусора Xcode и инструментов разработки: рантаймы и симуляторы, DerivedData, Device Support, архивы, превью, кэши, логи, неактивные копии Xcode. Это разделы окна пункта «Xcode» боковой панели (`CategoryGroup.xcode`, `GroupOverviewView`).

Симуляторы и рантаймы удаляются **через `simctl`**: `simctl delete <udid>` и `simctl runtime delete <id>`, сразу и без Корзины; папка без симулятора — файлами, после свежего `simctl list`. Защита — `cleanup.md` → «Удаление через менеджер». Сами не отмечаются, явный мусор — с меткой «мусор». Копии Xcode с 2026-10-12 удаляются как программы — только в Корзину, правилом из `applications.md`.

## Точки входа

- `XcodeScanner` — поиск с подписями и рекомендациями для категорий с особой логикой.
- `SimulatorCatalog` — разбор JSON `simctl list devices -j` и `simctl runtime list -j`, читаемые имена рантаймов.
- `CommandRunner` — запуск `simctl` и `xcode-select` с таймаутом 30 с и завершением процесса при отмене: `.system` в приложении, заготовленные ответы в тестах.
- Сами категории, их корни и способ поиска (`scanMethod`) — в `CleanupCategory`, модуль `scanning.md`.

## Категории

| Категория | Источник | Подпись элемента | Отмечается сама | Удаляется |
|---|---|---|---|---|
| Рантаймы симуляторов | `simctl runtime list -j` | платформа и версия; сборка, сколько симуляторов используют, последний запуск | `deletable` и не нужен ни одному симулятору | `simctl runtime delete`; встроенный в систему (`deletable == false`) — нет |
| Симуляторы | `simctl list devices -j` + папки `CoreSimulator/Devices` | имя; версия системы, «запущен» / «недоступен» / последний запуск | недоступные и не запущенные; папки-сироты | выключенный — `simctl delete`; папка без симулятора — файлами |
| DerivedData | `Xcode/DerivedData` + `info.plist` | имя проекта; путь, «проекта больше нет» или «открывался …» | все | да |
| Device Support | `Xcode/<платформа> DeviceSupport`: iOS, watchOS, tvOS, visionOS, macOS | имя папки; платформа и версия, «самая свежая» | все, кроме самой свежей версии платформы | да |
| Архивы | `Xcode/Archives/<дата>/*.xcarchive` | имя приложения; версия, дата | нет | да |
| Превью SwiftUI | `Xcode/UserData/Previews` | — | все | да |
| Кэш документации | `Xcode/DocumentationCache` | — | все | да |
| Кэши пакетов | `Caches/org.swift.swiftpm`, `Caches/CocoaPods`, `Caches/org.carthage.CarthageKit` | менеджер пакетов | все | да |
| Кэши Xcode и симуляторов | `Caches/com.apple.dt.Xcode`, `CoreSimulator/Caches`, `Developer/XCTestDevices` | чей кэш | все | да |
| Логи Xcode | `Xcode/iOS Device Logs`, `Xcode/DeviceLogs`, `Logs/CoreSimulator` | логи устройств или журналы симуляторов | все | да |
| Products | `Xcode/Products` — кэш Organizer из App Store Connect: `Info.json`, краши, иконки по bundle id | — | нет | да |
| Старые версии Xcode | `.app` в `/Applications` с `com.apple.dt.Xcode` | имя; версия | нет | только в Корзину, как программа |
| Общие кэши симуляторов | `/Library/Developer/CoreSimulator/Caches/dyld/<сборка macOS>/<runtimeIdentifier>.<сборка>` + `simctl list runtimes -j` | рантайм; сборка, «создастся заново» или «не поддерживается этой macOS» | нет; меткой «мусор» — кэш рантайма, который macOS не поддерживает | `simctl runtime dyld_shared_cache remove <runtimeIdentifier>/<сборка>`; без рантайма и старые сборки macOS — нет |

## Связанные модули

- `scanning.md` — категории, общий поиск по корням, исключение двойного счёта.
- `cleanup.md` — неудаляемые категории `Cleaner` отклоняет, `SafetyGuard` не включает их корни.
- `main-window.md` — окно Xcode с разделами, подписи, неактивные чекбоксы.

## Ключевые сценарии

- **Запуск `simctl`.** Только из активного Xcode: `xcode-select -p` → папка существует → `<папка>/usr/bin/simctl` существует → запуск напрямую, без `xcrun`. Иначе — пустая категория с причиной `noXcodeReason`: на Mac без инструментов разработчика заглушки `/usr/bin` предлагают их установить. `simctl` в Xcode 27 — bash-обёртка, сама выставляет `DEVELOPER_DIR` по своему пути.
- **Пустой список с причиной** (`CategoryScanResult.unavailableReason`) — не «Здесь чисто»: окно показывает «Нет данных» и причину.
- **Рантаймы.** Использование считается по `runtimeIdentifier` симуляторов из `simctl list devices`. Список симуляторов не получен — не отмечается ничего: без него «не нужен» — догадка. Размер — `sizeBytes` из `simctl`, не обход диска. Путь элемента — `mountPath`, у типа «Legacy Download» — `runtimeBundlePath`.
- **Симуляторы.** Элемент — папка `Devices/<udid>`, размер — обход папки. Папка с именем-UUID, которой нет в списке `simctl`, — сирота. `simctl` не ответил — категория пустая: без списка нельзя отличить сироту от симулятора.
- **DerivedData.** Имя проекта и путь — из `WorkspacePath` в `info.plist`; файла по пути нет — «проекта больше нет»: так находятся остатки удалённых проектов и worktree. Папки без `info.plist` (`ModuleCache.noindex` и т.п.) — «Общий кэш сборки Xcode».
- **Device Support.** Версия — первое число с точкой в имени папки: `iPhone14,3 18.5 (22F76)` → 18.5. Самая свежая версия в папке каждой платформы не отмечается; версию не разобрать — не отмечается. Правило общее — `VersionPolicy`, им же пользуется Терминал.
- **Архивы.** `Name`, `ApplicationProperties`, `CreationDate` из `Info.plist`; номер сборки показывается, только если отличается от версии.
- **Копии Xcode.** Активная — из `xcode-select -p`; её не показываем. Активную определить не удалось — не показываем ничего.
- **Категории из нескольких корней** подписывают элемент по корню — `CleanupCategory.rootLabel(forRootNamed:)`.

## Нюансы

- Список симуляторов запрашивается дважды за скан: его читают и «Симуляторы», и «Рантаймы».
- `CommandRunner.system` занимает поток пула на время работы команды — для `simctl list` это единицы секунд, максимум — таймаут 30 с.
- База логов устройств — тройка SQLite `.db` / `-shm` / `-wal`, это три отдельных элемента. Данные одноразовые, поэтому не объединяются.
- **Общие кэши симуляторов** — dyld-кэши рантаймов в `/Library`: папку читает сканер, удаляет `simctl`, корнем `/Library` не становится.
  - Сборка macOS — `kern.osversion` (`XcodeScanner.hostBuild`): `operatingSystemVersionString` локализована, слова «Build» в ней может не быть.
  - Кэши рабочих рантаймов CoreSimulator создаёт заново при следующем старте своей службы — место возвращается ненадолго, хотя «Освобождено» показывает полный размер; описание раздела это говорит. Для недоступных рантаймов (`isAvailable == false` в `simctl list runtimes -j`) кэш больше не собирается — это и помечено мусором, в подписи — причина словами `simctl` (`availabilityError`).
  - Удаление сверяет операцию с папкой элемента: `<runtimeIdentifier>.<сборка>`. Отказ «симулятор запущен» видит только основной набор симуляторов: клоны Previews и `XCTestDevices` в нём нет — без кэша они лишь запустятся медленнее.
  - Не проверено вживую: примет ли `simctl` удаление кэша недоступного рантайма; если пропустит — отчёт скажет «Менеджер оставил это на месте».
  - Аргумент `remove` — `<runtimeIdentifier>/<сборка>`: UUID образа `simctl` не принимает. Пароль не нужен: удаляет демон `simdiskimaged`. Симулятор этого рантайма запущен — отказ.
  - Папка без известного рантайма, папки старых сборок macOS и `inc` — только поиск: CoreSimulator удаляет их сам. `runtime delete` удаляет и кэш рантайма.
- **Удаление через `simctl`:**
  - операция элемента — из вывода `simctl` при скане: `.simulator(udid:)`, `.runtime(identifier:runtimeIdentifier:)`;
  - перед командой список перечитывается: симулятор — только `Shutdown`, рантайм — только без симуляторов; симуляторы очистки удаляются раньше рантаймов;
  - гонка «новый симулятор попал в сироты» закрыта: папку без симулятора `Cleaner` сверяет со свежим `simctl list`;
  - рантайм под текущий SDK без симуляторов тоже помечается мусором, но сам не отмечается;
  - клоны в `XCTestDevices` и `Previews` — тоже симуляторы, правило «запущенный не отмечается» к ним сейчас не применяется.
- Даты в подписях — всегда по-русски (`ru_RU`), независимо от языка системы.
- Минимальная версия системы проектов пользователя не учитывается: рантайм iOS 15 отмечается как мусор, если на нём нет симуляторов, даже когда проект поддерживает iOS 15.
- Под тестами `simctl` и `xcode-select` не вызываются: автоскан отключён, тесты подменяют `CommandRunner`.

## Кодовые якоря (индекс)

- Код: `derivedDataItem(_:home:)`, `deviceSupportItem(_:)`, `archives(in:)`, `simulators(in:runner:)`, `runtimes(runner:)`, `applications(in:runner:)`, `applicationPath(fromDeveloperDirectory:)`, `displayName(ofRuntime:)`, `listDevicesArguments`, `listRuntimesArguments`, `rootLabel(forRootNamed:)`, `developerDirectory(runner:)`, `simctlPath(runner:)`, `dyldCaches(system:runner:)`, `hostBuild()`, `dyldCacheRuntime(_:)`, `availability(from:)`, `unavailableReason`, `noXcodeReason`, `simctlFailedReason`, `unknownActiveXcodeReason`
- Формулировки поиска: «симулятор не отмечен», «рантайм не нужен», «проекта больше нет», «папка без симулятора», «старый Xcode», «бета Xcode»

### Ключевые файлы

- /Trash/Services/XcodeScanner.swift (service — Поиск Xcode)
- /Trash/Services/SimulatorCatalog.swift (service — Симуляторы и рантаймы)
- /Trash/Services/CommandRunner.swift (service — Запуск утилит)
- /TrashTests/XcodeScannerTests.swift (tests — Поиск Xcode)
- /TrashTests/CommandRunnerTests.swift (tests — Запуск утилит)
