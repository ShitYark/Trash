import Foundation
import Testing
@testable import Trash

/// Тесты работают в отдельной временной «домашней папке», реальные файлы пользователя не трогаются.
struct ScannerAndCleanerTests {
    let home: URL
    let caches: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "TrashTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        caches = home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    @Test func scannerFindsChildrenSortedBySize() async throws {
        try makeFile(caches.appending(path: "small/a.bin"), bytes: 10_000)
        try makeFile(caches.appending(path: "big/b.bin"), bytes: 500_000)
        try makeFile(caches.appending(path: ".DS_Store"), bytes: 100)
        defer { cleanUp() }

        let result = await CleanupScanner(home: home).scan(.userCaches)

        #expect(result.items.map(\.title) == ["big", "small"])
        #expect(result.items[0].size >= 500_000)
        #expect(!result.isAccessDenied)
    }

    @Test func hardLinkedFileIsCountedOnce() throws {
        let folder = caches.appending(path: "linked")
        let original = folder.appending(path: "original.bin")
        let other = folder.appending(path: "other.bin")
        try makeFile(original, bytes: 200_000)
        try makeFile(other, bytes: 50_000)
        try FileManager.default.linkItem(at: original, to: folder.appending(path: "hardlink.bin"))
        defer { cleanUp() }

        let expected = CleanupScanner.allocatedSize(of: original) + CleanupScanner.allocatedSize(of: other)

        #expect(CleanupScanner.allocatedSize(of: folder) == expected, "жёсткая ссылка не занимает место второй раз — как у du")
    }

    @Test func scannerReturnsEmptyResultForMissingFolder() async {
        defer { cleanUp() }
        let result = await CleanupScanner(home: home).scan(.xcodeDerivedData)
        #expect(result.items.isEmpty)
        #expect(!result.isAccessDenied)
    }

    @Test func cleanerDeletesAllowedItems() async throws {
        let target = caches.appending(path: "com.example.app")
        try makeFile(target.appending(path: "data.bin"), bytes: 1_000)
        defer { cleanUp() }

        let item = ScanItem(url: target, size: 1_000, category: .userCaches)
        let report = await Cleaner(safetyGuard: SafetyGuard(home: home)).clean([item], permanently: true)

        #expect(report.removed == [target])
        #expect(report.deletedPermanently == 1 && report.movedToTrash == 0)
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func cleanerRefusesItemsOutsideAllowedRoots() async throws {
        let outside = home.appending(path: "Documents/keep.txt")
        try makeFile(outside, bytes: 100)
        defer { cleanUp() }

        let item = ScanItem(url: outside, size: 100, category: .userCaches)
        let report = await Cleaner(safetyGuard: SafetyGuard(home: home)).clean([item], permanently: true)

        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func cleanerRefusesSearchOnlyCategoriesEvenIfGuardAllows() async throws {
        let image = home.appending(path: "Library/Android/sdk/system-images/android-36")
        try makeFile(image.appending(path: "data/file.bin"), bytes: 100)
        defer { cleanUp() }

        // Страж намеренно пускает все корни, включая Android SDK: отказать обязан сам Cleaner.
        let permissiveGuard = SafetyGuard(categories: CleanupCategory.allCases, home: home)
        let item = ScanItem(url: image, size: 100, category: .androidSDK)
        let report = await Cleaner(safetyGuard: permissiveGuard).clean([item], permanently: true)

        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func cleanerRemovesTerminalCachesButKeepsSettingsNextToThem() async throws {
        let gradleCache = home.appending(path: ".gradle/caches/modules-2")
        let npmCache = home.appending(path: ".npm/_cacache/content-v2")
        let settings = [home.appending(path: ".gradle/gradle.properties"), home.appending(path: ".npm/_logs/debug.log"),
                        home.appending(path: ".npmrc")]
        try makeFile(gradleCache.appending(path: "files.bin"), bytes: 1_000)
        try makeFile(npmCache.appending(path: "blob"), bytes: 1_000)
        for file in settings {
            try makeFile(file, bytes: 10)
        }
        defer { cleanUp() }

        let scanner = CleanupScanner(home: home)
        let items = await scanner.scan(.gradle).items + scanner.scan(.toolCaches).items
        let report = await Cleaner(safetyGuard: SafetyGuard(home: home)).clean(items, permanently: true)

        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: gradleCache.path))
        #expect(!FileManager.default.fileExists(atPath: npmCache.path))
        #expect(settings.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "настройки рядом с кэшами на месте")
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }
}
