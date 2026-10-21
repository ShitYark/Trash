# Сканирование

Поиск мусора по категориям и подсчёт занимаемого места. Модуль **только читает диск** — ничего не удаляет и не меняет.

## Точки входа

- `CleanupCategory` — список категорий: секция (`group`), корневые папки, способ поиска (`scanMethod`), заголовок, описание, иконка, выбор по умолчанию, удаляемость (`isDeletable`), исключения.
- `CategoryGroup` — группы категорий: «Система» — по пункту боковой панели на категорию; «Программы», «Xcode» и «Терминал» — по одному пункту с разделами.
- `CleanupScanner.scan(_:)` — сканирует одну категорию по её `scanMethod`.
- `SystemLocations` — системные папки вне `~`: сканер их только читает, корнями категорий они не становятся; в тестах подменяются.
- `CleanupScanner.allocatedSize(of:)` — место на диске файла или папки со всем содержимым.
- `CleanupScanner.list(_:accessDenied:)` — содержимое папки с отметкой отказа в правах.
- Модели: `ScanItem` (URL, размер, категория, `title`, `details`, `isRecommended`, `removal` — операция менеджера, если элемент удаляет `simctl` или `brew`), `CategoryScanResult` (элементы, `isAccessDenied`, `unavailableReason`, сумма).

## Категории секции «Система»

| Категория | Корни | Выбрана по умолчанию | Особенности |
|---|---|---|---|
| `userCaches` | `~/Library/Caches` | да | кэш самого Trash исключён; кэши Xcode и пакетов — в секции «Xcode» |
| `userLogs` | `~/Library/Logs` | да | журналы симуляторов — в секции «Xcode» |
| `trash` | `~/.Trash` | нет | нужен Full Disk Access; удаляется только навсегда |
| `applicationSupportCaches` | нет — `~/Library/Application Support` читает `OtherDataScanner` | нет | папки-кэши Chromium и Electron рядом с `Local State` или `Preferences` — обычным файлом, не папкой и не ссылкой, — до глубины 4; удаляются только у закрытой программы |
| `downloadedInstallers` | нет — `~/Downloads` читает `OtherDataScanner` | нет | `.dmg`, `.pkg`, `.xip` прямо в Загрузках — файлы, папкой только `.pkg`; мусором не помечаются: образ диска бывает и вашим |

**«Остальные данные»** на полосе диска — занятое место минус всё найденное. Разведка 2026-10-13: кэши dyld симуляторов в `/Library` — теперь «Общие кэши симуляторов» в `xcode.md`; Chromium-кэши в Application Support и установщики — разделы выше. Не разбираются и не чистятся: подготовленное обновление macOS в Preboot, данные программ вроде `Claude/vm_bundles`, `~/Library/Containers` — macOS закрывает их запросом доступа к данным других программ, `/var/folders` — ими пользуются запущенные программы, файлы пользователя на Рабочем столе.

Категории группы «Xcode» — `xcode.md`, группы «Терминал» — `terminal.md`.

## Способы поиска (`ScanMethod`)

- `children` — каждый непосредственный потомок каждого корня; подпись — `rootLabel(forRootNamed:)`, если категория из нескольких корней; у корня с `rootWarning(forRootNamed:)` элемент сам не отмечается, а предупреждение дописывается в подпись.
- `derivedData`, `deviceSupport`, `archives`, `simulators`, `runtimes`, `applications` — особая логика в `XcodeScanner`, см. `xcode.md`.
- `androidSDK`, `homebrew`, `gradle`, `programs`, `services`, `languageVersions`, `docker`, `conda`, `macPorts`, `ollama` — особая логика в `TerminalScanner`, см. `terminal.md`.
- `installedApplications`, `appLeftovers` — `ApplicationsScanner`, см. `applications.md`.
- `dyldCaches` — `XcodeScanner.dyldCaches`, см. `xcode.md`; `applicationSupportCaches`, `installers` — `OtherDataScanner`.

## Связанные модули

- `cleanup.md` — **корни удаляемых категорий одновременно являются разрешёнными корнями удаления** в `SafetyGuard`. Новая удаляемая категория расширяет зону, где приложение может удалять.
- `xcode.md` — категории и логика группы «Xcode».
- `terminal.md` — категории и логика группы «Терминал».
- `main-window.md` — запуск скана, показ результатов, баннер Full Disk Access.

## Ключевые сценарии

- Все категории сканируются параллельно: `CleanupViewModel.scan()` запускает `TaskGroup`, результаты приходят в UI по мере готовности.
- Корневой папки нет — пустой результат без ошибки.
- Нет прав на чтение корня (`CocoaError.fileReadNoPermission`) — `isAccessDenied = true`; остальные корни и категории сканируются дальше.
- **Без двойного счёта:** при поиске `children` пропускаются папки, которые сами являются корнями других категорий. `~/Library/Caches/org.swift.swiftpm` считается в «Кэшах пакетов», а не ещё раз в «Кэшах приложений».
- Исключаются `.DS_Store`, `.localized`, метка кэша `CACHEDIR.TAG`, папка кэша с bundle id самого приложения и `keeps` кэшей из `ToolCatalog` — у Bun это `links`.
- **Жёсткие ссылки** внутри одного элемента считаются один раз. Элементы, которые делят файлы — окружения и кэш conda, — считаются общим набором: `allocatedSize(of:countedHardLinks:)`.
- Выбор по умолчанию — поэлементный: `ScanItem.isRecommended`; для `children` он равен `isSelectedByDefault` категории.
- **Удаляемость — двух уровней:** категория (`isDeletable`) и элемент (`ScanItem.isDeletable`). В разделах `isManagerOnly` — рантаймы, Homebrew, Docker, conda, Ollama — удаляем только элемент с операцией менеджера `removal`; остальные элементы там — только поиск. `ScanItem.isSearchOnly` — только поиск внутри раздела, удаляемого файлами: emulator, platform-tools, cmdline-tools в Android SDK; в «Программах вне Homebrew» всё, кроме битых ссылок; работающие службы.
- **Сами не отмечаются** разделы с `autoSelectsRecommended == false` — рантаймы, симуляторы, Homebrew, версии языков, Android SDK, Docker, conda, Ollama, программы, службы, MacPorts: удаление там необратимо или затрагивает нужное проекту. Их явный мусор — `ScanItem.isUnmarkedJunk`: метка «мусор» без отметки.
- Элементы сортируются по размеру по убыванию.

## Нюансы

- Размер — `totalFileAllocatedSize`, запасной вариант — `fileAllocatedSize`: это место на диске, а не логический размер. Файл с несколькими жёсткими ссылками внутри одного элемента считается один раз — по `fileIdentifier`, как у `du`. Это inode, он уникален в пределах тома; корни категорий точек монтирования не пересекают. Между разными элементами общий файл учитывается в каждом. Сверка 2026-10-12: все 11 файловых разделов Xcode совпали с `du -sk` в пределах 0,1 %.
- Симлинки не раскрываются: `FileManager.enumerator` не заходит внутрь ссылок, у самой ссылки `isRegularFile == false` — её размер не учитывается.
- Работа с диском идёт в `@concurrent` функциях — вне main actor независимо от настроек изоляции по умолчанию.
- Отмена: циклы проверяют `Task.isCancelled`.
- Тест `everyCategoryRootIsInsideHome` гарантирует, что все корни лежат внутри домашней папки. У рантаймов и копий Xcode корней нет — они ищутся не по файлам `~`.

## Кодовые якоря (индекс)

- Код: `scan(_:)`, `allocatedSize(of:)`, `list(_:accessDenied:)`, `scanChildren(of:makeItem:)`, `roots(home:)`, `rootLabel(forRootNamed:)`, `isExcluded(_:)`, `isSelectedByDefault`, `isDeletable` (явный список без `default`), `isManagerOnly`, `autoSelectsRecommended`, `isUnmarkedJunk`, `removal`, `OtherDataScanner`, `cacheNames`, `profileMarkers`, `isApplicationCache(_:applicationSupport:)`, `isInstaller(_:downloads:)`, `programFolder(of:applicationSupport:)`, `alwaysDeletesPermanently`, `isAccessDenied`, `totalSize`
- Формулировки поиска: «не видит папку», «размер не совпадает с Finder», «замок у категории», «категория пустая», «считается дважды»

### Ключевые файлы

- /Trash/Services/OtherDataScanner.swift (service — Кэши в данных программ и установщики)
- /TrashTests/OtherDataTests.swift (tests — Остальные данные)

- /Trash/Models/CleanupCategory.swift (model — Категории)
- /Trash/Models/ScanResult.swift (model — Результаты сканирования)
- /Trash/Services/CleanupScanner.swift (service — Сканирование)
- /TrashTests/ScannerAndCleanerTests.swift (tests — Сканирование и очистка)
