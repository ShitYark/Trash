import Foundation

/// Поиск установленных программ и данных программ, которых больше нет. Только читает диск.
enum ApplicationsScanner {
    /// Программы из папок программ, кроме системных и самого Trash. Сами не отмечаются.
    static func installed(catalog: ApplicationCatalog) -> CategoryScanResult {
        let ownBundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let items = catalog.applications
            .filter { !$0.isSystem && $0.url.resolvingSymlinksInPath().path != ownBundle }
            .map { application in
                let isRunning = catalog.environment.isRunning(application.url)
                let details = [
                    application.version.map { "версия \($0)" },
                    application.isFromAppStore ? "App Store" : nil,
                    application.isOwnedByRoot ? "нужен пароль администратора" : nil,
                    isRunning ? "запущена — закройте перед удалением" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                return ScanItem(url: application.url, size: CleanupScanner.allocatedSize(of: application.url), category: .installedApplications,
                                title: application.name, details: details.isEmpty ? nil : details, isRecommended: false)
            }
        return CategoryScanResult(category: .installedApplications, items: items, isAccessDenied: false)
    }

    /// Данные программ, которых больше нет. Сам отмечается только уверенный остаток, кроме файлов настроек.
    static func leftovers(home: URL, catalog: ApplicationCatalog) -> CategoryScanResult {
        var isAccessDenied = false
        var items: [ScanItem] = []

        folders: for (folder, kind) in LeftoverPolicy.folders(home: home) {
            guard case let .children(entries) = CleanupScanner.list(folder, accessDenied: &isAccessDenied) else { continue }
            for entry in entries {
                guard !Task.isCancelled else { break folders }
                guard let owner = LeftoverPolicy.owner(ofEntryNamed: entry.lastPathComponent, kind: kind),
                      case let .orphan(confidence) = LeftoverPolicy.status(of: owner, in: catalog) else { continue }

                let isConfident = confidence == .confident
                let reason = switch (kind, confidence) {
                case (.preferences, _): "файл настроек — проверьте, вдруг это утилита без значка"
                case (_, .confident): "программа удалена"
                case (_, .vendorInstalled): "у производителя есть установленные программы — проверьте"
                case (_, .knownToLaunchServices): "macOS помнит программу — возможно, она на отключённом диске или это ваша сборка; проверьте"
                }
                // macOS закрывает чужие Group Containers: без полного доступа к диску размер не узнать и удалить не выйдет.
                var isEntryDenied = false
                if case .denied = CleanupScanner.list(entry, accessDenied: &isEntryDenied) {
                    isAccessDenied = true
                }
                let access = isEntryDenied ? "нет доступа — размер неизвестен, нужен полный доступ к диску" : nil
                items.append(ScanItem(url: entry, size: CleanupScanner.allocatedSize(of: entry), category: .appLeftovers,
                                      details: [kind.title, reason, access].compactMap { $0 }.joined(separator: " · "),
                                      isRecommended: isConfident && kind != .preferences))
            }
        }
        return CategoryScanResult(category: .appLeftovers, items: items, isAccessDenied: isAccessDenied)
    }
}
