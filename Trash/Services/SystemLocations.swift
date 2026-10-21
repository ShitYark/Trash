import Foundation

/// Системные папки вне домашней. Сканер их только читает: корнями категорий они не становятся,
/// поэтому `SafetyGuard` никогда не разрешит удалять в них файлы. Пакеты Homebrew удаляет сам `brew`
/// через `ManagerRemover`, программы — Корзина. В тестах подменяются временными папками.
struct SystemLocations: Sendable {
    var applications = URL(filePath: "/Applications", directoryHint: .isDirectory)
    var usrLocal = URL(filePath: "/usr/local", directoryHint: .isDirectory)
    var library = URL(filePath: "/Library", directoryHint: .isDirectory)
    /// Системные программы: их не показываем и не удаляем, но их данные и группы — не остатки.
    var systemApplications = [
        URL(filePath: "/System/Applications", directoryHint: .isDirectory),
        URL(filePath: "/System/Library/CoreServices", directoryHint: .isDirectory),
    ]
    /// Где искать Homebrew: Apple Silicon, затем Intel.
    var homebrewPrefixes = [
        URL(filePath: "/opt/homebrew", directoryHint: .isDirectory),
        URL(filePath: "/usr/local", directoryHint: .isDirectory),
    ]

    /// Установки conda по умолчанию от `.pkg`: `/opt/miniconda3`, `/opt/anaconda3`.
    var opt = URL(filePath: "/opt", directoryHint: .isDirectory)
    /// Префикс MacPorts.
    var macPortsPrefix = URL(filePath: "/opt/local", directoryHint: .isDirectory)

    /// Префикс установленного Homebrew — первый, где есть `bin/brew`.
    var homebrewPrefix: URL? {
        homebrewPrefixes.first { FileManager.default.fileExists(atPath: $0.appending(path: "bin/brew").path) }
    }
}
