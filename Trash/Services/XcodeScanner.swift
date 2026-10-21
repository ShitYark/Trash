import Foundation

/// Поиск мусора Xcode с подписями и рекомендациями. Только читает диск и вывод `simctl` —
/// ничего не удаляет и не запускает симуляторы.
enum XcodeScanner {
    static let xcodeSelect = "/usr/bin/xcode-select"
    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"

    static let noXcodeReason = "Xcode не найден: симуляторы и рантаймы ищутся через simctl из Xcode."
    static let simctlFailedReason = "simctl не ответил — пересканируйте позже."
    static let unknownActiveXcodeReason = "Не удалось определить активный Xcode — копии не показаны, чтобы не предложить удалить рабочую."

    // MARK: - DerivedData

    /// Папка DerivedData с именем проекта из `info.plist`. Папки без `info.plist` — общие кэши сборки.
    static func derivedDataItem(_ url: URL, home: URL) -> ScanItem {
        let size = CleanupScanner.allocatedSize(of: url)
        guard let info = propertyList(at: url.appending(path: "info.plist")),
              let workspacePath = info["WorkspacePath"] as? String else {
            return ScanItem(url: url, size: size, category: .xcodeDerivedData, details: "Общий кэш сборки Xcode")
        }

        var details = [abbreviated(workspacePath, home: home)]
        if !FileManager.default.fileExists(atPath: workspacePath) {
            details.append("проекта больше нет")
        } else if let lastAccess = info["LastAccessedDate"] as? Date {
            details.append("открывался \(formatted(lastAccess))")
        }
        let project = URL(filePath: workspacePath).deletingPathExtension().lastPathComponent
        return ScanItem(url: url, size: size, category: .xcodeDerivedData, title: project, details: details.joined(separator: " · "))
    }

    // MARK: - Device Support

    static func deviceSupportItem(_ url: URL) -> ScanItem {
        let platform = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: " DeviceSupport", with: "")
        let version = VersionPolicy.version(in: url.lastPathComponent)
        let details = version.map { "\(platform) \($0.map(String.init).joined(separator: "."))" }
        return ScanItem(url: url, size: CleanupScanner.allocatedSize(of: url), category: .xcodeDeviceSupport, details: details)
    }

    // MARK: - Archives

    /// Каждый `.xcarchive` из папок по датам: приложение, версия, дата создания.
    static func archives(in roots: [URL]) -> CategoryScanResult {
        var items: [ScanItem] = []
        var isAccessDenied = false

        for root in roots {
            guard case let .children(dateFolders) = CleanupScanner.list(root, accessDenied: &isAccessDenied) else { continue }
            for folder in dateFolders {
                guard case let .children(archives) = CleanupScanner.list(folder, accessDenied: &isAccessDenied) else { continue }
                for archive in archives where archive.pathExtension == "xcarchive" {
                    guard !Task.isCancelled else { break }
                    items.append(archiveItem(archive))
                }
            }
        }
        return CategoryScanResult(category: .xcodeArchives, items: items, isAccessDenied: isAccessDenied)
    }

    // MARK: - Simulators

    /// Симуляторы из `simctl` и папки в `Devices`, которых `simctl` не знает.
    /// Отмечены недоступные и папки-сироты; запущенный симулятор не отмечается никогда.
    static func simulators(in roots: [URL], runner: CommandRunner) async -> CategoryScanResult {
        guard let simctl = await simctlPath(runner: runner) else {
            return CategoryScanResult(category: .simulators, items: [], isAccessDenied: false, unavailableReason: noXcodeReason)
        }
        guard let devicesDirectory = roots.first,
              let data = try? await runner.run(simctl, SimulatorCatalog.listDevicesArguments),
              let devices = try? SimulatorCatalog.devices(from: data) else {
            // Без списка нельзя отличить сироту от симулятора — не угадываем.
            return CategoryScanResult(category: .simulators, items: [], isAccessDenied: false, unavailableReason: simctlFailedReason)
        }

        var items = devices.map { simulatorItem($0, in: devicesDirectory) }
        var isAccessDenied = false
        let known = Set(devices.map(\.udid))
        if case let .children(folders) = CleanupScanner.list(devicesDirectory, accessDenied: &isAccessDenied) {
            for folder in folders where isOrphanSimulatorFolder(folder, known: known) {
                items.append(ScanItem(
                    url: folder,
                    size: CleanupScanner.allocatedSize(of: folder),
                    category: .simulators,
                    title: "Папка без симулятора",
                    details: "\(folder.lastPathComponent) · simctl о ней не знает",
                    isRecommended: true
                ))
            }
        }
        return CategoryScanResult(category: .simulators, items: items, isAccessDenied: isAccessDenied)
    }

    // MARK: - Runtimes

    /// Рантаймы из `simctl runtime`. Отмечены удаляемые, которыми не пользуется ни один симулятор.
    /// Список симуляторов не получен — не отмечается ничего.
    static func runtimes(runner: CommandRunner) async -> CategoryScanResult {
        guard let simctl = await simctlPath(runner: runner) else {
            return CategoryScanResult(category: .simulatorRuntimes, items: [], isAccessDenied: false, unavailableReason: noXcodeReason)
        }
        guard let data = try? await runner.run(simctl, SimulatorCatalog.listRuntimesArguments),
              let runtimes = try? SimulatorCatalog.runtimes(from: data) else {
            return CategoryScanResult(category: .simulatorRuntimes, items: [], isAccessDenied: false, unavailableReason: simctlFailedReason)
        }

        let devices = (try? await runner.run(simctl, SimulatorCatalog.listDevicesArguments))
            .flatMap { try? SimulatorCatalog.devices(from: $0) }
        let usage = devices.map { Dictionary(grouping: $0, by: \.runtimeIdentifier).mapValues(\.count) }

        let items = runtimes.map { runtimeItem($0, usage: usage) }
        return CategoryScanResult(category: .simulatorRuntimes, items: items, isAccessDenied: false)
    }

    // MARK: - dyld caches

    /// Кэши dyld рантаймов: `<library>/Developer/CoreSimulator/Caches/dyld/<сборка macOS>/<runtimeIdentifier>.<сборка>`.
    /// Удаляет `simctl`; мусор — кэши рантаймов, которые эта macOS не поддерживает: их кэш больше не создаётся.
    /// Папка без известного рантайма и папки старых сборок macOS — только поиск: CoreSimulator удаляет их сам.
    static func dyldCaches(system: SystemLocations, runner: CommandRunner) async -> CategoryScanResult {
        let root = system.library.appending(path: "Developer/CoreSimulator/Caches/dyld", directoryHint: .isDirectory)
        var isAccessDenied = false
        guard case let .children(builds) = CleanupScanner.list(root, accessDenied: &isAccessDenied) else {
            return CategoryScanResult(category: .simulatorDyldCaches, items: [], isAccessDenied: isAccessDenied)
        }
        // Без `simctl` не понять, какой рантайм поддерживается, — все кэши только поиском.
        let availability: [String: SimulatorCatalog.Availability]? = if let simctl = await simctlPath(runner: runner),
                                               let data = try? await runner.run(simctl, SimulatorCatalog.listRuntimeAvailabilityArguments) {
            try? SimulatorCatalog.availability(from: data)
        } else {
            nil
        }
        let hostBuild = Self.hostBuild()

        var items: [ScanItem] = []
        for build in builds where !build.lastPathComponent.hasPrefix(".") {
            guard case let .children(caches) = CleanupScanner.list(build, accessDenied: &isAccessDenied) else { continue }
            for cache in caches where !cache.lastPathComponent.hasPrefix(".") && cache.lastPathComponent != "inc" {
                items.append(dyldCacheItem(cache, isCurrentBuild: build.lastPathComponent == hostBuild, availability: availability))
            }
        }
        return CategoryScanResult(category: .simulatorDyldCaches, items: items, isAccessDenied: isAccessDenied)
    }

    /// Сборка macOS — имя папки кэшей текущей системы, `26A428`. Из `kern.osversion`: строка версии
    /// `operatingSystemVersionString` локализована, «Build» в ней бывает и «сборкой».
    static func hostBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-16-0.20A360` → рантайм и сборка: сборка — после последней точки.
    static func dyldCacheRuntime(_ name: String) -> (runtimeIdentifier: String, build: String)? {
        guard let dot = name.lastIndex(of: "."), name.hasPrefix("com.apple.CoreSimulator.SimRuntime.") else { return nil }
        let build = String(name[name.index(after: dot)...])
        return build.isEmpty ? nil : (String(name[..<dot]), build)
    }

    private static func dyldCacheItem(_ cache: URL, isCurrentBuild: Bool, availability: [String: SimulatorCatalog.Availability]?) -> ScanItem {
        let name = cache.lastPathComponent
        let runtime = dyldCacheRuntime(name)
        let title = runtime.map { "Кэш dyld · \(SimulatorCatalog.displayName(ofRuntime: $0.runtimeIdentifier))" } ?? name
        let runtimeAvailability = availability?[name]
        let isAvailable = runtimeAvailability?.isAvailable
        let details: String
        var removal: ManagerRemoval?
        switch (isCurrentBuild, isAvailable) {
        case (false, _):
            details = "старая сборка macOS — CoreSimulator удалит сам"
        case (true, nil):
            details = availability == nil ? "simctl не ответил — какой рантайм, неизвестно" : "рантайма нет — CoreSimulator удалит сам"
        case (true, .some(true)):
            details = "сборка \(runtime?.build ?? "?") · Xcode создаст заново при следующем запуске"
            removal = runtime.map { .dyldCacheRemove(runtimeIdentifier: $0.runtimeIdentifier, build: $0.build) }
        case (true, .some(false)):
            // Причина — словами `simctl`: на этом Mac «not supported on hosts after macOS …».
            let reason = runtimeAvailability?.error ?? "рантайм недоступен"
            details = "сборка \(runtime?.build ?? "?") · кэш больше не создаётся: \(reason)"
            removal = runtime.map { .dyldCacheRemove(runtimeIdentifier: $0.runtimeIdentifier, build: $0.build) }
        }
        return ScanItem(url: cache, size: CleanupScanner.allocatedSize(of: cache), category: .simulatorDyldCaches, title: title,
                        details: details, isRecommended: isCurrentBuild && isAvailable == false, removal: removal)
    }

    // MARK: - Xcode applications

    /// Копии Xcode в папке программ, кроме выбранной в `xcode-select`. Активную определить не удалось — не показываем ничего.
    static func applications(in directory: URL, runner: CommandRunner) async -> CategoryScanResult {
        guard let developer = await developerDirectory(runner: runner),
              let activeApplication = applicationPath(fromDeveloperDirectory: developer.path) else {
            return CategoryScanResult(category: .xcodeApplications, items: [], isAccessDenied: false,
                                      unavailableReason: unknownActiveXcodeReason)
        }

        var isAccessDenied = false
        guard case let .children(applications) = CleanupScanner.list(directory, accessDenied: &isAccessDenied) else {
            return CategoryScanResult(category: .xcodeApplications, items: [], isAccessDenied: isAccessDenied)
        }

        let items = applications.compactMap { url -> ScanItem? in
            guard url.pathExtension == "app",
                  comparablePath(url) != comparablePath(activeApplication),
                  let info = propertyList(at: url.appending(path: "Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == xcodeBundleIdentifier else {
                return nil
            }
            return ScanItem(
                url: url,
                size: CleanupScanner.allocatedSize(of: url),
                category: .xcodeApplications,
                title: url.deletingPathExtension().lastPathComponent,
                details: (info["CFBundleShortVersionString"] as? String).map { "версия \($0)" }
            )
        }
        return CategoryScanResult(category: .xcodeApplications, items: items, isAccessDenied: isAccessDenied)
    }

    /// `/Applications/Xcode.app/Contents/Developer` → `/Applications/Xcode.app`.
    static func applicationPath(fromDeveloperDirectory path: String) -> URL? {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(filePath: String(path[..<range.lowerBound]) + ".app", directoryHint: .isDirectory)
    }

    // MARK: - Helpers

    /// Активная папка разработчика по `xcode-select -p`, только если она существует.
    /// Без неё `simctl` не запускаем: на Mac без инструментов разработчика заглушки `/usr/bin` предлагают их установить.
    private static func developerDirectory(runner: CommandRunner) async -> URL? {
        guard let output = try? await runner.run(xcodeSelect, ["-p"]) else { return nil }
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// `simctl` из активного Xcode; у Command Line Tools без Xcode его нет.
    static func simctlPath(runner: CommandRunner) async -> String? {
        guard let developer = await developerDirectory(runner: runner) else { return nil }
        let simctl = developer.appending(path: "usr/bin/simctl").path
        return FileManager.default.fileExists(atPath: simctl) ? simctl : nil
    }

    private static func simulatorItem(_ device: SimulatorDevice, in devicesDirectory: URL) -> ScanItem {
        let url = devicesDirectory.appending(path: device.udid, directoryHint: .isDirectory)
        var details = [SimulatorCatalog.displayName(ofRuntime: device.runtimeIdentifier)]
        if device.isBooted {
            details.append("запущен")
        } else if !device.isAvailable {
            details.append("недоступен в текущем Xcode")
        } else {
            details.append(device.lastUsedAt.map { "последний запуск \(formatted($0))" } ?? "не запускался")
        }
        return ScanItem(
            url: url,
            size: CleanupScanner.allocatedSize(of: url),
            category: .simulators,
            title: device.name,
            details: details.joined(separator: " · "),
            isRecommended: !device.isAvailable && !device.isBooted,
            removal: .simulator(udid: device.udid)
        )
    }

    private static func isOrphanSimulatorFolder(_ url: URL, known: Set<String>) -> Bool {
        let name = url.lastPathComponent
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory && UUID(uuidString: name) != nil && !known.contains(name)
    }

    private static func runtimeItem(_ runtime: SimulatorRuntime, usage: [String: Int]?) -> ScanItem {
        let users = usage?[runtime.runtimeIdentifier] ?? 0
        var details = [runtime.build.map { "сборка \($0)" }]
        if usage != nil {
            details.append(users > 0 ? "симуляторов: \(users)" : "не нужен ни одному симулятору")
        }
        details.append(runtime.lastUsedAt.map { "последний запуск \(formatted($0))" })
        if !runtime.isDeletable {
            details.append("встроен в Xcode")
        }

        let platform = SimulatorCatalog.platform(ofRuntime: runtime.runtimeIdentifier)
        let path = runtime.mountPath ?? runtime.bundlePath ?? "/Library/Developer/CoreSimulator/Volumes/\(runtime.identifier)"
        return ScanItem(
            url: URL(filePath: path, directoryHint: .isDirectory),
            size: runtime.sizeBytes,
            category: .simulatorRuntimes,
            title: platform.isEmpty ? "Рантайм \(runtime.version)" : "\(platform) \(runtime.version)",
            details: details.compactMap { $0 }.joined(separator: " · "),
            isRecommended: runtime.isDeletable && usage != nil && users == 0,
            // Встроенный в Xcode рантайм `simctl` не удаляет — операции нет, выбрать его нельзя.
            removal: runtime.isDeletable ? .runtime(identifier: runtime.identifier, runtimeIdentifier: runtime.runtimeIdentifier) : nil
        )
    }

    private static func archiveItem(_ url: URL) -> ScanItem {
        let info = propertyList(at: url.appending(path: "Info.plist"))
        let properties = info?["ApplicationProperties"] as? [String: Any]
        let version = properties?["CFBundleShortVersionString"] as? String
        let build = properties?["CFBundleVersion"] as? String
        let created = info?["CreationDate"] as? Date

        // Номер сборки показываем, только если он отличается от версии.
        let versionText = version.map { version in
            build.flatMap { $0 == version ? nil : "версия \(version) (\($0))" } ?? "версия \(version)"
        }
        let details = [versionText, created.map(formatted)].compactMap { $0 }.joined(separator: " · ")

        return ScanItem(
            url: url,
            size: CleanupScanner.allocatedSize(of: url),
            category: .xcodeArchives,
            title: info?["Name"] as? String ?? url.deletingPathExtension().lastPathComponent,
            details: details.isEmpty ? nil : details
        )
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func abbreviated(_ path: String, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Даты — по-русски, как весь интерфейс, независимо от языка системы.
    private static func formatted(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "ru_RU")))
    }
}
