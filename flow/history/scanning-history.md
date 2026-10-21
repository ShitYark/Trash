# История изменений: scanning

Хроника правок модуля сканирования. Текущее состояние модуля — [`scanning.md`](../knowledge/modules/scanning.md). Формат — `flow/meta/conventions.md` → «Формат записи истории модуля».

## Активные записи

#### 2026-10-13 — Найдены и чистятся кэши симуляторов, кэши в данных программ и установщики из «остальных данных»

- Суть: разобраны «остальные данные». Новые разделы: «Кэши в данных программ» — Chromium-кэши внутри `~/Library/Application Support` рядом с признаком профиля, и «Установщики в Загрузках». Оба — без корней, узкими правилами (`OtherDataScanner`). Не чистятся: Preboot с обновлением macOS, данные программ, `~/Library/Containers`, `/var/folders`.
- Решения:
  - `Service Worker` **намеренно** не трогается: Chromium относит `CacheStorage` к данным сайтов.
  - Установщики **намеренно** не помечаются мусором: образ диска бывает и вашим.
- Тесты: `OtherDataTests` — признак профиля, глубина, остатки, ссылки, папка-признак, установщики, настоящий `lsof`.
- Файлы: `Trash/Services/OtherDataScanner.swift`, `Trash/Models/CleanupCategory.swift`, `Trash/Services/CleanupScanner.swift`, `TrashTests/OtherDataTests.swift`

#### 2026-10-13 — Битые ссылки, службы удалённых программ и неактивные версии MacPorts удаляются, где нужно — с паролем администратора

- Суть: все категории удаляемы — `isDeletable` явным списком без `false`; MacPorts — `isManagerOnly`; программы, службы и MacPorts сами не отмечаются. `ScanItem.searchOnly()`.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Models/ScanResult.swift`

#### 2026-10-13 — Android SDK, Docker, conda и Ollama стали удаляемыми

- Суть: Android SDK, Docker, conda и Ollama — удаляемые разделы, сами не отмечаются; Docker, conda и Ollama — `isManagerOnly`. `ScanItem.isSearchOnly` — только поиск внутри раздела, удаляемого файлами. `CleanupReport.Failure.title`.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Models/ScanResult.swift`

#### 2026-10-13 — Окно очистки говорит только про отмеченное

- Суть: в `CleanupReport` добавлены счётчики `movedToTrash` и `deletedPermanently` рядом с `removedByManagers` — отчёт пишет, куда ушло удалённое. Заполняет их `Cleaner`, см. историю `cleanup`.
- Файлы: `Trash/Models/ScanResult.swift`

#### 2026-10-13 — Рантаймы, симуляторы, пакеты Homebrew и версии языков стали удаляемыми

- Суть: удаляемость стала двухуровневой — категория и элемент. `ScanItem.removal` — операция менеджера; в разделах `isManagerOnly` удаляется только элемент с ней. Разделы с `autoSelectsRecommended == false` сами не отмечаются, их явный мусор — `isUnmarkedJunk`. `CleanupReport.removedByManagers`.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Models/ScanResult.swift`

#### 2026-10-12 — «Терминал» показывает только найденное, добавлены Bun, asdf, mise, Docker, conda, MacPorts и Ollama

- Суть: `allocatedSize(of:countedHardLinks:)` — общий учёт жёстких ссылок для элементов, которые делят файлы; `isExcluded` пропускает `keeps` кэшей из `ToolCatalog`; новые `ScanMethod` — `docker`, `conda`, `macPorts`, `ollama`; корни `toolCaches` — из каталога.
- Файлы: `Trash/Services/CleanupScanner.swift`, `Trash/Models/CleanupCategory.swift`

#### 2026-10-12 — Добавлен раздел Программы: удаление программ и поиск остатков удалённых программ

- Суть: группа `applications`, категории `installedApplications` и `appLeftovers`, `CleanupScanner` получил `ApplicationEnvironment`.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Services/CleanupScanner.swift`
- План: `flow/plans/applications-section.md`

#### 2026-10-12 — Добавлен раздел Терминал: Homebrew, Android SDK, Gradle, кэши пакетов, программы вне Homebrew, службы и версии языков

- Суть: группа `CategoryGroup.terminal` и 7 категорий; способы поиска `androidSDK`, `homebrew`, `gradle`, `programs`, `services`, `languageVersions`; `SystemLocations` вместо `applicationsDirectory`. Метка `CACHEDIR.TAG` исключена во всех категориях. Кэши Homebrew, pip, Yarn, Poetry, Go ушли из «Кэшей приложений» через правило корней других категорий.
- Решения:
  - Системные папки вне `~` **намеренно** не становятся корнями категорий — тест «все корни внутри дома» остаётся в силе.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Models/ScanResult.swift`, `Trash/Services/CleanupScanner.swift`
- План: `flow/plans/terminal-section.md`

#### 2026-10-12 — Раздел Xcode собран в один пункт боковой панели, исправлен двойной учёт жёстких ссылок

- Суть: `allocatedSize` считал файл с несколькими жёсткими ссылками несколько раз: копия Xcode показывалась на 10 % больше `du`, симуляторы — на 0,8 %. Теперь файл с `linkCount` > 1 учитывается один раз по `fileIdentifier`.
- Решения:
  - Размер по-прежнему — **место на диске**, логический размер не вводился.
  - Дедупликация — внутри одного элемента; общий файл двух элементов учитывается в каждом.
- Сверка с `du -sk`: все 11 файловых разделов Xcode — в пределах 0,1 %.
- Тесты: `ScannerAndCleanerTests.hardLinkedFileIsCountedOnce`; мутация «без дедупликации» ловится.
- Файлы: `Trash/Services/CleanupScanner.swift`, `TrashTests/ScannerAndCleanerTests.swift`
- План: `flow/plans/main-window-xcode-overview.md`

#### 2026-10-12 — Добавлен раздел Xcode с поиском рантаймов, симуляторов, DerivedData по проектам и других артефактов

- Суть: категории разделены на секции «Система» и «Xcode» (`CategoryGroup`), у категории появился способ поиска `scanMethod`, у элемента — `title`, `details` и поэлементный `isRecommended`. Поиск `children` пропускает папки, которые сами являются корнями других категорий: кэши SwiftPM, CocoaPods, Xcode и журналы симуляторов больше не считаются дважды. Прежние категории Xcode влились в секцию «Xcode» — см. `xcode-history.md`.
- Решения:
  - Device Support: решение каркаса «не отмечать по умолчанию» **пересмотрено пользователем** — теперь отмечаются все версии, кроме самой свежей в каждой платформе.
  - Корзина по-прежнему **намеренно** не отмечается по умолчанию.
- Тесты: `XcodeScannerTests.xcodeFoldersAreNotCountedTwice`, обновлён `scannerFindsChildrenSortedBySize`.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Models/ScanResult.swift`, `Trash/Services/CleanupScanner.swift`
- План: `flow/plans/xcode-full-scan.md`

#### 2026-10-12 — Создан каркас приложения: сканирование, очистка и главное окно

- Суть: первая версия сканирования — шесть категорий (кэши приложений, журналы, Xcode DerivedData, Device Support, кэши симуляторов, Корзина), параллельный скан всех категорий, размер на диске по `totalFileAllocatedSize`, отказ в доступе к корню фиксируется как `isAccessDenied` без прерывания скана.
- Решения:
  - Device Support и Корзина **намеренно** не отмечаются по умолчанию: первое нужно для отладки на устройствах, второе удаляется безвозвратно.
  - Элемент категории — непосредственный потомок корня; вложенная структура в UI не раскрывается.
  - Размер — место на диске, а не логический размер; симлинки не раскрываются.
  - Кэш самого Trash, `.DS_Store` и `.localized` исключены из результатов.
- Тесты: `ScannerAndCleanerTests` — сортировка по размеру и исключение `.DS_Store`, отсутствующая папка; `SafetyGuardTests.everyCategoryRootIsInsideHome`.
- Файлы: `Trash/Models/CleanupCategory.swift`, `Trash/Models/ScanResult.swift`, `Trash/Services/CleanupScanner.swift`, `TrashTests/ScannerAndCleanerTests.swift`
