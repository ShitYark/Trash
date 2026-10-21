import Foundation

/// Объём и свободное место тома — для виджета диска и «станет свободно после очистки».
struct DiskSpace: Sendable, Equatable {
    let name: String
    let total: Int64
    /// Свободно с учётом места, которое macOS освободит сама, — как в Finder.
    let available: Int64

    var used: Int64 { max(0, total - available) }

    /// Том, на котором лежит `url`. `nil`, если macOS не отдала значения.
    @concurrent
    static func current(for url: URL) async -> DiskSpace? {
        // `URL` кэширует значения ресурсов: без сброса после очистки вернётся место на момент первого чтения.
        var url = url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return DiskSpace(name: values.volumeName ?? "Диск", total: Int64(total), available: available)
    }
}
