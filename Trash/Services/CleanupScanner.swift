import Foundation

/// Ищет мусор по категориям и считает занимаемое место. Только читает диск.
struct CleanupScanner: Sendable {
    /// Содержимое папки.
    enum Listing {
        case missing
        case denied
        case children([URL])
    }

    let home: URL
    let system: SystemLocations
    let commandRunner: CommandRunner
    let applications: ApplicationEnvironment

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        system: SystemLocations = SystemLocations(),
        commandRunner: CommandRunner = .system,
        applications: ApplicationEnvironment = .live
    ) {
        self.home = home
        self.system = system
        self.commandRunner = commandRunner
        self.applications = applications
    }

    @concurrent
    func scan(_ category: CleanupCategory) async -> CategoryScanResult {
        var result: CategoryScanResult
        switch category.scanMethod {
        case .children:
            result = scanChildren(of: category) { Self.childItem($0, category: category) }
        case .derivedData:
            result = scanChildren(of: category) { XcodeScanner.derivedDataItem($0, home: home) }
        case .deviceSupport:
            result = scanChildren(of: category, makeItem: XcodeScanner.deviceSupportItem)
            result.items = VersionPolicy.recommendingAllButNewest(result.items) { $0.url.deletingLastPathComponent().standardizedFileURL.path }
        case .archives:
            result = XcodeScanner.archives(in: category.roots(home: home))
        case .simulators:
            result = await XcodeScanner.simulators(in: category.roots(home: home), runner: commandRunner)
        case .runtimes:
            result = await XcodeScanner.runtimes(runner: commandRunner)
        case .applications:
            result = await XcodeScanner.applications(in: system.applications, runner: commandRunner)
        case .androidSDK:
            result = TerminalScanner.android(home: home)
        case .homebrew:
            result = await TerminalScanner.homebrew(prefix: system.homebrewPrefix, runner: commandRunner)
        case .gradle:
            result = scanChildren(of: category) { Self.childItem($0, category: category) }
            result.items = TerminalScanner.recommendingOlderGradleDistributions(result.items)
        case .programs:
            result = TerminalScanner.programs(home: home, system: system)
        case .services:
            result = TerminalScanner.services(home: home, system: system)
        case .languageVersions:
            result = TerminalScanner.languageVersions(home: home)
        case .docker:
            result = await TerminalScanner.docker(home: home, system: system, runner: commandRunner)
        case .conda:
            result = TerminalScanner.conda(home: home, system: system)
        case .macPorts:
            result = await TerminalScanner.macPorts(system: system, runner: commandRunner)
        case .ollama:
            result = TerminalScanner.ollama(home: home)
        case .installedApplications:
            result = ApplicationsScanner.installed(catalog: ApplicationCatalog.scan(system: system, home: home, environment: applications))
        case .appLeftovers:
            result = ApplicationsScanner.leftovers(home: home, catalog: ApplicationCatalog.scan(system: system, home: home, environment: applications))
        case .dyldCaches:
            result = await XcodeScanner.dyldCaches(system: system, runner: commandRunner)
        case .applicationSupportCaches:
            result = OtherDataScanner.applicationCaches(home: home)
        case .installers:
            result = OtherDataScanner.installers(home: home)
        }
        result.items.sort { $0.size > $1.size }
        return result
    }

    /// Реальный размер на диске файла или папки со всем содержимым. Симлинки не раскрываются,
    /// файл с несколькими жёсткими ссылками считается один раз — как у `du`.
    static func allocatedSize(of url: URL) -> Int64 {
        var countedHardLinks = Set<UInt64>()
        return allocatedSize(of: url, countedHardLinks: &countedHardLinks)
    }

    /// То же с общим набором учтённых жёстких ссылок — когда элементы делят файлы, как окружения и кэш conda.
    static func allocatedSize(of url: URL, countedHardLinks: inout Set<UInt64>) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .linkCountKey, .fileIdentifierKey,
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else {
            if (values.linkCount ?? 1) > 1, let identifier = values.fileIdentifier, !countedHardLinks.insert(identifier).inserted {
                return 0
            }
            return fileSize(values)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            if (values.linkCount ?? 1) > 1, let identifier = values.fileIdentifier,
               !countedHardLinks.insert(identifier).inserted {
                continue
            }
            total += fileSize(values)
        }
        return total
    }

    /// Содержимое папки; отказ в правах дополнительно отмечается в `accessDenied`.
    static func list(_ directory: URL, accessDenied: inout Bool) -> Listing {
        do {
            return .children(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            accessDenied = true
            return .denied
        } catch {
            return .missing
        }
    }

    /// Непосредственные потомки корней категории. Папки, которые сами являются корнями других категорий,
    /// пропускаются: кэш SwiftPM лежит внутри `~/Library/Caches`, но считается в «Кэшах пакетов», а не дважды.
    private func scanChildren(of category: CleanupCategory, makeItem: (URL) -> ScanItem) -> CategoryScanResult {
        let foreignRoots = Set(
            CleanupCategory.allCases
                .filter { $0 != category }
                .flatMap { $0.roots(home: home) }
                .map { $0.standardizedFileURL.path }
        )
        var items: [ScanItem] = []
        var isAccessDenied = false

        for root in category.roots(home: home) {
            guard case let .children(children) = Self.list(root, accessDenied: &isAccessDenied) else { continue }
            for child in children where !category.isExcluded(child) && !foreignRoots.contains(child.standardizedFileURL.path) {
                guard !Task.isCancelled else { break }
                items.append(makeItem(child))
            }
        }
        return CategoryScanResult(category: category, items: items, isAccessDenied: isAccessDenied)
    }

    /// Потомок корня с подписью по корню. Корень с предупреждением — элемент сам не отмечается.
    private static func childItem(_ child: URL, category: CleanupCategory) -> ScanItem {
        let rootName = child.deletingLastPathComponent().lastPathComponent
        let warning = category.rootWarning(forRootNamed: rootName)
        let details = [category.rootLabel(forRootNamed: rootName), warning].compactMap { $0 }.joined(separator: " · ")
        return ScanItem(url: child, size: allocatedSize(of: child), category: category,
                        details: details.isEmpty ? nil : details, isRecommended: warning == nil ? nil : false)
    }

    private static func fileSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
