# «Терминал» по найденному: скрытие пустых разделов, каталог инструментов, новые инструменты

## Метаданные

- Дата: 2026-10-12
- Модуль: `terminal`; смежные — `scanning` (категории и корни), `cleanup` (контракт), `main-window` (скрытие разделов)
- Статус: выполнен; ревью — High (вторая защита `links` у Bun) и Medium закрыты

## DoD

- В «Терминале» видно только то, что есть на этом Mac: раздел скрыт, если инструмента нет или ничего не найдено без ошибки; «нет данных» с причиной и замок остаются; во время скана видно всё.
- `ToolCatalog` — одно место для кэшей менеджеров пакетов и менеджеров версий.
- Новые инструменты: кэш Bun (удаляемый), asdf и mise (версии), Docker, conda, MacPorts, Ollama — разделы только поиска.
- Тесты во временных папках; `make build`, `make test` проходят; прогон на диске пользователя только на чтение.

## Этапы

1. Сверка путей и команд по документации — ниже, раздел «Сверка».
2. Скрытие пустых разделов.
3. `ToolCatalog`: кэши и менеджеры версий.
4. Новые инструменты.
5. Тесты.
6. Проверка: сборка, тесты, ревью, прогон на чтение, `make run`.
7. Документация и история.

## Ограничения из истории

- `~/.m2/repository`, `~/.cache`, `~/.pub-cache/hosted|git` — не отмечаются сами, предупреждение в подписи.
- Системные папки вне `~` корнями удаления не становятся; тест «все корни внутри дома».
- Рядом с удаляемыми кэшами настройки и утилиты не удаляются — для Bun запрещающий тест.
- Скрытие отличает «ничего не найдено» от «нет данных / ошибки».
- Docker удалён — ничего не показываем; установлен, но не запущен — раздел с причиной.

## Сверка — документация и исходники, 2026-10-12

| Инструмент | Что подтверждено | Источник |
|---|---|---|
| Bun | кэш `~/.bun/install/cache`; `links/` — глобальное хранилище при `install.globalStore`, `node_modules/.bun/*` ссылаются туда; `~/.bun/bin`, `~/.bun/install/global` — не кэш; глобальный `bunfig` — `~/.bunfig.toml` | bun.com/docs/pm/global-cache, /pm/global-store, /runtime/bunfig; oven-sh/bun `PackageManagerDirectories` |
| asdf | `~/.asdf/installs/<plugin>/<version>` и в 0.16 на Go; `~/.tool-versions`: `<tool> <версия> [<версия>…]`, остальные — запасные; `ref:x` → `ref-x` | asdf-vm.com/manage/versions, upgrading-to-v0-16; asdf `internal/data`, `internal/toolversions` |
| mise | `~/.local/share/mise/installs/<tool>/<version>`, ссылки-псевдонимы префиксов; `[tools]` в `~/.config/mise/config.toml`; `~/.tool-versions` читается | mise.jdx.dev/directories, /configuration |
| Ollama | `~/.ollama/models`, `blobs/sha256-<hex>`; `manifests/<хост>/<пространство>/<модель>/<тег>`, с 0.40 `manifests-v2/…` — ссылка на блоб; размер = `config` + `layers` | ollama `manifest/paths.go`, `manifest.go` |
| conda | `~/miniconda3`, `~/anaconda3`, `/opt/miniconda3`, `/opt/anaconda3`, `~/miniforge3`, Caskroom `…/base`, `~/micromamba`; `envs`, `pkgs`, `~/.conda/envs`, `~/.conda/pkgs` | anaconda.com docs; conda `base/context.py`; homebrew-cask |
| Docker | `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`; CLI `/usr/local/bin`, `~/.docker/bin`, `Docker.app/Contents/Resources/bin`; `docker system df --format json`: `Type`, `Reclaimable` строками | docs.docker.com mac FAQ, settings; docker/cli `disk_usage.go` |
| MacPorts | `/opt/local`; `var/macports/software`, `build`, `distfiles`; `port installed inactive`: «  имя @версия_ревизия+варианты», без `(active)` | guide.macports.org; macports-base `port.tcl`, `reclaim.tcl` |

Не подтверждено: явное «кэш Bun удалять безопасно»; путь Miniforge `.pkg`; путь `Docker.app/.../bin/docker` в документации самого Docker.

## Дальше по очереди — по просьбе пользователя

1. Удаление разделов «только поиск» через их менеджеры — отдельная задача `/dev:code`: начать с рантаймов и симуляторов (`simctl`), затем Homebrew, Android, версии языков; ссылки и службы — с паролем администратора.
2. Чистилка «остальных данных» — отдельная задача `/dev:code`. Разведка 2026-10-12, только чтение:
   - `/Library/Developer/CoreSimulator`: `Caches` 25,6 ГБ — кэши dyld симуляторов; `Cryptex` 17,6 ГБ, `Images` 13,6 ГБ, `Profiles` 12,4 ГБ — файлы рантаймов; `Volumes` в `du` — смонтированные образы, двойной счёт;
   - тома: Preboot 21,7 ГБ, в нём подготовленное обновление macOS; VM 7,5 ГБ; System 14,1 ГБ; Recovery 3,1 ГБ;
   - дом без `~/Library` — около 65 ГБ: `Desktop` 33 ГБ, `development` 11,9 ГБ, `.claude` 5 ГБ, `Downloads` 4,9 ГБ;
   - `~/Library`: `Developer` 162 ГБ — почти всё уже в разделе Xcode; `Application Support` 21,7 ГБ — не разобрано; `Containers` 8 ГБ — остатки и данные установленных программ; `Android` 7,1 ГБ, `Caches` 3,6 ГБ — уже в разделах.
