import Foundation

extension URL {
    /// Путь без `.`/`..` и без симлинков в существующей части; недостающий хвост — как есть.
    /// `/var/…/нет-файла` и `/private/var/…/нет-файла` дают одну форму — так сравниваются и ещё не созданные пути, и битые ссылки.
    var canonicalFileURL: URL {
        var existing = standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }
    }
}
