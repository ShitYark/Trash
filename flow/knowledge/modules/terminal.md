# Терминал

Поиск того, что поставлено через терминал и не видно в Программах и Launchpad: Android SDK, Homebrew, Gradle, кэши менеджеров пакетов, программы мимо Homebrew, фоновые службы, версии языков, Docker, conda, MacPorts, модели Ollama. Разделы окна пункта «Терминал» боковой панели (`CategoryGroup.terminal`, `GroupOverviewView`).

**Видно только найденное:** у каждого пользователя свой набор инструментов, поэтому раздел, где пусто без ошибки, скрыт (`CategoryGroup.hidesEmptySections`, `CleanupViewModel.visibleCategories(in:)`). «Нет данных» с причиной и замок остаются; во время скана видно всё.

Что удаляется:
- кэши — «Gradle» и «Кэши менеджеров пакетов», файлами внутри `~`;
- Homebrew — командой `brew`: ненужная зависимость — `brew uninstall`, чистимые старые версии — `brew cleanup`; защита — `cleanup.md` → «Удаление через менеджер»;
- версии языков — папкой версии, кроме активной и неопределённой;
- Android — папкой пакета SDK или эмулятора, кроме запущенного эмулятора и нужного ему образа;
- Docker — `docker … prune`, conda — `conda remove` и `conda clean`, Ollama — её сервером: сразу, без Корзины.

- битые ссылки, службы с удалённой программой и неактивные версии MacPorts — в чужих папках с паролем администратора: `cleanup.md` → «С паролем администратора».

Остальное в «Программах вне Homebrew», работающие службы, папки сборки и исходники MacPorts — только поиск.

## Точки входа

- `TerminalScanner` — поиск по разделам с подписями и рекомендациями.
- `ToolCatalog` — **каталог инструментов**: кэши менеджеров пакетов (`Cache`: инструмент, путь, предупреждение, `keeps`) и менеджеры версий (`VersionManager`). Новый кэш или менеджер версий — одна запись; корни, подписи и предупреждения `toolCaches` берутся отсюда.
- `HomebrewCatalog` — разбор JSON `brew info --json=v2 --installed`, правило «зависимость больше не нужна».
- `VersionPolicy` — «всё, кроме самой свежей версии»; общее с Device Support из `xcode.md`.
- `SystemLocations` — системные папки (`/usr/local`, `/Library`, `/Applications`, префиксы Homebrew). Сканер их только читает, корнями категорий они не становятся, в тестах подменяются. Пакеты в префиксе Homebrew удаляет сам `brew`.
- Категории и корни — в `CleanupCategory`, модуль `scanning.md`.

## Разделы

| Раздел | Источник | Отмечается сам | Удаляется |
|---|---|---|---|
| Android SDK и эмуляторы | `~/Library/Android/sdk`, `~/.android/avd/*.avd/config.ini` | ничего; меткой «мусор» — образ системы, который не указан в `image.sysdir.1` ни одного эмулятора; build-tools и NDK — кроме самой свежей версии | папкой: образы, build-tools, NDK, платформы, эмуляторы; emulator, platform-tools, cmdline-tools — нет |
| Homebrew | `brew info --json=v2 --installed`, `Cellar`, `Caskroom` | ничего; меткой «мусор» — формула, не нужная ни одному явно поставленному пакету и cask, и старая версия по правилам `brew cleanup` | через `brew`: ненужная незакреплённая формула — `uninstall`, чистимые старые версии — `cleanup`; cask, явно поставленные и закреплённые — нет |
| Gradle | `~/.gradle/caches`, `~/.gradle/wrapper/dists`, `~/.gradle/daemon` | всё; дистрибутивы — кроме самой свежей версии | да |
| Кэши менеджеров пакетов | `ToolCatalog.caches`: `Caches/Homebrew`, `~/.npm/_cacache`, `Caches/Yarn`, `~/Library/pnpm/store`, `Caches/pip`, `Caches/pypoetry`, `Caches/go-build`, `~/.cargo/registry`, `~/.m2/repository`, `~/.pub-cache/hosted` и `git`, `~/.cache`, `~/.bun/install/cache` | все, кроме Maven, pub-cache и `~/.cache` — у них предупреждение в подписи | да |
| Программы вне Homebrew | Python в `/Library/Frameworks/Python.framework/Versions`, `lib/node_modules` префиксов, команды `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/go/bin`, pipx | ничего; меткой «мусор» — ссылка на удалённую программу | только битые ссылки: в своей папке — по режиму, в `/usr/local/bin` — от root |
| Фоновые службы | `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` | ничего; меткой «мусор» — служба, чья программа — абсолютный путь — не существует | только такие: plist, без выгрузки; в `/Library` — от root |
| Версии языков | `ToolCatalog.versionManagers`: nvm, fnm, Volta, pyenv, rbenv, rustup, SDKMAN, asdf, mise | ничего; меткой «мусор» — все, кроме активных; активную не определить — ни одна | папкой версии; активную и неопределённую — нет |
| Docker | `/Applications/Docker.app` есть → диск `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`, разобранный по `docker system df --format json` | ничего | `prune`: остановленные контейнеры, неиспользуемые образы, кэш сборки; тома и остальное на диске — нет |
| conda | базы `~/miniconda3`, `~/miniforge3`, `~/anaconda3`, `~/micromamba`, `/opt/miniconda3`, `/opt/anaconda3`, `Caskroom/miniforge|miniconda/base`, `<префикс Homebrew>/anaconda3`: окружения `envs/*` и `~/.conda/envs/*`, кэш `pkgs` и `~/.conda/pkgs` | ничего | `conda remove --all` и `conda clean --all` — если у базы есть `bin/conda`; у micromamba — нет |
| MacPorts | `/opt/local/bin/port` есть → `port installed inactive` и архивы `var/macports/software/<порт>/<порт>-<версия>.*`, `var/macports/build`, `var/macports/distfiles` | ничего; меткой «мусор» — неактивные версии и папки сборки | неактивные версии — `port -N uninstall`, от root, если MacPorts не свой; сборка и исходники — нет |
| Модели Ollama | `~/.ollama/models`: манифесты `manifests/<хост>/<пространство>/<модель>/<тег>` и с 0.40 `manifests-v2/…` — ссылка на блоб | ничего — модель выбор пользователя | сервером Ollama, как `ollama rm`; Ollama должна быть запущена |

## Связанные модули

- `scanning.md` — общий поиск по корням и правило «без двойного счёта»: кэши Homebrew и pip уходят из «Кэшей приложений».
- `cleanup.md` — удаляемые корни Терминала попадают в `SafetyGuard`; Homebrew — удаление через менеджер, версии языков — узкое правило стража; неудаляемые разделы отклоняет `Cleaner`.
- `xcode.md` — `VersionPolicy`, образец запуска утилит и удаления через менеджер (`simctl`).
- `main-window.md` — `GroupOverviewView` и пункт боковой панели.

## Ключевые сценарии

- **Homebrew.** `brew` запускается, только если есть `<префикс>/bin/brew`; префиксы — `/opt/homebrew`, затем `/usr/local`. Работает и с урезанным `PATH`, как при запуске приложения из Finder. Нет `brew` — пусто без причины, раздел скрыт; ошибка или таймаут — «brew не ответил», раздел виден.
- **«Больше не нужна»** — как `brew autoremove`: замыкание `runtime_dependencies` текущих версий от формул с `installed_on_request`, от `depends_on.formula` cask и от формул, собранных из исходников (`poured_from_bottle == false`), вместе с их `build_dependencies`. Имена зависимостей сверяются и с `aliases` / `oldnames`. Подпись нужной зависимости — кто её держит: «нужен — node, php и ещё 3».
- **Удаление Homebrew.** Отметки связаны по формуле: `brew uninstall --force` удаляет все версии формулы, `brew cleanup <формула>` — все её чистимые версии, поэтому отметить можно только группу целиком. Ненужная формула, закреплённая (`brew pin`) или с `.keepme` в какой-либо версии, не удаляется и мусором не помечается: `brew uninstall` сам `.keepme` не проверяет, а с `--force` молча снимает закрепление. Закрепление после скана ловит `ManagerRemover`. Неотмечаемые старые версии — ждёт обновления, `.keepme`, не старше свежей — у формулы с `cleanup` остаются только поиском; если `brew cleanup --dry-run` всё же захватил бы их, удаление отклоняется.
- **Старые версии** — как `brew cleanup` (`eligible_kegs_for_cleanup`): отмечается версия, которая не подключена и старше свежей версии формулы (`versions.stable` + `_revision`), и только если свежая установлена. Не отмечаются: формула ждёт обновления, `pinned`, `.keepme`, версия не старше свежей — например, подключена старая, а новая просто лежит рядом. Причина — в подписи. Сравнение версий — по числам: `1.5.7` < `1.5.7_1`.
- **Android.** Использование образа — по `image.sysdir.1` из `config.ini` эмуляторов (`AndroidEmulators`). Папки эмуляторов нет — эмуляторов нет, все образы не нужны; папка есть, но не читается — образы не отмечаются. `licenses` не показывается.
  - Удаление — папкой пакета, как Android Studio: она и старый `sdkmanager` находят пакеты обходом папок по `package.xml`. `sdkmanager` из cmdline-tools 23.0 — обёртка над новым Android CLI, который при первом запуске может скачать себя; поэтому приложение его не зовёт. У Android CLI своя запись о пакетах в `<sdk>/.sdk` — как он отнесётся к удалённой вручную папке, не проверено.
  - Эмулятор удаляется сам, без `avdmanager`: тому нужна Java, и ни он, ни Android Studio не проверяют, запущен ли эмулятор. Запущен — пока в папке `.avd` есть `hardware-qemu.ini.lock` или `userdata-qemu.img.lock` с живым PID, а `multiinstance.lock` занят `flock`; проба — исключительной блокировкой без ожидания. Поведение `multiinstance.lock` проверено только опытом на Mac пользователя, в документации его нет.
  - Эмуляторы — `.avd` в `~/.android/avd` и папки из `path=` в `<имя>.ini`; вне `~/.android/avd` — только поиск. Путь образа — от `system-images/` в `image.sysdir.1`, бывает и абсолютным. Образ хоть одного эмулятора не определить — образы не помечаются «не нужен», и `Cleaner` их не удаляет. `ANDROID_AVD_HOME` приложение из Finder не видит.
- **Программы.** Папка команд бывает ссылкой (dotfiles) — читается то, на что она ведёт. Битая ли ссылка, решает система: `fileExists` по самой ссылке, `..` разбирается от реальной папки. Команда-ссылка, ведущая в показанный Python, глобальный npm-пакет или в `Cellar` / `Caskroom` / `opt` Homebrew, отдельным элементом не показывается. `npm` и `corepack` в настоящем префиксе Homebrew ставит формула node — они не показываются; в `/usr/local` на Apple Silicon это установщик Node.js — показываются. Пути сравниваются через `canonicalPath`: симлинки разрешены в существующей части пути — `/var` и `/private/var`, относительные ссылки и битые ссылки дают одну форму. Обычный файл подписан по первой строке: «скрипт php», «скрипт системного Ruby (гем)», «программа».
- **Службы.** Программа — `Program` или первый из `ProgramArguments` (`TerminalScanner.service(at:)`, общее для скана и перепроверки). Команда без абсолютного пути (`sh`) считается существующей; «удалена» — только `ENOENT`, закрытая правами папка — нет. Метка — ключ `Label`, имя файла с ней не обязано совпадать.
- **Битая ссылка** — `TerminalScanner.isBrokenLink`: цели нет по `ENOENT`; ссылка на `/Volumes/…` не битая — диск подключат снова.
- **Версии языков.** Активная по настройкам менеджера:
  - nvm — `alias/default`, точное совпадение или самая свежая с этим префиксом, `lts/*` не разрешается;
  - fnm — симлинк `aliases/default` ведёт в `<версия>/installation`, папки — `~/.local/share/fnm` и старая `Library/Application Support/fnm`;
  - Volta — `tools/user/platform.json`;
  - pyenv — все версии файла `version`: `pyenv global 3.12 3.11` пишет несколько, `#` — комментарий; плюс `~/.python-version`: pyenv ищет его от текущей папки вверх, поэтому он действует во всей домашней папке;
  - rbenv — файл `version` и `~/.ruby-version`;
  - rustup — `default_toolchain` и тулчейны `rustup override set` из `settings.toml`: у них ключ — путь папки в кавычках;
  - SDKMAN — симлинк `current`;
  - asdf — `~/.asdf/installs/<плагин>/<версия>`, активны **все** версии строки `~/.tool-versions`: первая основная, остальные запасные; `ref:x` — папка `ref-x`;
  - mise — `~/.local/share/mise/installs/<инструмент>/<версия>`; конфиги складываются по иерархии папок, поэтому активны версии из `[tools]` **всех** конфигов, действующих во всей домашней папке: глобального `~/.config/mise/config.toml`, его `config.local.toml` и фрагментов `conf.d`, `mise.toml` и `.mise.toml` самой домашней папки, плюс `~/.tool-versions`.
- **Сведение активной версии к папкам** — `VersionManager.activeVersions(home:in:)`, одно для скана и для перепроверки в `Cleaner`:
  - точное имя папки;
  - ссылка-псевдоним — папка, в которую ведёт: `22` у mise, окружение pyenv-virtualenv — версия, внутри которой оно лежит; ссылка наружу — ни одна папка;
  - префикс по правилу `pyenv latest` — `<префикс>.` или `<префикс>-`: активны все версии с ним, например `3.12` или `stable`;
  - `system` — версия вне менеджера, папки нет;
  - запись, не нашедшая ни одной папки, — активная не определена: мусором ничего не помечается, `Cleaner` не удаляет ни одну версию этого менеджера.
  - Учитываются глобальные настройки и файлы самой домашней папки: версия из `.python-version`, `.nvmrc` или `rust-toolchain.toml` проекта для приложения не активна.
  - Ссылки в папке версий — псевдонимы, а не версии: `current` у SDKMAN, `22` у mise, `rustup toolchain link` — не показываются.
- **Bun.** Кэш `~/.bun/install/cache` удаляется, кроме `links`: это глобальное хранилище при `install.globalStore`, на него ссылаются `node_modules` проектов. `links` не показывает сканер (`Cache.keeps`, `isExcluded`) и не пропускает `SafetyGuard` (`keptFolders`) — две защиты. Рядом не удаляются `~/.bun/bin`, `~/.bun/install/global`, `~/.bunfig.toml`.
- **Docker.** Только при установленном Docker Desktop. Диск разобран по `docker system df` на строки, которые вместе дают его размер, — двойного счёта нет:
  - «Остановленные контейнеры», «Неиспользуемые образы», «Кэш сборки» — оценка Docker в десятичных единицах; удаляются `docker container prune -f`, `docker image prune -a -f`, `docker builder prune -a -f`. `-a` — именно эти образы и кэш Docker считает освобождаемыми;
  - и скан, и удаление — с `--host unix://~/.docker/run/docker.sock`: сокет Docker Desktop по документации; текущий контекст мог указывать на другой движок;
  - «Остальное на диске Docker» — диск минус строки выше, не меньше нуля: тома, всё в работе, служебное место; только поиск. Тома без контейнеров — подписью: там бывают данные, их удаляют сами;
  - строки — адрес `Docker.raw` с якорем (`#images`): у каждой свой идентификатор, «Показать в Finder» ведёт к диску.
  - Демон не запущен — один диск только поиском, подпись «запустите и пересканируйте»; диска нет — «нет данных»; Docker Desktop удалён — раздел скрыт, диск показывают «Остатки удалённых программ». Место после `prune` macOS получает обратно через несколько минут.
- **conda.** Окружения считаются первыми, кэш `pkgs` — без файлов, общих с окружениями жёсткими ссылками: столько и освободит `conda clean --all`. Системные `/opt` и `Caskroom` удаляет только сама conda — без прав администратора она откажет.
  - Окружение — `<база>/bin/conda remove -p <путь> --all -y`: запускает скрипты пакетов и убирает путь из `~/.conda/environments.txt`; base и активное окружение conda не удаляет сама. Для `~/.conda/envs` — conda первой найденной базы.
  - Кэш — `conda clean --all -y`: он чистит все кэши этой conda, поэтому кэш базы и `~/.conda/pkgs` отмечаются вместе. При нескольких базах с conda `~/.conda/pkgs` — только поиск: его чистит любая из них. `pkgs_dirs` из `.condarc` не учитываются. Папку `pkgs` целиком не удаляем: сломались бы окружения на симлинках.
  - Активное окружение conda знает только по `CONDA_PREFIX` своего процесса: окружение, открытое в терминале, приложение из Finder удалить может — сами разделы ничего не отмечают.
- **MacPorts.** Архив неактивной версии — по префиксу `<порт>-<версия>.`: точка нужна, иначе `1.0_1` совпал бы с `1.0_10`. Пусто или ошибка `port` по коду выхода не различить — неактивные версии тогда не показываются.
  - Удаление — `port -N uninstall <порт> @<версия>`. `port reclaim` приложение не запускает: без терминала он молча соглашается удалить и unrequested-порты, и все папки сборки. Папки сборки и исходники — `sudo port reclaim` вручную. MacPorts у пользователя не установлен — проверено только тестами.
- **Ollama.** Имя как в `ollama list`: у стандартного реестра без хоста, `library` — без пространства, чужой реестр — с хостом. Новая раскладка важнее старой, но битая ссылка v2 откатывается на старый манифест; список манифестов (manifest list) без слоёв пропускается. Общие блобы считаются один раз.
  - Удаление — `DELETE /api/delete` к `127.0.0.1:11434` через системный `curl`: сервер удаляет манифест и блобы, не нужные другим моделям. Не `ollama rm`: при выключенном сервере CLI может сам запустить Ollama.app. Удалять файлы модели вручную нельзя — слои общие.

## Нюансы

- Разведка 2026-10-12 на Mac пользователя: результат совпал с `brew autoremove --dry-run` (0 формул) и `brew cleanup --dry-run` (16 версий). Docker и Parallels удалены, но оставили 15 битых ссылок в `/usr/local/bin` и 2 службы в `/Library/LaunchDaemons`.
- `CACHEDIR.TAG` — служебная метка кэша, исключена во всех категориях.
- `~/.pub-cache/bin` и `global_packages` не трогаются: там глобально активированные Dart-утилиты, а не кэш.
- **Не только кэш — сами не отмечаются** (`CleanupCategory.rootWarning(forRootNamed:)`, решение пользователя по ревью): `~/.m2/repository` — сборки из `mvn install`, которых нет в репозиториях; `~/.cache` — общая папка программ, у Hugging Face там токен и модели; `~/.pub-cache/hosted` и `git` — на них ссылаются глобальные утилиты Dart. Удалить их можно, но только отметив вручную.
- Данные удалённых приложений — например, Docker в `~/Library/Containers` — не про Терминал: их показывают «Остатки удалённых программ».
- Пути инструментов сверены по документации и исходникам 2026-10-12 — Bun, asdf 0.16, mise, Ollama 0.40, conda, Docker Desktop, MacPorts; источники — `flow/plans/terminal-dynamic-tools.md`. Переменные окружения (`BUN_INSTALL_CACHE_DIR`, `ASDF_DATA_DIR`, `MISE_DATA_DIR`, `OLLAMA_MODELS`, `XDG_*`) не учитываются: приложение из Finder их не видит.
- Форматы pyenv — несколько версий и префиксы `^<префикс>[-.]`, хранение override в настройках rustup и иерархия конфигов mise сверены по документации 2026-10-13. По исходникам Homebrew: `--force` не проверяет закрепление (`uninstall.rb`), `.keepme` учитывает только `cleanup` (`formula.rb`), `bin/brew` пропускает переменные `HOMEBREW_*` через фильтр окружения.
- `brew cleanup --dry-run` холостой не полностью: удаляет `.DS_Store` в папке формулы и служебные кэши brew. Данных пользователя там нет.
- 2026-10-13 холостой `brew cleanup --dry-run <формула>` на Mac пользователя совпал с отметками сканера по всем 14 формулам, 16 версий.
- Не проверено вживую — у пользователя этих инструментов нет: TCC для контейнера Docker, `port installed inactive` при отсутствии неактивных версий, формат manifest list Ollama, `docker system df` при другом context.

## Кодовые якоря (индекс)

- Код: `ToolCatalog`, `caches`, `versionManagers`, `keptFolders(home:)`, `cache(forRootNamed:)`, `docker(home:system:runner:)`, `dockerReclaimable(_:)`, `conda(home:system:)`, `macPorts(system:runner:)`, `inactivePorts(_:)`, `ollama(home:)`, `visibleCategories(in:)`, `hidesEmptySections`, `android(home:)`, `homebrew(prefix:runner:)`, `recommendingOlderGradleDistributions(_:)`, `programs(home:system:)`, `services(home:system:)`, `languageVersions(home:)`, `requiredFormulae(_:casks:)`, `users(_:casks:required:)`, `isCleanable(_:)`, `isLatestInstalled`, `isOlder(_:than:)`, `infoArguments`, `recommendingAllButNewest(_:groupedBy:newestNote:)`, `version(in:)`, `homebrewPrefix`, `canonicalPath(_:)`, `commandItem(_:label:ownedPrefixes:applications:)`, `fileKind(_:)`, `VersionManager`, `activeVersions(home:in:)`, `listedVersions`, `installedVersions(in:)`, `activity(ofVersionAt:home:)`, `VersionActivity`, `AndroidEmulators`, `usedImages(in:)`, `isRunning(_:)`, `imagePath(of:)`, `dockerCLI(home:system:)`, `dockerPart(_:_:)`, `dockerBytes(_:)`, `isSearchOnly`, `searchOnly()`, `service(at:)`, `Service`, `brewFailedReason`, `dockerDiskMissingReason`, `rootWarning(forRootNamed:)`
- Формулировки поиска: «раздела нет», «пустой раздел», «у другого пользователя другие инструменты», «битая ссылка», «программа удалена», «старая версия brew», «зависимость не нужна», «образ эмулятора», «активная версия», «ждёт обновления»

### Ключевые файлы

- /Trash/Services/TerminalScanner.swift (service — Поиск Терминала)
- /Trash/Services/ToolCatalog.swift (service — Каталог инструментов)
- /Trash/Services/HomebrewCatalog.swift (service — Homebrew)
- /Trash/Services/VersionPolicy.swift (service — Правило свежей версии)
- /Trash/Services/SystemLocations.swift (service — Системные папки)
- /Trash/Services/AndroidEmulators.swift (service — Эмуляторы Android)
- /TrashTests/TerminalScannerTests.swift (tests — Поиск Терминала)
