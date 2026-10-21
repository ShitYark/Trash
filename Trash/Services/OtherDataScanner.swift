import Foundation

/// То, что прятали «остальные данные»: кэши Chromium внутри `~/Library/Application Support` и установщики
/// в Загрузках. Правила общие для скана и для `SafetyGuard`.
enum OtherDataScanner {
    /// Папки, которые Chromium и Electron пересоздают сами: HTTP-кэш, кэш V8, кэши GPU и шейдеров; у VS Code
    /// и его форков — кэш кода, скачанные расширения и манифесты профилей. `Service Worker` — нет: там данные сайтов.
    static let cacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache", "ShaderCache",
        "GrShaderCache", "GraphiteDawnCache", "GPUPersistentCache", "CachedData", "CachedExtensionVSIXs", "CachedProfilesData",
    ]
    /// Признак профиля Chromium рядом с кэшем: без него папка `Cache` может быть чем угодно.
    static let profileMarkers = ["Local State", "Preferences"]
    /// Глубина кэша от `Application Support`: `Slack/Cache` — 2, `Figma/DesktopProfile/v37/Cache` — 4.
    static let maxDepth = 4
    static let installerExtensions: Set<String> = ["dmg", "pkg", "xip"]

    static func applicationSupport(home: URL) -> URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    static func downloads(home: URL) -> URL {
        home.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    /// Кэши Chromium по программам. Папки остатков удалённых программ — с именем-идентификатором — пропускаются:
    /// их целиком показывают «Остатки», иначе место посчиталось бы дважды.
    static func applicationCaches(home: URL) -> CategoryScanResult {
        let root = applicationSupport(home: home)
        var isAccessDenied = false
        var items: [ScanItem] = []
        guard case let .children(programs) = CleanupScanner.list(root, accessDenied: &isAccessDenied) else {
            return CategoryScanResult(category: .applicationSupportCaches, items: [], isAccessDenied: isAccessDenied)
        }
        for program in programs where isPlainFolder(program) && LeftoverPolicy.owner(ofEntryNamed: program.lastPathComponent, kind: .applicationSupport) == nil {
            for cache in caches(in: program, depth: 2) {
                let path = cache.path.dropFirst(root.path.count + 1)
                items.append(ScanItem(url: cache, size: CleanupScanner.allocatedSize(of: cache), category: .applicationSupportCaches,
                                      title: "\(program.lastPathComponent) · \(cache.lastPathComponent)",
                                      details: "\(path) · программа создаст заново", isRecommended: true))
            }
        }
        return CategoryScanResult(category: .applicationSupportCaches, items: items, isAccessDenied: isAccessDenied)
    }

    /// `.dmg`, `.pkg`, `.xip` прямо в Загрузках; вложенные папки — ваши, туда не заходим.
    static func installers(home: URL) -> CategoryScanResult {
        var isAccessDenied = false
        guard case let .children(entries) = CleanupScanner.list(downloads(home: home), accessDenied: &isAccessDenied) else {
            return CategoryScanResult(category: .downloadedInstallers, items: [], isAccessDenied: isAccessDenied)
        }
        let items = entries.filter(isInstallerCandidate).map { installer in
            let kind = switch installer.pathExtension.lowercased() {
            case "dmg": "образ диска"
            case "pkg": "установщик"
            default: "архив Xcode"
            }
            // Без метки «мусор»: образ диска бывает и вашим — например, зашифрованным с документами.
            return ScanItem(url: installer, size: CleanupScanner.allocatedSize(of: installer), category: .downloadedInstallers,
                            details: kind, isRecommended: false)
        }
        return CategoryScanResult(category: .downloadedInstallers, items: items, isAccessDenied: isAccessDenied)
    }

    /// Кэш Chromium: имя из списка, рядом признак профиля, не глубже `maxDepth` от `Application Support`,
    /// не ссылка и не скрытое; верхняя папка — не остаток удалённой программы.
    static func isApplicationCache(_ url: URL, applicationSupport: URL) -> Bool {
        let root = applicationSupport.pathComponents
        let components = url.pathComponents
        guard components.count > root.count + 1, components.starts(with: root),
              components.count - root.count <= maxDepth,
              !components.dropFirst(root.count).contains(where: { $0.hasPrefix(".") }),
              let program = components.dropFirst(root.count).first,
              LeftoverPolicy.owner(ofEntryNamed: program, kind: .applicationSupport) == nil else { return false }
        return cacheNames.contains(url.lastPathComponent) && isPlainFolder(url) && hasProfileMarker(url.deletingLastPathComponent())
    }

    /// Установщик прямо в Загрузках: нужное расширение, не ссылка. `.pkg` бывает и папкой-пакетом.
    static func isInstaller(_ url: URL, downloads: URL) -> Bool {
        url.deletingLastPathComponent().path == downloads.path && isInstallerCandidate(url)
    }

    /// Папка программы в `Application Support`, к которой относится кэш, — её проверяют на открытые файлы.
    static func programFolder(of cache: URL, applicationSupport: URL) -> URL? {
        let root = applicationSupport.pathComponents
        let components = cache.pathComponents
        guard components.count > root.count + 1, components.starts(with: root) else { return nil }
        return applicationSupport.appending(path: components[root.count], directoryHint: .isDirectory)
    }

    /// Кэши в папке — внутрь кэша не спускаемся.
    private static func caches(in folder: URL, depth: Int) -> [URL] {
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter(isPlainFolder)
        let hasMarker = hasProfileMarker(folder)
        var found: [URL] = []
        for child in children {
            if hasMarker, cacheNames.contains(child.lastPathComponent) {
                found.append(child)
            } else if depth < maxDepth {
                found += caches(in: child, depth: depth + 1)
            }
        }
        return found
    }

    /// Признак — обычный файл, не папка и не ссылка: так их создаёт Chromium.
    private static func hasProfileMarker(_ folder: URL) -> Bool {
        profileMarkers.contains { name in
            let values = try? folder.appending(path: name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
    }

    /// Обычная папка: не ссылка и не скрытая.
    private static func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return !url.lastPathComponent.hasPrefix(".") && values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Файл с нужным расширением; папкой бывает только `.pkg` — пакет-бандл. Папка `x.dmg` — ваша, не установщик.
    private static func isInstallerCandidate(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        let fileExtension = url.pathExtension.lowercased()
        let isAllowedKind = values?.isRegularFile == true || (fileExtension == "pkg" && values?.isDirectory == true)
        return !url.lastPathComponent.hasPrefix(".") && values?.isSymbolicLink != true && isAllowedKind
            && installerExtensions.contains(fileExtension)
    }
}
