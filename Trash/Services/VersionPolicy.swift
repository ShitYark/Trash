import Foundation

/// Правило «оставить самую свежую версию»: Device Support, build-tools Android, дистрибутивы Gradle.
enum VersionPolicy {
    /// Первое число с точкой в имени: `iPhone14,3 18.5 (22F76)` → `[18, 5]`, `gradle-8.13-bin` → `[8, 13]`.
    /// Числа без точки (`android-36`) версией не считаются — такое имя не разобрать.
    static func version(in name: String) -> [Int]? {
        guard let match = name.firstMatch(of: #/(\d+(?:\.\d+)+)/#) else { return nil }
        return match.1.split(separator: ".").compactMap { Int($0) }
    }

    /// Отмечает все версии в каждой группе, кроме самой свежей. Версию не разобрать — элемент не отмечается.
    /// - Parameters:
    ///   - group: ключ группы — например, папка платформы; свежесть сравнивается только внутри группы.
    ///   - newestNote: дописывается в подпись самой свежей версии.
    static func recommendingAllButNewest(
        _ items: [ScanItem],
        groupedBy group: (ScanItem) -> String,
        newestNote: String = "самая свежая"
    ) -> [ScanItem] {
        var newest: [String: [Int]] = [:]
        for item in items {
            guard let version = version(in: item.url.lastPathComponent) else { continue }
            let key = group(item)
            if newest[key].map({ $0.lexicographicallyPrecedes(version) }) ?? true {
                newest[key] = version
            }
        }

        return items.map { item in
            guard let version = version(in: item.url.lastPathComponent), let newestVersion = newest[group(item)] else {
                return item.with(details: item.details, isRecommended: false)
            }
            let isNewest = version == newestVersion
            let details = [item.details, isNewest ? newestNote : nil].compactMap { $0 }.joined(separator: " · ")
            return item.with(details: details, isRecommended: !isNewest)
        }
    }
}
