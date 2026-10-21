import Foundation

/// Последний рубеж защиты перед удалением. Разрешает удалять только:
/// - то, что лежит строго внутри одной из корневых папок категорий;
/// - сам `.app` прямо в папке программ или в её подпапке — не папку программ и не содержимое бандла;
/// - остаток с именем-идентификатором прямо в папке данных программ `~/Library/<…>`.
struct SafetyGuard: Sendable {
    let allowedRoots: [URL]
    let protectedPaths: Set<String>
    let applicationFolders: [URL]
    let leftoverFolders: [(URL, LeftoverPolicy.Kind)]
    /// Папки внутри разрешённых корней, которые удалять нельзя никогда, — например глобальное хранилище Bun:
    /// на него ссылаются `node_modules` проектов. Вторая защита после исключения в сканере.
    let keptFolders: [URL]
    /// Папка симуляторов: правилом «Симуляторов» — только папка-UUID прямо в ней; корнем для других разделов не служит.
    let simulatorDevices: URL?
    /// Папки версий менеджеров: правилом «Версий языков» — только папка версии прямо в них. Читаются при каждой
    /// проверке — менеджер, поставленный после запуска, тоже учитывается.
    let versionFolders: @Sendable () -> [URL]
    /// Android SDK и папка эмуляторов: правилом «Android» — только папка пакета с `package.xml` на своей глубине
    /// или `<имя>.avd` прямо в папке эмуляторов; корнями для других разделов не служат.
    let androidSDK: URL?
    let androidAVDs: URL?
    /// Папки команд и папки служб `launchd`, в том числе вне `~`: правилами «Программ» и «Служб» — только битая
    /// ссылка прямо в папке команд и только plist прямо в папке служб.
    let commandFolders: [URL]
    let serviceFolders: [URL]
    /// `Application Support` и Загрузки: правилами «Кэшей в данных программ» и «Установщиков» — только папка-кэш
    /// Chromium и только установщик прямо в Загрузках; целиком корнями не становятся.
    let applicationSupport: URL?
    let downloads: URL?

    init(
        allowedRoots: [URL],
        applicationFolders: [URL] = [],
        leftoverFolders: [(URL, LeftoverPolicy.Kind)] = [],
        keptFolders: [URL] = [],
        simulatorDevices: URL? = nil,
        versionFolders: @escaping @Sendable () -> [URL] = { [] },
        androidSDK: URL? = nil,
        androidAVDs: URL? = nil,
        commandFolders: [URL] = [],
        serviceFolders: [URL] = [],
        applicationSupport: URL? = nil,
        downloads: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.allowedRoots = allowedRoots.map(Self.normalized)
        self.keptFolders = keptFolders.map(Self.normalized)
        self.simulatorDevices = simulatorDevices?.canonicalFileURL
        self.versionFolders = versionFolders
        self.androidSDK = androidSDK?.canonicalFileURL
        self.androidAVDs = androidAVDs?.canonicalFileURL
        self.commandFolders = commandFolders.map(\.canonicalFileURL)
        self.serviceFolders = serviceFolders.map(\.canonicalFileURL)
        self.applicationSupport = applicationSupport?.canonicalFileURL
        self.downloads = downloads?.canonicalFileURL
        // Сами папки тоже раскрываются: `~/Applications` бывает ссылкой.
        self.applicationFolders = applicationFolders.map(\.canonicalFileURL)
        self.leftoverFolders = leftoverFolders.map { ($0.0.canonicalFileURL, $0.1) }

        let homePaths = ["", "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications"]
            .map { Self.normalized(home.appending(path: $0)).path }
        let systemPaths = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/var", "/etc"]
            .map { Self.normalized(URL(filePath: $0)).path }
        self.protectedPaths = Set(homePaths + systemPaths)
    }

    /// Разрешены корни только удаляемых категорий; программы и остатки — своими узкими правилами,
    /// а не корнями: `/Applications` и папки `~/Library` целиком удаляемыми не становятся.
    init(categories: [CleanupCategory] = CleanupCategory.allCases.filter(\.isDeletable), home: URL, system: SystemLocations = SystemLocations()) {
        // Симуляторы и версии языков — своими узкими правилами, а не корнями: иначе их папки достались бы любому разделу.
        let narrow: Set<CleanupCategory> = [.simulators, .languageVersions, .androidSDK, .terminalPrograms, .backgroundServices]
        let hasVersions = categories.contains(.languageVersions)
        let android = categories.contains(.androidSDK) ? CleanupCategory.androidSDK.roots(home: home) : []
        let versionFolders: @Sendable () -> [URL] = {
            hasVersions ? ToolCatalog.versionManagers.flatMap { $0.versionFolders(home) } : []
        }
        self.init(
            allowedRoots: categories.filter { !narrow.contains($0) }.flatMap { $0.roots(home: home) },
            applicationFolders: categories.contains(where: \.isApplicationBundle) ? ApplicationCatalog.folders(system: system, home: home) : [],
            leftoverFolders: categories.contains(.appLeftovers) ? LeftoverPolicy.folders(home: home) : [],
            keptFolders: categories.contains(.toolCaches) ? ToolCatalog.keptFolders(home: home) : [],
            simulatorDevices: categories.contains(.simulators) ? CleanupCategory.simulators.roots(home: home).first : nil,
            versionFolders: versionFolders,
            androidSDK: android.first,
            androidAVDs: android.dropFirst().first,
            commandFolders: categories.contains(.terminalPrograms)
                ? [system.usrLocal.appending(path: "bin")] + CleanupCategory.terminalPrograms.roots(home: home)
                : [],
            serviceFolders: categories.contains(.backgroundServices)
                ? CleanupCategory.backgroundServices.roots(home: home) + ["LaunchAgents", "LaunchDaemons"].map { system.library.appending(path: $0) }
                : [],
            applicationSupport: categories.contains(.applicationSupportCaches) ? OtherDataScanner.applicationSupport(home: home) : nil,
            downloads: categories.contains(.downloadedInstallers) ? OtherDataScanner.downloads(home: home) : nil,
            home: home
        )
    }

    /// Проверка по корням категорий — для элементов, удаляемых файлами.
    func canDelete(_ url: URL) -> Bool {
        let target = Self.normalized(url)
        return !protectedPaths.contains(target.path) && isInsideAllowedRoot(target)
    }

    /// Проверка по правилу категории элемента: программа — только правилом программ, остаток — только правилом
    /// остатков, остальное — корнями. Так `.app` из чужой категории не пройдёт и не уйдёт мимо Корзины.
    func canDelete(_ url: URL, as category: CleanupCategory) -> Bool {
        let target = Self.normalized(url)
        guard !protectedPaths.contains(target.path) else { return false }
        if category.isApplicationBundle {
            return isApplicationBundle(target)
        }
        if category == .appLeftovers {
            return isLeftover(target)
        }
        if category == .simulators {
            return isSimulatorFolder(target)
        }
        if category == .languageVersions {
            return isVersionFolder(target)
        }
        if category == .androidSDK {
            return isAndroidItem(target)
        }
        if category == .terminalPrograms {
            return isBrokenCommandLink(target)
        }
        if category == .backgroundServices {
            return isServicePlist(target)
        }
        if category == .applicationSupportCaches {
            return applicationSupport.map { OtherDataScanner.isApplicationCache(target, applicationSupport: $0) } ?? false
        }
        if category == .downloadedInstallers {
            return downloads.map { OtherDataScanner.isInstaller(target, downloads: $0) } ?? false
        }
        return isInsideAllowedRoot(target)
    }

    /// Вид папки данных программ, в которой прямо лежит элемент, или `nil`.
    func leftoverKind(of url: URL) -> LeftoverPolicy.Kind? {
        let parent = Self.normalized(url).deletingLastPathComponent().path
        return leftoverFolders.first { $0.0.path == parent }?.1
    }

    private func isInsideAllowedRoot(_ target: URL) -> Bool {
        let targetComponents = target.pathComponents
        // Сама сохраняемая папка или что-то внутри неё — нельзя, даже если корень разрешён.
        if keptFolders.contains(where: { targetComponents.starts(with: $0.pathComponents) }) {
            return false
        }
        return allowedRoots.contains { root in
            let rootComponents = root.pathComponents
            return targetComponents.count > rootComponents.count
                && targetComponents.starts(with: rootComponents)
        }
    }

    /// `.app` прямо в папке программ или в её подпапке (`Utilities`, папка производителя), не системный и не сам Trash.
    private func isApplicationBundle(_ target: URL) -> Bool {
        guard target.pathExtension == "app" else { return false }
        let parent = target.deletingLastPathComponent()
        let isInFolder = applicationFolders.contains { $0.path == parent.path }
        let isInSubfolder = parent.pathExtension != "app" && applicationFolders.contains { $0.path == parent.deletingLastPathComponent().path }
        guard isInFolder || isInSubfolder else { return false }

        let resolved = target.resolvingSymlinksInPath().path
        return !resolved.hasPrefix("/System/") && resolved != Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    /// Папка симулятора: имя — UUID, лежит прямо в папке симуляторов. Не `device_set.plist`, не содержимое симулятора.
    private func isSimulatorFolder(_ target: URL) -> Bool {
        guard let simulatorDevices else { return false }
        return target.deletingLastPathComponent().path == simulatorDevices.path && UUID(uuidString: target.lastPathComponent) != nil
    }

    /// Папка версии прямо в папке версий менеджера — не сама папка версий, не что-то внутри версии и не ссылка-псевдоним
    /// вроде `current` у SDKMAN или `22` у mise.
    private func isVersionFolder(_ target: URL) -> Bool {
        let parent = target.deletingLastPathComponent().path
        guard !target.lastPathComponent.hasPrefix("."),
              (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return false }
        return versionFolders().contains { $0.canonicalFileURL.path == parent }
    }

    /// Эмулятор `<имя>.avd` прямо в папке эмуляторов или пакет SDK: `system-images/<api>/<tag>/<abi>`,
    /// `build-tools/<версия>`, `ndk/<версия>`, `platforms/<платформа>` с `package.xml` — по нему пакеты находят
    /// Android Studio и sdkmanager. Не ссылка, не скрытое; эмулятор, platform-tools и прочие компоненты — нет.
    private func isAndroidItem(_ target: URL) -> Bool {
        guard !target.lastPathComponent.hasPrefix("."),
              (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return false }
        if let androidAVDs, target.deletingLastPathComponent().path == androidAVDs.path {
            return target.pathExtension == "avd"
        }
        guard let androidSDK else { return false }
        let root = androidSDK.pathComponents
        let components = target.pathComponents
        guard components.count > root.count, components.starts(with: root) else { return false }
        let relative = components.dropFirst(root.count)
        let depths = ["system-images": 4, "build-tools": 2, "ndk": 2, "platforms": 2]
        guard let kind = relative.first, depths[kind] == relative.count, !relative.contains(where: { $0.hasPrefix(".") }) else {
            return false
        }
        return FileManager.default.fileExists(atPath: target.appending(path: "package.xml").path)
    }

    /// Битая ссылка прямо в папке команд: удаляется сама ссылка — цели нет. Живая ссылка, программа, скрытое — нет.
    private func isBrokenCommandLink(_ target: URL) -> Bool {
        guard !target.lastPathComponent.hasPrefix("."),
              (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
              TerminalScanner.isBrokenLink(target) else { return false }
        return commandFolders.contains { $0.path == target.deletingLastPathComponent().path }
    }

    /// plist службы прямо в папке служб: обычный файл, не ссылка, не скрытый. `/System` в папках служб нет.
    private func isServicePlist(_ target: URL) -> Bool {
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard target.pathExtension == "plist", !target.lastPathComponent.hasPrefix("."),
              values?.isRegularFile == true, values?.isSymbolicLink != true else { return false }
        return serviceFolders.contains { $0.path == target.deletingLastPathComponent().path }
    }

    /// `<имя>.ini` эмулятора: обычный файл, не ссылка и не папка, прямо в папке эмуляторов.
    func canDeleteEmulatorConfig(_ url: URL) -> Bool {
        let target = Self.normalized(url)
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard let androidAVDs, target.pathExtension == "ini", !target.lastPathComponent.hasPrefix("."),
              values?.isRegularFile == true, values?.isSymbolicLink != true else { return false }
        return target.deletingLastPathComponent().path == androidAVDs.path
    }

    /// Элемент с именем-идентификатором чужой программы прямо в папке данных программ.
    private func isLeftover(_ target: URL) -> Bool {
        guard let kind = leftoverKind(of: target) else { return false }
        return LeftoverPolicy.owner(ofEntryNamed: target.lastPathComponent, kind: kind) != nil
    }

    /// Убирает `.` и `..`, раскрывает симлинки в родительских папках, но не в самом элементе:
    /// удаляется ссылка, а не то, на что она указывает. Ещё не созданный путь приводится так же, как существующий.
    static func normalized(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard name != "/" else { return standardized }
        return standardized.deletingLastPathComponent().canonicalFileURL.appending(path: name)
    }
}
