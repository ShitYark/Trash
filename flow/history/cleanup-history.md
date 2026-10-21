# История изменений: cleanup

Хроника правок модуля очистки. Текущее состояние модуля и контракт безопасности — [`cleanup.md`](../knowledge/modules/cleanup.md). Формат — `flow/meta/conventions.md` → «Формат записи истории модуля».

## Активные записи

#### 2026-10-13 — Найдены и чистятся кэши симуляторов, кэши в данных программ и установщики из «остальных данных»

- Суть: узкие правила стража для кэшей в данных программ и установщиков; перед кэшами программы `Cleaner` проверяет её папку `lsof -t +D` — запущена или не понять — отказ; операция `.dyldCacheRemove` с отказом при запущенном симуляторе. `CommandRunner` — режим «вывод с ошибками при любом коде выхода».
- Решения:
  - Запущенность — **намеренно** по открытым файлам, а не по имени: имя папки и программы совпадают не всегда, «Яндекс Музыка» лежит в `YandexMusic`.
  - Решает вывод `lsof`, а не код выхода: он выходит с 1 и тогда, когда нашёл процессы, — эту ошибку поймал прогон на диске пользователя.
- Ревью: Medium — установщики как мусор и сбой `lsof` как «закрыта» — закрыты. Low закрыты, кроме двух, записанных в `xcode.md`: полный размер пересоздаваемого кэша в «Освобождено», отказ не видит клоны Previews.
- Тесты: `ManagerRemovalTests.applicationCachesAreKeptWhileProgramHoldsFiles`, `OtherDataTests.openFilesAreDetectedByOutputNotExitCode`, `CommandRunnerTests.answersWithAnyStatusKeepsOutputAndErrors`. Мутации ловятся.
- Файлы: `Trash/Services/Cleaner.swift`, `Trash/Services/SafetyGuard.swift`, `Trash/Services/ManagerRemover.swift`, `Trash/Services/CommandRunner.swift`, `Trash/Models/ManagerRemoval.swift`, `TrashTests/ManagerRemovalTests.swift`, `TrashTests/CommandRunnerTests.swift`

#### 2026-10-13 — Битые ссылки, службы удалённых программ и неактивные версии MacPorts удаляются, где нужно — с паролем администратора

- Суть: очередь 3. Узкие правила стража — битая ссылка прямо в папке команд и обычный plist прямо в папке служб, в том числе вне `~`. В системных папках без права записи шаги идут одним скриптом от root — `AdministratorScript`: `osascript` с `do shell script … with administrator privileges`, в фоне, тайм-аут 10 минут. Под root каждый шаг заново проверяет себя: `cd -P` и сверка `pwd -P`, ссылка всё ещё битая, plist с той же меткой и без программы, версия порта всё ещё неактивна.
- Решения:
  - Зона удаления вне `~` и `rm` от root без Корзины — **пользователем**, для ссылок, служб и MacPorts; запасной путь программ «только Finder и только в Корзину» не меняется.
  - Root — **намеренно** только для фиксированных системных папок; своя папка без права записи — отказ, иначе root пошёл бы по подменённому пути.
  - Службы **намеренно** не выгружаются: по метке можно снять другую, живую службу; без программы эта не запустится.
  - Один скрипт на очистку — **намеренно**: кэш авторизации по TN2065 только для того же скрипта.
- Ревью: High закрыты — программа службы перепроверяется под root, root не идёт по подменённому пути. Medium — выгрузка по метке убрана, одно правило root для окна и очистки, свежий список неактивных портов, `osascript` в фоне с тайм-аутом. Low закрыты.
- Тесты: `AdministratorScriptTests` — скрипт исполняется `sh` во временной папке: кавычки и `$HOME` в имени, ожившая ссылка, подменённая папка, чужая метка, программа на месте, коды отмены; `ManagerRemovalTests` — один скрипт, своя закрытая папка, отмена и прерванный скрипт, MacPorts; `SafetyGuardTests.brokenLinksAndServicePlistsAreDeletableOnlyThemselves`. Мутации ловятся.
- Файлы: `Trash/Services/AdministratorScript.swift`, `Trash/Services/Cleaner.swift`, `Trash/Services/SafetyGuard.swift`, `Trash/Services/ManagerRemover.swift`, `Trash/Models/ManagerRemoval.swift`, `TrashTests/AdministratorScriptTests.swift`, `TrashTests/ManagerRemovalTests.swift`, `TrashTests/SafetyGuardTests.swift`

#### 2026-10-13 — Android SDK, Docker, conda и Ollama стали удаляемыми

- Суть: очередь 2 удаления «только поиск». Android — файлами по узкому правилу стража: пакет SDK с `package.xml` на своей глубине или `<имя>.avd`; `Cleaner` отказывает для запущенного эмулятора и образа, нужного эмулятору, удаляет `<имя>.ini` вместе с папкой. Docker, conda и Ollama — новыми операциями `ManagerRemover`: `docker … prune`, `conda remove --all` и `conda clean --all`, `DELETE /api/delete` через `curl`. Отказы в отчёте — с именем строки (`Failure.title`).
- Решения:
  - Android-пакеты и эмуляторы — **намеренно** сами, без `sdkmanager` и `avdmanager`: первый может скачать Android CLI, второму нужна Java, и ни один не проверяет запущенный эмулятор.
  - `docker` — **намеренно** с `--host` сокета Docker Desktop, а не текущим контекстом.
  - Ollama — **намеренно** через сервер, а не `ollama rm`: CLI может запустить Ollama.app.
  - «Неизвестно — отказ»: папку эмуляторов или образ эмулятора не определить — образ не удаляется.
- Ревью: High закрыты — контекст docker, нечитаемая папка эмуляторов как пустая, `.ini` мимо стража. Medium — порядок образы→контейнеры, обещание про активное окружение conda, `_` в именах Ollama, проверка манифеста после удаления, эмуляторы вне папки. Low закрыты все.
- Тесты: `ManagerRemovalTests` — запущенный эмулятор по PID и `flock`, образ в работе и неизвестный, `.ini`-папка, docker с `--host` и порядком, conda с подделками, Ollama: коды, `_`, манифест на месте; `SafetyGuardTests.androidPackagesAndEmulatorsAreDeletableOnlyThemselves`. Мутации ловятся.
- Файлы: `Trash/Models/ManagerRemoval.swift`, `Trash/Services/ManagerRemover.swift`, `Trash/Services/Cleaner.swift`, `Trash/Services/SafetyGuard.swift`, `TrashTests/ManagerRemovalTests.swift`, `TrashTests/SafetyGuardTests.swift`

#### 2026-10-13 — Окно очистки говорит только про отмеченное

- Суть: `CleanupReport` считает, куда ушло удалённое: `movedToTrash` — Корзина, включая программы при любом режиме, `deletedPermanently` — навсегда, включая содержимое Корзины, `removedByManagers`. Что и как удаляется, не менялось.
- Тесты: `ScannerAndCleanerTests.cleanerDeletesAllowedItems`, `ApplicationsTests.applicationDeniedByPermissionsGoesToTrashThroughFinder` — счётчики.
- Файлы: `Trash/Services/Cleaner.swift`, `Trash/Models/ScanResult.swift`, `TrashTests/ScannerAndCleanerTests.swift`, `TrashTests/ApplicationsTests.swift`

#### 2026-10-13 — Рантаймы, симуляторы, пакеты Homebrew и версии языков стали удаляемыми

- Суть: новый путь удаления — через менеджер. `ManagerRemoval` у элемента берётся из вывода `simctl` и `brew` при скане, `ManagerRemover` запускает фиксированную команду с проверенным идентификатором после перечитывания состояния. Симуляторы и версии языков — узкими правилами `SafetyGuard`, а не корнями. `Cleaner` перепроверяет папки без симулятора свежим `simctl list` и активность версии языка. В отчёте — `removedByManagers`.
- Решения:
  - Снята прежняя защита «симуляторы, рантаймы, Homebrew, версии языков — только поиск» — **пользователем**: она была временной. Вместо неё — своя защита пути через менеджер, контракт в `cleanup.md`.
  - `brew` — **намеренно** с `HOMEBREW_NO_AUTOREMOVE=1`: иначе `brew uninstall` сам удалил бы неотмеченные зависимости.
  - `brew cleanup` — **намеренно** только после `--dry-run`, совпавшего с отметками до версии: команда чистит все версии формулы, в том числе те, что в окне не отмечаются.
  - Активная версия не определилась — **намеренно** отказ для всех версий менеджера, а не «неактивна».
- Повторное ревью: Medium — mise читал не все конфиги, закрыта. Low закрыты — закрепление после скана проверяется перед `uninstall`, страж не пропускает ссылки-псевдонимы версий, тексты окна и ошибок.
- Ревью: High закрыты — автоудаление зависимостей, лишние версии в `brew cleanup`, активная версия под другим именем, папки симуляторов и версий как корни для любого раздела. Medium — тексты окна, закреплённые формулы, тесты. Low — только `Shutdown`, UDID операции равен папке, список папок версий читается при каждой проверке.
- Тесты: `ManagerRemovalTests` — полные команды с `env`, холостой прогон и отказ при несовпадении, подделанные идентификаторы и операции, `Booting`, неопределённая версия; `SafetyGuardTests.simulatorAndVersionFoldersAreDeletableOnlyThemselves`. Мутации снятия сверки, правила «неизвестно» и узких правил ловятся.
- Файлы: `Trash/Models/ManagerRemoval.swift`, `Trash/Services/ManagerRemover.swift`, `Trash/Services/Cleaner.swift`, `Trash/Services/SafetyGuard.swift`, `TrashTests/ManagerRemovalTests.swift`, `TrashTests/SafetyGuardTests.swift`

#### 2026-10-12 — «Терминал» показывает только найденное, добавлены Bun, asdf, mise, Docker, conda, MacPorts и Ollama

- Суть: `SafetyGuard.keptFolders` — папки внутри разрешённых корней, которые нельзя удалять никогда: глобальное хранилище Bun `~/.bun/install/cache/links`. Новый удаляемый корень — кэш Bun; новые разделы Docker, conda, MacPorts, Ollama — неудаляемые, без корней.
- Решения: две независимые защиты для `links` — исключение в сканере и отказ стража — **намеренно**, как у неудаляемых категорий.
- Тесты: `SafetyGuardTests.toolSettingsNextToTerminalCachesAreNotDeletable` — `links`, `~/.bun/bin`, `~/.bun/install/global`, `~/.bunfig.toml`, версии asdf и mise, модели Ollama, окружение conda.
- Файлы: `Trash/Services/SafetyGuard.swift`, `TrashTests/SafetyGuardTests.swift`

#### 2026-10-12 — Программы, принадлежащие системе, удаляются в Корзину через Finder с паролем администратора

- Суть: `NSWorkspace.recycle` для программ root пароль не спрашивает и отказывает — пользователь не смог удалить YouBooster из App Store. `Recycler.moveToTrash` при отказе по правам — Cocoa 513, POSIX `EACCES`/`EPERM`, в том числе вложенные — передаёт программу Finder Apple Event'ом «удалить»: Finder спрашивает пароль и кладёт программу в Корзину. Ошибки Finder — понятные причины в отчёте. Добавлены entitlement `com.apple.security.automation.apple-events` и `NSAppleEventsUsageDescription`. Отчёт при нуле удалённого пишет «Ничего не удалено».
- Решения:
  - Запасной путь — **только** Finder и только в Корзину, **намеренно** без `rm` с правами администратора: программы по-прежнему удаляются только в Корзину.
  - Отмена пароля действует до конца очистки **намеренно**: иначе при 19 программах root пароль спросили бы 19 раз.
  - Ссылку на программу Finder не получает **намеренно**: с правами администратора он мог бы переложить её цель.
  - Прошлое предположение «macOS сам спросит пароль» было непроверенным и опровергнуто.
- Ревью: Medium закрыты — `canInteract` в событии, иначе Finder мог не показать запрос пароля; повторные запросы после отмены. Low: ссылки не идут в Finder, текст таймаута «проверьте Корзину».
- Тесты: `ApplicationsTests` — отказ по правам ведёт в Finder и в «удалено», программа не удаляется мимо Корзины; другие ошибки пароль не спрашивают; отказ Finder с причиной; после отмены пароль не спрашивается; ссылка не уходит в Finder.
- Файлы: `Trash/Services/Cleaner.swift`, `Trash/Services/FinderTrash.swift`, `Trash/Trash.entitlements`, `Trash.xcodeproj/project.pbxproj`, `Trash/Views/CleanupReportSheet.swift`, `TrashTests/ApplicationsTests.swift`

#### 2026-10-12 — Добавлен раздел Программы: удаление программ и поиск остатков удалённых программ

- Суть: `SafetyGuard` — два узких правила: `.app` прямо в папке программ и остаток с именем-идентификатором прямо в папке данных программ. `normalized` приводит и ещё не созданные пути (`canonicalFileURL`). `Cleaner` — программы через `Recycler` всегда в Корзину, отказ запущенной; остатки — перепроверка по свежему каталогу.
- Решения:
  - Расширение зоны удаления за пределы `~` — **только** для самого `.app`, по решению пользователя в конфликте с историей; всё остальное вне `~` по-прежнему только читается.
- Тесты: `ApplicationsTests.guardAllowsOnlyApplicationBundlesAndLeftoverEntries`, `cleanerRecyclesApplicationsButNotRunningOnes`, `cleanerRechecksLeftoversBeforeDeleting`; `SafetyGuardTests.searchOnlyCategoriesAreNotDeletable` — `/Applications` и содержимое бандла никогда.
- Файлы: `Trash/Services/SafetyGuard.swift`, `Trash/Services/Cleaner.swift`
- План: `flow/plans/applications-section.md`

#### 2026-10-12 — Добавлен раздел Терминал: Homebrew, Android SDK, Gradle, кэши пакетов, программы вне Homebrew, службы и версии языков

- Суть: новые удаляемые корни — `~/.gradle/caches|wrapper/dists|daemon` и кэши менеджеров пакетов внутри `~`. Остальные разделы Терминала — `isDeletable == false`.
- Решения:
  - Рядом с удаляемыми кэшами **намеренно** не удаляются настройки и утилиты: `~/.gradle/gradle.properties`, `~/.npmrc`, `~/.cargo/bin`, `~/.cargo/config.toml`, `~/.m2/settings.xml`, `~/.pub-cache/bin`, `global_packages`.
- Тесты: `SafetyGuardTests.toolSettingsNextToTerminalCachesAreNotDeletable`.
- Файлы: `TrashTests/SafetyGuardTests.swift`
- План: `flow/plans/terminal-section.md`

#### 2026-10-12 — Добавлен раздел Xcode с поиском рантаймов, симуляторов, DerivedData по проектам и других артефактов

- Суть: `Cleaner` отклоняет элементы неудаляемых категорий (`isDeletable == false`: симуляторы, рантаймы, копии Xcode) до проверки `SafetyGuard`, с причиной в отчёте. `SafetyGuard` по умолчанию разрешает корни только удаляемых категорий.
- Решения:
  - Две независимые защиты **намеренно**: даже страж с корнем `CoreSimulator/Devices` не приведёт к удалению папки симулятора.
  - Корни вне домашней папки не добавлялись; копии Xcode в `/Applications` в этой задаче не удаляются вообще.
- Тесты: `SafetyGuardTests.searchOnlyCategoriesAreNotDeletable`, `xcodeUserDataNextToRootsIsNotDeletable` — настройки Xcode рядом с корнями не удаляются, `everyCategoryRootIsInsideHomeAndNotProtected`; `ScannerAndCleanerTests.cleanerRefusesSearchOnlyCategoriesEvenIfGuardAllows`.
- Файлы: `Trash/Services/Cleaner.swift`, `Trash/Services/SafetyGuard.swift`, `TrashTests/SafetyGuardTests.swift`, `TrashTests/ScannerAndCleanerTests.swift`
- План: `flow/plans/xcode-full-scan.md`

#### 2026-10-12 — Создан каркас приложения: сканирование, очистка и главное окно

- Суть: удаление через `Cleaner` с обязательной проверкой каждого пути в `SafetyGuard`; два режима — «Переместить в Корзину» и «Удалить навсегда»; отчёт с освобождённым местом и ошибками.
- Решения:
  - Разрешённые корни удаления = корни категорий; сам корень удалить нельзя, только содержимое.
  - Сравнение путей — по компонентам, не по строковому префиксу; симлинки раскрываются только в родительских папках.
  - Список защищённых путей зашит в код, настройкой не меняется — **намеренно**.
  - Корзина удаляется только навсегда, независимо от выбранного режима.
  - Ошибка одного элемента не прерывает очистку остальных.
- Тесты: `SafetyGuardTests` — 7 сценариев, включая выход через `..` и соседнюю папку с тем же префиксом; `ScannerAndCleanerTests` — удаление разрешённого и отказ для пути вне корней, во временной папке.
- Файлы: `Trash/Services/Cleaner.swift`, `Trash/Services/SafetyGuard.swift`, `Trash/Models/ScanResult.swift`, `TrashTests/SafetyGuardTests.swift`, `TrashTests/ScannerAndCleanerTests.swift`
