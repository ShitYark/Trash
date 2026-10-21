# Чистилка «остальных данных»

## Метаданные

- Дата: 2026-10-13
- Модули: `scanning`, `xcode`, `cleanup`, `main-window`
- Статус: готово 2026-10-13. Ревью — 2 Medium, 8 Low — исправлены, кроме двух Low, записанных в доку `xcode.md`; тесты 137/137, мутации ловятся; на диске пользователя только чтением: 8 кэшей dyld на 25,6 ГБ, мусор 3,4 ГБ; 93 кэша программ на 4,4 ГБ; 3 установщика; `lsof` видит запущенный Claude.

## Разведка 2026-10-13, только чтение

- `/Library/Developer/CoreSimulator/Caches/dyld/<сборка macOS>/<runtimeIdentifier>.<build>` — 24 ГБ, кэши 8 рантаймов; iOS 15.5 и 16.0 — 3,2 ГБ — эта macOS не поддерживает, их кэш больше не собирается. Остальные CoreSimulator создаёт заново при старте службы.
- Chromium-кэши внутри `~/Library/Application Support` — 5,1 ГБ: Slack, Claude, Windsurf, Figma, VS Code, Яндекс Музыка.
- Не чистим: `Claude/vm_bundles` 10 ГБ — данные; Preboot около 21,7 ГБ — подготовленное обновление macOS; `~/Library/Containers` — запрос доступа к данным других программ; `/var/folders`.

## DoD

- Xcode → «Общие кэши симуляторов»: строка на рантайм; удаляет `simctl runtime dyld_shared_cache remove <runtimeIdentifier>/<build>`, сразу и без Корзины; мусор — кэши рантаймов, которые macOS не поддерживает; у остальных подпись «создастся заново»; симулятор этого рантайма запущен — отказ; папка без рантайма — только поиск.
- Система → «Кэши в данных программ»: `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnWebGPUCache`, `DawnGraphiteCache`, `ShaderCache`, `GrShaderCache`, `GraphiteDawnCache`, `GPUPersistentCache`, у VS Code — `CachedData`, `CachedExtensionVSIXs`, `CachedProfilesData`; только рядом с `Local State` или `Preferences` — признаком профиля Chromium; файлами по режиму; какой-то процесс держит файлы в папке программы — отказ.
- Система → «Установщики в Загрузках»: `.dmg`, `.pkg`, `.xip` прямо в `~/Downloads`, по режиму; мусором не помечаются — образ диска бывает и вашим.
- Сами не отмечаются; тексты окна очистки — для новых путей.

## Решения

- Корней в `/Library` нет: кэши dyld читает сканер, удаляет `simctl` — как рантаймы.
- `Service Worker` не трогаем: Chromium относит `CacheStorage` к данным сайтов, `ScriptCache` — только вместе с базой.
- Запущенность — по открытым файлам (`lsof +D`), а не по имени: имя папки и программы совпадают не всегда.
