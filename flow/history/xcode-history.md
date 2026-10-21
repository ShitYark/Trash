# История изменений: xcode

Хроника правок модуля поиска мусора Xcode. Текущее состояние модуля — [`xcode.md`](../knowledge/modules/xcode.md). Формат — `flow/meta/conventions.md` → «Формат записи истории модуля».

## Активные записи

#### 2026-10-13 — Найдены и чистятся кэши симуляторов, кэши в данных программ и установщики из «остальных данных»

- Суть: «Общие кэши симуляторов» — dyld-кэши рантаймов в `/Library/Developer/CoreSimulator/Caches/dyld`, удаляет `simctl runtime dyld_shared_cache remove <runtimeIdentifier>/<сборка>`. Мусор — недоступные рантаймы: их кэш больше не создаётся. Сборка macOS — из `kern.osversion`.
- Решения:
  - `/Library` **намеренно** не корень: папку читает сканер, удаляет `simctl`.
  - Кэши рабочих рантаймов удаляемы, но не мусор: CoreSimulator создаст их заново.
- Тесты: `XcodeScannerTests.dyldCachesAreMatchedToRuntimeAvailability`; `ManagerRemovalTests.dyldCacheIsRemovedBySimctlUnlessItsSimulatorRuns`.
- Файлы: `Trash/Services/XcodeScanner.swift`, `Trash/Services/SimulatorCatalog.swift`, `TrashTests/XcodeScannerTests.swift`

#### 2026-10-13 — Рантаймы, симуляторы, пакеты Homebrew и версии языков стали удаляемыми

- Суть: симуляторы и рантаймы удаляются через `simctl delete` и `simctl runtime delete`. Операция у элемента — из вывода `simctl`; встроенный рантайм — без операции, только поиск. Папка без симулятора — файлами, после свежего `simctl list`. Сами не отмечаются, явный мусор — с меткой.
- Решения:
  - Не отмечаются сами **намеренно**: после скана сразу отметились бы 55,5 ГБ рантаймов, среди них нужный проекту iOS 15.
  - Удаляется только симулятор в состоянии `Shutdown`; `Booting` и `Shutting Down` тоже заняты.
- Файлы: `Trash/Services/XcodeScanner.swift`, `TrashTests/XcodeScannerTests.swift`

#### 2026-10-12 — Добавлен раздел Программы: удаление программ и поиск остатков удалённых программ

- Суть: «Старые версии Xcode» стали удаляемыми — тем же правилом и способом, что программы: только в Корзину.
- Решения:
  - Отменено решение «копии Xcode в /Applications намеренно только находятся» — пользователем, чтобы одна копия не была удаляемой в одном разделе и неудаляемой в другом.
- Файлы: `Trash/Models/CleanupCategory.swift`, `TrashTests/XcodeScannerTests.swift`
- План: `flow/plans/applications-section.md`

#### 2026-10-12 — Добавлен раздел Терминал: Homebrew, Android SDK, Gradle, кэши пакетов, программы вне Homebrew, службы и версии языков

- Суть: правило «всё, кроме самой свежей версии» для Device Support вынесено в общий `VersionPolicy`; поведение не изменилось.
- Файлы: `Trash/Services/XcodeScanner.swift`, `TrashTests/XcodeScannerTests.swift`
- План: `flow/plans/terminal-section.md`

#### 2026-10-12 — Добавлен раздел Xcode с поиском рантаймов, симуляторов, DerivedData по проектам и других артефактов

- Суть: секция «Xcode» в боковой панели — 12 категорий: рантаймы и симуляторы из `simctl` с папками-сиротами, DerivedData с именем проекта и пометкой «проекта больше нет», Device Support по версиям, архивы, превью SwiftUI, кэш документации, кэши SwiftPM/CocoaPods/Carthage, кэши Xcode и симуляторов, логи, Products, неактивные копии Xcode. У элементов — подписи и поэлементная отметка явного мусора.
- Решения:
  - Симуляторы, рантаймы и копии Xcode **намеренно** только находятся, без удаления: пользователь попросил в этой задаче только логику поиска. Удаление через `simctl` — следующая задача.
  - Рантайм отмечается, только если удаляемый и не нужен ни одному симулятору; список симуляторов не получен — не отмечается ничего.
  - `simctl` не ответил — категория «Симуляторы» пустая: без списка сироту не отличить.
  - Самая свежая версия Device Support платформы **намеренно** не отмечается — нужна для текущего устройства.
  - Активный Xcode не определён — копии Xcode не показываются вовсе.
  - Архивы и Products не отмечаются: в архивах символы для разбора крашей.
  - `simctl` запускается только из существующего активного Xcode, напрямую, без `xcrun`, с таймаутом 30 с: без Xcode заглушки `/usr/bin` показывают диалог установки, зависший `simctl` блокировал бы скан.
  - Отказ `simctl` или неизвестный активный Xcode — «Нет данных» с причиной, а не «Здесь чисто».
- Тесты: `XcodeScannerTests` — 13 сценариев на JSON-фикстурах `simctl` и временных папках, запуск утилит подменён; `CommandRunnerTests` — вывод, код выхода, таймаут на реальных `/bin/echo` и `/bin/sleep`.
- Ревью: findings Medium закрыты — таймаут и отмена команд, `simctl` только при установленном Xcode, запрещающие тесты для соседних с корнями настроек Xcode.
- Разведка на Mac пользователя, только чтение: рантаймы 90,9 ГБ, из них не нужны симуляторам 55,5 ГБ; DerivedData 37 ГБ; симуляторы 37,7 ГБ; Device Support 10,8 ГБ; `Xcode beta1` 4,3 ГБ.
- Файлы: `Trash/Services/XcodeScanner.swift`, `Trash/Services/SimulatorCatalog.swift`, `Trash/Services/CommandRunner.swift`, `TrashTests/XcodeScannerTests.swift`, `TrashTests/CommandRunnerTests.swift`
- План: `flow/plans/xcode-full-scan.md`
