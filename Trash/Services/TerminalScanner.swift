import Foundation

/// Поиск того, что поставлено через терминал и не видно в Программах: Android SDK, Homebrew, Gradle,
/// программы мимо Homebrew, фоновые службы, версии языков. Только читает диск и вывод `brew`.
enum TerminalScanner {
    static let brewFailedReason = "brew не ответил — пересканируйте позже."

    // MARK: - Android SDK

    /// Компоненты SDK и эмуляторы. Образ системы отмечается, если его не использует ни один эмулятор;
    /// build-tools и NDK — все версии, кроме самой свежей. Список эмуляторов не прочитан — образы не отмечаются.
    static func android(home: URL) -> CategoryScanResult {
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let avdDirectory = home.appending(path: ".android/avd", directoryHint: .isDirectory)
        var isAccessDenied = false

        let avds = AndroidEmulators.read(in: avdDirectory, accessDenied: &isAccessDenied)
        // Образ хоть одного эмулятора неизвестен — «не нужен» никому не пишем.
        let imageUsage = avds.flatMap { avds in
            avds.allSatisfy(\.isImageKnown) ? Dictionary(grouping: avds.compactMap(\.imagePath), by: { $0 }).mapValues(\.count) : nil
        }

        var items: [ScanItem] = []
        if case let .children(components) = CleanupScanner.list(sdk, accessDenied: &isAccessDenied) {
            for component in components where !component.lastPathComponent.hasPrefix(".") {
                guard !Task.isCancelled else { break }
                switch component.lastPathComponent {
                case "system-images":
                    items += systemImageItems(in: component, usage: imageUsage, accessDenied: &isAccessDenied)
                case "build-tools", "ndk":
                    items += versionedSDKItems(in: component, kind: component.lastPathComponent, accessDenied: &isAccessDenied)
                case "platforms":
                    items += sdkChildren(of: component, accessDenied: &isAccessDenied).map { platform in
                        let level = platform.lastPathComponent.replacingOccurrences(of: "android-", with: "")
                        return ScanItem(url: platform, size: CleanupScanner.allocatedSize(of: platform), category: .androidSDK,
                                        title: "Платформа Android \(level)", details: "нужна для сборки под эту версию")
                    }
                case "licenses":
                    continue
                default:
                    // Эмулятор, platform-tools, cmdline-tools — инструменты, а не мусор.
                    items.append(ScanItem(url: component, size: CleanupScanner.allocatedSize(of: component), category: .androidSDK,
                                          details: "компонент SDK", isSearchOnly: true))
                }
            }
        }

        let avdFolder = avdDirectory.canonicalFileURL.path
        items += (avds ?? []).map { avd in
            // Эмулятор вне `~/.android/avd` — по `path=` в его `.ini` — только поиск: удаляем лишь свои папки.
            let isOutside = avd.url.deletingLastPathComponent().canonicalFileURL.path != avdFolder
            return ScanItem(url: avd.url, size: CleanupScanner.allocatedSize(of: avd.url), category: .androidSDK, title: avd.name,
                            details: ["эмулятор", avd.imagePath.map(imageTitle), isOutside ? "лежит вне ~/.android/avd" : nil]
                                .compactMap { $0 }.joined(separator: " · "),
                            isSearchOnly: isOutside)
        }
        return CategoryScanResult(category: .androidSDK, items: items, isAccessDenied: isAccessDenied)
    }

    // MARK: - Homebrew

    /// Формулы по `brew info`: текущая версия, старые версии, зависимости, которые больше не нужны, и cask.
    static func homebrew(prefix: URL?, runner: CommandRunner) async -> CategoryScanResult {
        // Homebrew нет — раздел пустой без причины и в «Терминале» скрывается: показывать «не установлен» незачем.
        guard let prefix else {
            return CategoryScanResult(category: .homebrew, items: [], isAccessDenied: false)
        }
        let brew = prefix.appending(path: "bin/brew").path
        guard let data = try? await runner.run(brew, HomebrewCatalog.infoArguments),
              let catalog = try? HomebrewCatalog.parse(data) else {
            return CategoryScanResult(category: .homebrew, items: [], isAccessDenied: false, unavailableReason: brewFailedReason)
        }
        let (formulae, casks) = catalog

        let cellar = prefix.appending(path: "Cellar", directoryHint: .isDirectory)
        let required = HomebrewCatalog.requiredFormulae(formulae, casks: casks)
        let users = HomebrewCatalog.users(formulae, casks: casks, required: required)
        var items: [ScanItem] = []

        for formula in formulae {
            guard !Task.isCancelled else { break }
            let folder = cellar.appending(path: formula.name, directoryHint: .isDirectory)
            let isUnneeded = formula.currentVersion != nil && !formula.isOnRequest && !required.contains(formula.fullName)
            // Закреплённую (`brew pin`) держат сознательно, а `.keepme` в версии значит «нужна другой программе» —
            // такую не удаляем и мусором не помечаем: `brew uninstall` сам `.keepme` не проверяет.
            let hasKeepme = formula.installed.contains {
                FileManager.default.fileExists(atPath: folder.appending(path: $0.version).appending(path: ".keepme").path)
            }
            let keptNote: String? = if formula.isPinned { "закреплена (brew pin)" } else if hasKeepme { "помечена .keepme — нужна другой программе" } else { nil }
            let isUninstallable = isUnneeded && keptNote == nil
            if let current = formula.currentVersion {
                let role = if formula.isOnRequest {
                    "поставлен явно"
                } else if isUnneeded {
                    keptNote.map { "зависимость, больше ничему не нужна, но \($0)" } ?? "зависимость, больше ничему не нужна"
                } else if formula.isBuiltFromSource {
                    "собран из исходников"
                } else {
                    "зависимость: нужен — \(listed(users[formula.fullName] ?? []))"
                }
                let url = folder.appending(path: current, directoryHint: .isDirectory)
                // Ненужная зависимость удаляется целиком — `brew uninstall`; явно поставленное и нужное — только поиск.
                items.append(ScanItem(url: url, size: CleanupScanner.allocatedSize(of: url), category: .homebrew, title: formula.name,
                                      details: [current, role, formula.summary].compactMap { $0 }.joined(separator: " · "),
                                      isRecommended: isUninstallable, removal: isUninstallable ? .brewUninstall(formula: formula.name) : nil))
            }
            for version in formula.installed.map(\.version) where version != formula.currentVersion {
                let url = folder.appending(path: version, directoryHint: .isDirectory)
                // Как `brew cleanup`: ждёт обновления, закреплена, `.keepme` или не старше свежей — не чистится.
                let keptBecause: String? = if !formula.isLatestInstalled {
                    "пакет ждёт обновления до \(formula.latestVersion ?? "новой версии") — brew пока её не чистит"
                } else if formula.isPinned {
                    "версии закреплены (brew pin)"
                } else if FileManager.default.fileExists(atPath: url.appending(path: ".keepme").path) {
                    "помечена .keepme — нужна другой программе"
                } else if !formula.isCleanable(version) {
                    "не старше свежей версии — brew её не чистит"
                } else {
                    nil
                }
                let current = formula.currentVersion ?? version
                let relation = HomebrewCatalog.isOlder(version, than: current) ? "старая версия" : "другая версия"
                let details = ["\(relation), текущая — \(current)", keptBecause].compactMap { $0 }.joined(separator: " · ")
                // Старые версии удаляет `brew cleanup` — все чистимые версии формулы разом; у ненужной формулы — вместе с ней.
                let removal: ManagerRemoval? = if isUninstallable {
                    .brewUninstall(formula: formula.name)
                } else if keptBecause == nil {
                    .brewCleanup(formula: formula.name)
                } else {
                    nil
                }
                items.append(ScanItem(url: url, size: CleanupScanner.allocatedSize(of: url), category: .homebrew,
                                      title: "\(formula.name) \(version)", details: details, isRecommended: keptBecause == nil,
                                      removal: removal))
            }
        }

        let caskroom = prefix.appending(path: "Caskroom", directoryHint: .isDirectory)
        items += casks.map { cask in
            let url = caskroom.appending(path: cask.token, directoryHint: .isDirectory)
            return ScanItem(url: url, size: CleanupScanner.allocatedSize(of: url), category: .homebrew, title: cask.token,
                            details: ["cask", cask.version, cask.summary].compactMap { $0 }.joined(separator: " · "))
        }
        return CategoryScanResult(category: .homebrew, items: items, isAccessDenied: false)
    }

    // MARK: - Gradle

    /// Дистрибутивы Gradle — все, кроме самой свежей версии; кэш и логи демона — по умолчанию категории.
    static func recommendingOlderGradleDistributions(_ items: [ScanItem]) -> [ScanItem] {
        let isDistribution = { (item: ScanItem) in item.url.deletingLastPathComponent().lastPathComponent == "dists" }
        let distributions = VersionPolicy.recommendingAllButNewest(items.filter(isDistribution), groupedBy: { _ in "dists" })
        return items.filter { !isDistribution($0) } + distributions
    }

    // MARK: - Programs

    /// Программы мимо Homebrew: Python с python.org, глобальные npm-пакеты, команды в `/usr/local/bin`,
    /// `~/.local/bin`, `~/.cargo/bin`, `~/go/bin`, pipx. Отмечены ссылки на уже удалённые программы.
    static func programs(home: URL, system: SystemLocations) -> CategoryScanResult {
        var isAccessDenied = false
        var items: [ScanItem] = []

        let pythonVersions = system.library.appending(path: "Frameworks/Python.framework/Versions", directoryHint: .isDirectory)
        if case let .children(versions) = CleanupScanner.list(pythonVersions, accessDenied: &isAccessDenied) {
            for version in versions where version.lastPathComponent != "Current" && !isSymlink(version) {
                items.append(ScanItem(url: version, size: CleanupScanner.allocatedSize(of: version), category: .terminalPrograms,
                                      title: "Python \(version.lastPathComponent)", details: "установщик python.org · /Library/Frameworks"))
            }
        }

        let npmPrefixes = ([system.usrLocal] + system.homebrewPrefixes).uniqued(by: \.standardizedFileURL.path)
        // Только настоящий префикс, где есть `bin/brew`: `/usr/local` на Apple Silicon — место установщика Node.js, а не Homebrew.
        let homebrewPath = system.homebrewPrefix?.standardizedFileURL.path
        for prefix in npmPrefixes {
            let packages = globalNPMPackages(in: prefix.appending(path: "lib/node_modules", directoryHint: .isDirectory), accessDenied: &isAccessDenied)
            let bundledWithNode: Set<String> = prefix.standardizedFileURL.path == homebrewPath ? ["npm", "corepack"] : []
            items += packages.filter { !bundledWithNode.contains($0.url.lastPathComponent) }
        }

        // Команды, которые принадлежат уже показанному выше или Homebrew, отдельными элементами не дублируются.
        // Пути сравниваются после разрешения симлинков: `/var` и `/private/var` — одна папка.
        let ownedFolders = [pythonVersions] + npmPrefixes.map { $0.appending(path: "lib/node_modules") }
            + system.homebrewPrefixes.flatMap { prefix in ["Cellar", "Caskroom", "opt"].map { prefix.appending(path: $0) } }
        let ownedPrefixes = ownedFolders.map { $0.canonicalFileURL.path + "/" }
        let commandFolders = [(system.usrLocal.appending(path: "bin", directoryHint: .isDirectory), "/usr/local/bin")]
            + [".local/bin", ".cargo/bin", "go/bin"].map { (home.appending(path: $0, directoryHint: .isDirectory), "~/\($0)") }
        for (folder, label) in commandFolders {
            // Папка команд бывает ссылкой (dotfiles): читаем то, на что она ведёт.
            guard case let .children(commands) = CleanupScanner.list(folder.resolvingSymlinksInPath(), accessDenied: &isAccessDenied) else { continue }
            for command in commands where !command.lastPathComponent.hasPrefix(".") {
                if let item = commandItem(command, label: label, ownedPrefixes: ownedPrefixes, applications: system.applications) {
                    items.append(item)
                }
            }
        }

        for venvs in ["~/.local/pipx/venvs", "~/.local/share/pipx/venvs"] {
            let folder = home.appending(path: String(venvs.dropFirst(2)), directoryHint: .isDirectory)
            guard case let .children(packages) = CleanupScanner.list(folder, accessDenied: &isAccessDenied) else { continue }
            items += packages.map {
                ScanItem(url: $0, size: CleanupScanner.allocatedSize(of: $0), category: .terminalPrograms, details: "pipx · \(venvs)")
            }
        }
        // Удаляются только битые ссылки — помеченные мусором; программы, пакеты и рабочие команды — только поиск.
        items = items.map { $0.isRecommended ? $0 : $0.searchOnly() }
        return CategoryScanResult(category: .terminalPrograms, items: items, isAccessDenied: isAccessDenied)
    }

    // MARK: - Background services

    /// Агенты и службы `launchd`. Отмечены те, чья программа уже удалена.
    static func services(home: URL, system: SystemLocations) -> CategoryScanResult {
        let folders = [
            (home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory), "агент пользователя"),
            (system.library.appending(path: "LaunchAgents", directoryHint: .isDirectory), "агент для всех пользователей"),
            (system.library.appending(path: "LaunchDaemons", directoryHint: .isDirectory), "системная служба"),
        ]
        var isAccessDenied = false
        var items: [ScanItem] = []

        for (folder, kind) in folders {
            guard case let .children(plists) = CleanupScanner.list(folder, accessDenied: &isAccessDenied) else { continue }
            for plist in plists where plist.pathExtension == "plist" {
                let service = service(at: plist)
                let program = service.program
                let isMissing = service.isProgramMissing
                let details = [kind, program.map { isMissing ? "программа удалена: \($0)" : $0 }].compactMap { $0 }.joined(separator: " · ")
                // Удаляются только службы с удалённой программой; работающие — только поиск.
                items.append(ScanItem(url: plist, size: CleanupScanner.allocatedSize(of: plist), category: .backgroundServices,
                                      title: service.label ?? plist.deletingPathExtension().lastPathComponent,
                                      details: details, isRecommended: isMissing, isSearchOnly: !isMissing))
            }
        }
        return CategoryScanResult(category: .backgroundServices, items: items, isAccessDenied: isAccessDenied)
    }

    /// Метка и программа службы из её plist — для скана и для перепроверки перед удалением.
    struct Service {
        let label: String?
        let program: String?

        /// Только абсолютный путь можно проверить; команда вроде `sh` считается существующей. Нет файла — только
        /// `ENOENT`: программа в папке, закрытой правами, — не «удалена».
        var isProgramMissing: Bool {
            program.map { $0.hasPrefix("/") && TerminalScanner.isMissing($0) } ?? false
        }
    }

    /// Битая ссылка: цели нет — `ENOENT`, а не «нет прав». Ссылка на отключённый диск `/Volumes/…` — не битая:
    /// диск подключат снова.
    static func isBrokenLink(_ url: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let target = URL(filePath: destination, relativeTo: url.deletingLastPathComponent()).absoluteURL.standardizedFileURL.path
        return !target.hasPrefix("/Volumes/") && isMissing(url.path)
    }

    /// Пути нет: `stat` с переходом по ссылкам отвечает `ENOENT`.
    static func isMissing(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) != 0 && errno == ENOENT
    }

    static func service(at plist: URL) -> Service {
        let info = propertyList(at: plist)
        let arguments = info?["ProgramArguments"] as? [String]
        return Service(label: info?["Label"] as? String, program: info?["Program"] as? String ?? arguments?.first)
    }

    // MARK: - Language versions

    /// Версии из менеджеров версий. Отмечены все, кроме активной; активную не определить — не отмечается ничего.
    static func languageVersions(home: URL) -> CategoryScanResult {
        var isAccessDenied = false
        var items: [ScanItem] = []

        for manager in ToolCatalog.versionManagers {
            for versionsFolder in manager.versionFolders(home) {
                guard case let .children(versions) = CleanupScanner.list(versionsFolder, accessDenied: &isAccessDenied) else { continue }
                let active = manager.activeVersions(home: home, in: versionsFolder)
                // Ссылки — псевдонимы версий (`current` у SDKMAN, `22` → `22.11.0` у mise), а не отдельные версии.
                for version in versions where !version.lastPathComponent.hasPrefix(".") && !isSymlink(version) {
                    let name = version.lastPathComponent
                    let language = manager.language(versionsFolder)
                    let isActive = active?.contains(name) == true
                    let state = active == nil ? "активная не определена" : (isActive ? "активная" : "не активна")
                    items.append(ScanItem(url: version, size: CleanupScanner.allocatedSize(of: version), category: .languageVersions,
                                          title: "\(language) \(name)", details: "\(manager.name) · \(state)",
                                          isRecommended: active != nil && !isActive))
                }
            }
        }
        return CategoryScanResult(category: .languageVersions, items: items, isAccessDenied: isAccessDenied)
    }

    // MARK: - Docker

    /// Диск Docker Desktop, разобранный по `docker system df`: остановленные контейнеры, неиспользуемые образы и кэш
    /// сборки — строки с операцией `prune`, остальное на диске — строка только поиска. Вместе строки дают размер диска:
    /// всё лежит внутри него, двойного счёта нет. Docker не отвечает — один диск, только поиск.
    static func docker(home: URL, system: SystemLocations, runner: CommandRunner) async -> CategoryScanResult {
        let app = system.applications.appending(path: "Docker.app")
        // Docker Desktop удалён — его диск остался данными удалённой программы, их показывают «Остатки».
        guard FileManager.default.fileExists(atPath: app.path) else {
            return CategoryScanResult(category: .docker, items: [], isAccessDenied: false)
        }
        let disk = home.appending(path: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        do {
            _ = try disk.checkResourceIsReachable()
        } catch {
            let isDenied = (error as? CocoaError)?.code == .fileReadNoPermission
            return CategoryScanResult(category: .docker, items: [], isAccessDenied: isDenied,
                                      unavailableReason: isDenied ? nil : dockerDiskMissingReason)
        }

        let diskSize = CleanupScanner.allocatedSize(of: disk)
        guard let cli = dockerCLI(home: home, system: system),
              let data = try? await runner.run(cli.path, dockerHost(home: home) + ["system", "df", "--format", "json"]) else {
            let item = ScanItem(url: disk, size: diskSize, category: .docker, title: "Диск Docker Desktop",
                                details: "Docker не запущен — запустите его и пересканируйте, чтобы увидеть, что можно освободить",
                                isRecommended: false)
            return CategoryScanResult(category: .docker, items: [item], isAccessDenied: false)
        }

        let reclaimable = dockerReclaimable(data)
        let parts: [(ManagerRemoval.DockerTarget, String, String, String)] = [
            (.containers, "Containers", "Остановленные контейнеры", "docker container prune"),
            (.images, "Images", "Неиспользуемые образы", "образы без контейнеров · docker image prune -a; скачаются или соберутся заново"),
            (.buildCache, "Build Cache", "Кэш сборки", "docker builder prune -a; соберётся заново"),
        ]
        var items = parts.compactMap { target, type, title, details -> ScanItem? in
            guard let size = reclaimable[type], size > 0 else { return nil }
            return ScanItem(url: dockerPart(disk, target), size: size, category: .docker, title: title,
                            details: "оценка docker system df · " + details, isRecommended: false, removal: .dockerPrune(target))
        }
        // Оценки Docker в десятичных единицах и не обязаны сойтись с диском — остаток не меньше нуля.
        let rest = max(0, diskSize - items.reduce(0) { $0 + $1.size })
        let volumes = reclaimable["Local Volumes"].map { $0 > 0 ? " · тома без контейнеров: \($0.formatted(.byteCount(style: .file))) — удаляйте сами, там бывают данные" : "" } ?? ""
        items.append(ScanItem(url: disk, size: rest, category: .docker, title: "Остальное на диске Docker",
                              details: "тома, образы и контейнеры в работе, служебное место" + volumes, isRecommended: false))
        return CategoryScanResult(category: .docker, items: items, isAccessDenied: false)
    }

    /// Всегда движок Docker Desktop, а не текущий контекст: `docker context use` мог указать на сервер, colima
    /// или OrbStack. Сокет Docker Desktop на Mac — `~/.docker/run/docker.sock`.
    static func dockerHost(home: URL) -> [String] {
        ["--host", "unix://" + home.appending(path: ".docker/run/docker.sock").path]
    }

    /// Команда `docker`: из Docker Desktop, ссылка в `/usr/local/bin` или в `~/.docker/bin`.
    static func dockerCLI(home: URL, system: SystemLocations) -> URL? {
        let app = system.applications.appending(path: "Docker.app")
        return [home.appending(path: ".docker/bin/docker"), system.usrLocal.appending(path: "bin/docker"),
                app.appending(path: "Contents/Resources/bin/docker")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Строка внутри диска: адрес диска с якорем — у каждой строки свой идентификатор, «Показать в Finder» ведёт к диску.
    static func dockerPart(_ disk: URL, _ target: ManagerRemoval.DockerTarget) -> URL {
        URL(string: disk.absoluteString + "#" + target.rawValue) ?? disk
    }

    static let dockerDiskMissingReason = "Диск Docker Desktop не найден — его могли перенести в настройках Docker."

    /// Строки `docker system df --format json` — по объекту на строку: тип → сколько можно освободить, в байтах.
    /// Значения вида «1.5GB (71%)».
    static func dockerReclaimable(_ data: Data) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["Type"] as? String, let reclaimable = object["Reclaimable"] as? String,
                  let bytes = dockerBytes(reclaimable) else { continue }
            result[type] = bytes
        }
        return result
    }

    /// «1.5GB (71%)», «300MB», «12kB», «0B» → байты. Docker пишет размеры в десятичных единицах.
    static func dockerBytes(_ text: String) -> Int64? {
        let value = text.split(separator: " ").first.map(String.init) ?? ""
        guard let unitStart = value.firstIndex(where: { $0.isLetter }), let number = Double(value[..<unitStart]) else { return nil }
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12, "pb": 1e15]
        guard let factor = units[value[unitStart...].lowercased()] else { return nil }
        return Int64(number * factor)
    }

    // MARK: - conda

    /// Окружения и кэш пакетов conda, Miniforge, Anaconda и micromamba в местах установки по умолчанию.
    /// Кэш пакетов делит файлы с окружениями жёсткими ссылками — при удалении освободится меньше, поэтому не отмечается.
    static func conda(home: URL, system: SystemLocations) -> CategoryScanResult {
        let candidates = ["miniconda3", "miniforge3", "anaconda3", "micromamba"].map { home.appending(path: $0) }
            + ["miniconda3", "anaconda3"].map { system.opt.appending(path: $0) }
            + system.homebrewPrefixes.flatMap { prefix in
                ["Caskroom/miniforge/base", "Caskroom/miniconda/base", "anaconda3"].map { prefix.appending(path: $0) }
            }
        let bases = candidates.filter { base in
            ["conda-meta", "pkgs", "envs"].contains { isDirectory(base.appending(path: $0)) }
        }
        var isAccessDenied = false
        var items: [ScanItem] = []
        // Окружения считаются первыми, кэш — без файлов, общих с ними: столько и освободит conda clean.
        var countedHardLinks = Set<UInt64>()

        // Удаляет сама conda базы: у micromamba её нет — там только поиск. Для `~/.conda` — conda первой базы.
        let condaOf = { (base: URL) -> String? in
            let conda = base.appending(path: "bin/conda").path
            return FileManager.default.isExecutableFile(atPath: conda) ? conda : nil
        }
        let condas = bases.compactMap(condaOf)
        let anyConda = condas.first
        // `conda clean --all` любой базы чистит и `~/.conda/pkgs`: при нескольких базах отметка не сказала бы правду.
        let homeCacheConda = condas.count == 1 ? anyConda : nil
        let homeConda = home.appending(path: ".conda")

        for (envs, conda) in bases.map({ ($0.appending(path: "envs"), condaOf($0)) }) + [(homeConda.appending(path: "envs"), anyConda)] {
            guard case let .children(environments) = CleanupScanner.list(envs, accessDenied: &isAccessDenied) else { continue }
            for environment in environments where !environment.lastPathComponent.hasPrefix(".") && isDirectory(environment) {
                let removal = conda.map { ManagerRemoval.condaRemoveEnvironment(conda: $0, prefix: environment.path) }
                items.append(ScanItem(url: environment, size: CleanupScanner.allocatedSize(of: environment, countedHardLinks: &countedHardLinks),
                                      category: .conda, title: "Окружение \(environment.lastPathComponent)",
                                      details: environment.path + (removal == nil ? " · удалить нечем: conda не найдена" : " · conda remove --all"),
                                      isRecommended: false, removal: removal))
            }
        }
        for (cache, conda) in bases.map({ ($0.appending(path: "pkgs"), condaOf($0)) }) + [(homeConda.appending(path: "pkgs"), homeCacheConda)]
        where isDirectory(cache) {
            items.append(ScanItem(url: cache, size: CleanupScanner.allocatedSize(of: cache, countedHardLinks: &countedHardLinks),
                                  category: .conda, title: "Кэш пакетов",
                                  details: "\(cache.deletingLastPathComponent().path) · без файлов, общих с окружениями · conda clean --all",
                                  isRecommended: false, removal: conda.map { .condaClean(conda: $0) }))
        }
        return CategoryScanResult(category: .conda, items: items.uniqued(by: \.url.standardizedFileURL.path), isAccessDenied: isAccessDenied)
    }

    // MARK: - MacPorts

    /// То, что удаляет `port reclaim`: неактивные версии портов, папки сборки, скачанные исходники.
    static func macPorts(system: SystemLocations, runner: CommandRunner) async -> CategoryScanResult {
        let port = system.macPortsPrefix.appending(path: "bin/port")
        guard FileManager.default.isExecutableFile(atPath: port.path) else {
            return CategoryScanResult(category: .macPorts, items: [], isAccessDenied: false)
        }
        let macPorts = system.macPortsPrefix.appending(path: "var/macports")
        var items: [ScanItem] = []

        // Пусто или ошибка — неактивных версий не показываем: отличить одно от другого по коду выхода нельзя.
        let output = (try? await runner.run(port.path, ["installed", "inactive"])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for port in inactivePorts(output) {
            let folder = macPorts.appending(path: "software/\(port.name)")
            let archives = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                // С точкой: иначе `1.0_1` совпал бы с `1.0_10`, а `1.0_0` — с `1.0_0+universal`.
                .filter { $0.lastPathComponent.hasPrefix("\(port.name)-\(port.version).") }
            guard let archive = archives.first else { continue }
            items.append(ScanItem(url: archive, size: archives.reduce(0) { $0 + CleanupScanner.allocatedSize(of: $1) }, category: .macPorts,
                                  title: "\(port.name) @\(port.version)", details: "неактивная версия — удалит port uninstall",
                                  isRecommended: true, removal: .portUninstall(name: port.name, version: port.version)))
        }
        let build = macPorts.appending(path: "build")
        if isDirectory(build) {
            items.append(ScanItem(url: build, size: CleanupScanner.allocatedSize(of: build), category: .macPorts,
                                  title: "Папки сборки", details: "остаются после установки портов — чистите сами: sudo port reclaim", isRecommended: true))
        }
        let distfiles = macPorts.appending(path: "distfiles")
        if isDirectory(distfiles) {
            items.append(ScanItem(url: distfiles, size: CleanupScanner.allocatedSize(of: distfiles), category: .macPorts,
                                  title: "Скачанные исходники", details: "ненужные установленным портам удалит sudo port reclaim — запустите сами",
                                  isRecommended: false))
        }
        return CategoryScanResult(category: .macPorts, items: items, isAccessDenied: false)
    }

    /// Строки `port installed inactive`: «  имя @версия_ревизия+варианты» — без пометки `(active)`.
    static func inactivePorts(_ output: String) -> [(name: String, version: String)] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(" "), !line.contains("(active)") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("@") else { return nil }
            return (String(parts[0]), String(parts[1].dropFirst()))
        }
    }

    // MARK: - Ollama

    /// Модели по манифестам: до Ollama 0.40 — `manifests/<хост>/<пространство>/<модель>/<тег>` с JSON,
    /// с 0.40 — `manifests-v2/…`, ссылка на блоб с тем же JSON. Модели делят слои — каждый блоб считается один раз.
    static func ollama(home: URL) -> CategoryScanResult {
        let models = home.appending(path: ".ollama/models")
        guard isDirectory(models) else { return CategoryScanResult(category: .ollama, items: [], isAccessDenied: false) }

        // На имя — манифесты из обеих раскладок, новая первой: старый остаётся запасным, если ссылка v2 битая.
        var manifests: [String: [URL]] = [:]
        for layout in ["manifests", "manifests-v2"] {
            let enumerator = FileManager.default.enumerator(at: models.appending(path: layout), includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard enumerator?.level == 4 else { continue }
                manifests[ollamaName(Array(file.pathComponents.suffix(4))), default: []].insert(file, at: 0)
            }
        }

        var counted = Set<String>()
        var items: [ScanItem] = []
        for (name, candidates) in manifests.sorted(by: { $0.key < $1.key }) {
            // Список манифестов (manifest list) и битые ссылки пропускаются — слоёв в них нет.
            let parsed = candidates.lazy.compactMap { file -> (URL, [String: Any])? in
                guard let json = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                      json["layers"] != nil else { return nil }
                return (file, json)
            }.first
            guard let parsed else { continue }
            let (manifest, json) = parsed
            let layers = ((json["layers"] as? [[String: Any]]) ?? []) + [(json["config"] as? [String: Any]) ?? [:]]
            let digests = layers.compactMap { $0["digest"] as? String }
            guard !digests.isEmpty else { continue }
            let size = digests.filter { counted.insert($0).inserted }.reduce(Int64(0)) { total, digest in
                total + CleanupScanner.allocatedSize(of: models.appending(path: "blobs/" + digest.replacingOccurrences(of: ":", with: "-")))
            }
            items.append(ScanItem(url: manifest, size: size, category: .ollama, title: name,
                                  details: "модель Ollama", isRecommended: false,
                                  removal: .ollamaDelete(model: name)))
        }
        return CategoryScanResult(category: .ollama, items: items, isAccessDenied: false)
    }

    /// Имя модели как в `ollama list`: у стандартного реестра без хоста, у `library` — без пространства.
    private static func ollamaName(_ parts: [String]) -> String {
        let (host, namespace, model, tag) = (parts[0], parts[1], parts[2], parts[3])
        let isDefaultRegistry = host == "registry.ollama.ai" || host == "ollama.com"
        let path = isDefaultRegistry ? (namespace == "library" ? model : "\(namespace)/\(model)") : "\(host)/\(namespace)/\(model)"
        return "\(path):\(tag)"
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `system-images/<api>/<tag>/<abi>` — по элементу на вариант образа.
    private static func systemImageItems(in folder: URL, usage: [String: Int]?, accessDenied: inout Bool) -> [ScanItem] {
        var items: [ScanItem] = []
        for api in sdkChildren(of: folder, accessDenied: &accessDenied) {
            for tag in sdkChildren(of: api, accessDenied: &accessDenied) {
                for abi in sdkChildren(of: tag, accessDenied: &accessDenied) {
                    let path = "system-images/\(api.lastPathComponent)/\(tag.lastPathComponent)/\(abi.lastPathComponent)"
                    let users = usage?[path] ?? 0
                    let details = usage == nil ? "образ системы" : (users > 0 ? "образ системы · эмуляторов: \(users)" : "образ системы · не нужен ни одному эмулятору")
                    items.append(ScanItem(url: abi, size: CleanupScanner.allocatedSize(of: abi), category: .androidSDK,
                                          title: imageTitle(path), details: details, isRecommended: usage != nil && users == 0))
                }
            }
        }
        return items
    }

    /// `build-tools/35.0.0`, `ndk/27.0.12077973` — все версии, кроме самой свежей.
    private static func versionedSDKItems(in folder: URL, kind: String, accessDenied: inout Bool) -> [ScanItem] {
        let items = sdkChildren(of: folder, accessDenied: &accessDenied).map { version in
            ScanItem(url: version, size: CleanupScanner.allocatedSize(of: version), category: .androidSDK,
                     title: "\(kind) \(version.lastPathComponent)", details: kind == "ndk" ? "Android NDK" : "инструменты сборки")
        }
        return VersionPolicy.recommendingAllButNewest(items, groupedBy: { _ in kind })
    }

    /// `system-images/android-36/google_apis/arm64-v8a` → `Android 36 · google_apis · arm64-v8a`.
    private static func imageTitle(_ path: String) -> String {
        let parts = path.split(separator: "/").dropFirst()
        guard let api = parts.first else { return path }
        let level = api.replacingOccurrences(of: "android-", with: "Android ")
        return ([level] + parts.dropFirst().map(String.init)).joined(separator: " · ")
    }

    private static func sdkChildren(of folder: URL, accessDenied: inout Bool) -> [URL] {
        guard case let .children(children) = CleanupScanner.list(folder, accessDenied: &accessDenied) else { return [] }
        return children.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private static func globalNPMPackages(in folder: URL, accessDenied: inout Bool) -> [ScanItem] {
        var packages: [URL] = []
        for entry in sdkChildren(of: folder, accessDenied: &accessDenied) {
            // Пакеты с областью видимости лежат на уровень глубже: `@org/pkg`.
            packages += entry.lastPathComponent.hasPrefix("@") ? sdkChildren(of: entry, accessDenied: &accessDenied) : [entry]
        }
        return packages.map { package in
            let manifest = propertyListOrJSON(at: package.appending(path: "package.json"))
            let version = manifest?["version"] as? String
            let name = manifest?["name"] as? String ?? package.lastPathComponent
            return ScanItem(url: package, size: CleanupScanner.allocatedSize(of: package), category: .terminalPrograms, title: name,
                            details: ["глобальный npm-пакет", version.map { "версия \($0)" }, folder.path].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// Команда из папки команд: битая ссылка — отмечена; ссылка в уже показанное или в Homebrew — пропуск.
    private static func commandItem(_ command: URL, label: String, ownedPrefixes: [String], applications: URL) -> ScanItem? {
        let path = command.path
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return ScanItem(url: command, size: CleanupScanner.allocatedSize(of: command), category: .terminalPrograms,
                            details: "\(label) · \(fileKind(command))")
        }

        let isBroken = isBrokenLink(command)
        let target = isBroken
            ? URL(filePath: destination, relativeTo: command.deletingLastPathComponent()).absoluteURL.standardizedFileURL
            : command.resolvingSymlinksInPath()
        let resolvedTarget = target.canonicalFileURL.path
        if ownedPrefixes.contains(where: { resolvedTarget.hasPrefix($0) }) {
            return nil
        }
        guard !isBroken else {
            return ScanItem(url: command, size: 0, category: .terminalPrograms,
                            details: "\(label) · ссылка на удалённую программу: \(target.path)", isRecommended: true)
        }
        let applicationsPath = applications.canonicalFileURL.path + "/"
        if resolvedTarget.hasPrefix(applicationsPath) {
            let application = resolvedTarget.dropFirst(applicationsPath.count).split(separator: "/").first.map(String.init) ?? ""
            return ScanItem(url: command, size: 0, category: .terminalPrograms, details: "\(label) · команда приложения \(application)")
        }
        return ScanItem(url: command, size: CleanupScanner.allocatedSize(of: target), category: .terminalPrograms,
                        details: "\(label) · ссылка на \(target.path)")
    }

    /// Скрипт с интерпретатором из первой строки или исполняемая программа.
    private static func fileKind(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "файл" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 200)) ?? Data()
        guard head.starts(with: Data("#!".utf8)) else { return "программа" }

        let firstLine = String(decoding: head, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        let words = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        let interpreter = (words.first?.hasSuffix("/env") == true ? words.dropFirst().first : words.first)
            .map { URL(filePath: $0).lastPathComponent } ?? "?"
        return firstLine.contains("/System/Library/Frameworks/Ruby.framework") ? "скрипт системного Ruby (гем)" : "скрипт \(interpreter)"
    }

    /// `node, php и ещё 3`.
    private static func listed(_ names: [String]) -> String {
        guard !names.isEmpty else { return "?" }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) и ещё \(names.count - 3)" : shown
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func propertyListOrJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private extension Array {
    func uniqued(by key: (Element) -> String) -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert(key($0)).inserted }
    }
}
