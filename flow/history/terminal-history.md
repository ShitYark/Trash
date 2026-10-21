# История изменений: terminal

Хроника правок модуля «Терминал». Текущее состояние модуля — [`terminal.md`](../knowledge/modules/terminal.md). Формат — `flow/meta/conventions.md` → «Формат записи истории модуля».

## Активные записи

#### 2026-10-13 — Битые ссылки, службы удалённых программ и неактивные версии MacPorts удаляются, где нужно — с паролем администратора

- Суть: «Программы вне Homebrew» — удаляемы только битые ссылки, остальное только поиск; «Фоновые службы» — только с удалённой программой; MacPorts — неактивные версии через `port -N uninstall`. Битая ссылка и удалённая программа — только по `ENOENT` (`isBrokenLink`, `isMissing`); ссылка на `/Volumes/…` не битая. `service(at:)` — общее для скана и перепроверки.
- Решения:
  - `port reclaim` приложение **намеренно** не запускает: без терминала он молча удаляет и неотмеченные порты. Сборка и исходники MacPorts — только поиск.
- Тесты: `TerminalScannerTests` — флаги служб и MacPorts, `lockedOrUnmountedTargetsAreNotMissing`.
- Файлы: `Trash/Services/TerminalScanner.swift`, `TrashTests/TerminalScannerTests.swift`

#### 2026-10-13 — Android SDK, Docker, conda и Ollama стали удаляемыми

- Суть: Android, Docker, conda и Ollama удаляемы. Android — пакеты и эмуляторы, emulator, platform-tools и cmdline-tools — только поиск; чтение эмуляторов вынесено в `AndroidEmulators`: `.avd` и `path=` из `.ini`, запущенный эмулятор, нужные образы. Docker — строки по `docker system df` с `--host` сокета Docker Desktop. conda — операции с `bin/conda` своей базы. Ollama — операция по имени модели.
- Решения:
  - Отменено решение 2026-10-12 «Docker — намеренно один элемент» — **пользователем**: диск делится на строки «Остановленные контейнеры», «Неиспользуемые образы», «Кэш сборки» и «Остальное на диске Docker», которые вместе дают размер диска, — двойного счёта по-прежнему нет.
  - `~/.conda/pkgs` при нескольких базах с conda — **намеренно** только поиск: его чистит `conda clean` любой из них.
  - Эмулятор вне `~/.android/avd` — **намеренно** только поиск.
- Тесты: `TerminalScannerTests` — Android с «только поиск», строки Docker без двойного счёта, conda своей базы, операции Ollama.
- Файлы: `Trash/Services/TerminalScanner.swift`, `Trash/Services/AndroidEmulators.swift`, `TrashTests/TerminalScannerTests.swift`

#### 2026-10-13 — Рантаймы, симуляторы, пакеты Homebrew и версии языков стали удаляемыми

- Суть: Homebrew удаляется через `brew` — ненужная зависимость `uninstall --formula --force`, чистимые старые версии `cleanup <формула>`. Версии языков — папкой, кроме активной и неопределённой. Активная версия сводится к папкам одним правилом для скана и удаления: префиксы, ссылки-псевдонимы, окружения pyenv-virtualenv, `system`. pyenv читает все версии файла, rustup — ещё и override.
- Решения:
  - Ненужная формула, закреплённая или с `.keepme`, **намеренно** не удаляется и мусором не помечается.
  - mise — объединение всех конфигов домашней папки **намеренно**: какой перекрывает какой, для удаления не важно, важно не принять нужную версию за лишнюю.
  - Учитываются только глобальные настройки и файлы самой домашней папки **намеренно**: версии проектов `.python-version`, `.nvmrc`, `rust-toolchain.toml` не найти без обхода диска. Версии сами не отмечаются.
- Тесты: `TerminalScannerTests.languageVersionsResolvePrefixesAliasesAndUnknown`, `homeWideVersionFilesAddActiveVersions`, `pinnedOrKeptUnneededFormulaIsNotRemovable`.
- Файлы: `Trash/Services/TerminalScanner.swift`, `Trash/Services/ToolCatalog.swift`, `Trash/Services/SystemLocations.swift`, `TrashTests/TerminalScannerTests.swift`

#### 2026-10-12 — «Терминал» показывает только найденное, добавлены Bun, asdf, mise, Docker, conda, MacPorts и Ollama

- Суть: разделы «Терминала», где пусто без ошибки, скрыты — у каждого пользователя свой набор инструментов. Кэши менеджеров пакетов и менеджеры версий собраны в каталог `ToolCatalog`. Новые: кэш Bun — удаляемый, кроме `links`; asdf и mise в «Версиях языков»; разделы только поиска Docker, conda, MacPorts, модели Ollama. Пути сверены по документации.
- Решения:
  - Homebrew без `brew` — пусто без причины, раздел скрыт **намеренно**: раньше было «Homebrew не установлен.», но показывать отсутствующий инструмент незачем. Ошибка `brew` по-прежнему видна.
  - Docker — **намеренно** один элемент, диск виртуальной машины: образы и кэш лежат внутри, отдельно посчитались бы дважды. Удалённый Docker не показывается — его данные у «Остатков».
  - У asdf и mise активны **все** версии из списка, не только первая: остальные — запасные.
  - Ссылки в папках версий не показываются: это псевдонимы — `current`, префиксы mise, `rustup toolchain link`.
  - Модели Ollama и окружения conda не отмечаются **намеренно** — это выбор пользователя, а не мусор.
- Ревью: High закрыт — `links` Bun защищён и стражем, не только сканером. Medium закрыты — архив MacPorts по префиксу с точкой; conda без двойного счёта жёстких ссылок; активные версии asdf и mise; Ollama с откатом на старый манифест. Low: имена Ollama с хостом, домен ошибки TCC у Docker, подпись раздела кэшей.
- Тесты: `TerminalScannerTests` — Bun без `links`; asdf и mise; Docker только при установленном Desktop; conda без двойного счёта; MacPorts `2.0_1` не `2.0_10`; Ollama — общие слои, битая ссылка v2, чужой реестр; отсутствующие инструменты — пусто без причины. `SafetyGuardTests` — соседи Bun и `links`. `CleanupViewModelTests` — скрытие пустых и видимость ошибок. Мутация «страж без `keptFolders`» ловится.
- Файлы: `Trash/Services/ToolCatalog.swift`, `Trash/Services/TerminalScanner.swift`, `Trash/Services/SystemLocations.swift`, `Trash/Services/CleanupScanner.swift`, `Trash/Models/CleanupCategory.swift`, `TrashTests/TerminalScannerTests.swift`
- План: `flow/plans/terminal-dynamic-tools.md`

#### 2026-10-12 — Добавлен раздел Программы: удаление программ и поиск остатков удалённых программ

- Суть: своя `canonicalPath` заменена общим `URL.canonicalFileURL`; поведение не изменилось.
- Файлы: `Trash/Services/TerminalScanner.swift`
- План: `flow/plans/applications-section.md`

#### 2026-10-12 — Добавлен раздел Терминал: Homebrew, Android SDK, Gradle, кэши пакетов, программы вне Homebrew, службы и версии языков

- Суть: пункт «Терминал» с 7 разделами — Android SDK и эмуляторы, Homebrew, Gradle, кэши менеджеров пакетов, программы вне Homebrew, фоновые службы, версии языков. Удаляются только кэши Gradle и менеджеров пакетов; остальное — только поиск.
- Решения:
  - Установленные программы, версии и службы **намеренно** только находятся: удалять их правильно через свой менеджер, это следующая задача.
  - Homebrew считается **как сам brew**: «не нужна» — как `brew autoremove`, старые версии — как `brew cleanup`, включая пропуск `outdated`, `pinned`, `.keepme`. Гипотеза «старую версию держит пакет, собранный с ней» проверена и отвергнута: `aom` собран с `brotli 1.1.0`, а `brew cleanup` её удаляет.
  - Системные папки — `SystemLocations`: только чтение, корнями категорий не становятся.
  - `~/.m2/repository`, `~/.cache` и `~/.pub-cache/hosted|git` **намеренно** не отмечаются сами и подписаны предупреждением: ревью показало, что там бывает невосстановимое — сборки `mvn install`, токен Hugging Face, зависимости глобальных утилит Dart. Решение пользователя — вариант «оставить, но не отмечать».
  - Без списка эмуляторов образы не отмечаются; у nvm с `lts/*` активная версия неизвестна — версии не отмечаются.
  - Docker в интерпретации исключался по ошибочной причине «у Docker Desktop своя очистка» — Docker Desktop у пользователя удалён. Его данные — задача «Остатки удалённых программ».
- Сверка на Mac пользователя, только чтение: совпадение с `brew autoremove --dry-run` (0) и `brew cleanup --dry-run` (16 версий); 15 битых ссылок Docker и Parallels; 2 службы Docker без программы; build-tools 30.0.3 и 35.0.0 отмечены, образ эмулятора `tablet` — нет.
- Ревью: Low закрыты — Homebrew сверен с исходниками `brew autoremove` / `cleanup` (сборка из исходников и build-зависимости, `aliases` / `oldnames`, подключённая старая версия при установленной новой); рабочая ссылка в папке-ссылке больше не «битая», и такая папка читается; fnm — активная версия над `installation` и папка `~/.local/share/fnm`; `npm` и `corepack` из формулы node не показываются; `isDeletable` — явный список без `default`. По ходу сверки найдена и исправлена собственная регрессия: npm установщика Node.js в `/usr/local` пропадал.
- Тесты: `TerminalScannerTests` — 14 сценариев; мутации правил `outdated` Homebrew и использования образа Android ловятся; сквозной `cleanerRemovesTerminalCachesButKeepsSettingsNextToThem`.
- Файлы: `Trash/Services/TerminalScanner.swift`, `Trash/Services/HomebrewCatalog.swift`, `Trash/Services/VersionPolicy.swift`, `Trash/Services/SystemLocations.swift`, `TrashTests/TerminalScannerTests.swift`
- План: `flow/plans/terminal-section.md`
