import Foundation
import Testing
@testable import Trash

/// Кэши Chromium в данных программ и установщики в Загрузках — во временной «домашней папке».
struct OtherDataTests {
    let base: URL
    let home: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "TrashOtherDataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @Test func chromiumCachesAreFoundOnlyNextToProfile() async throws {
        defer { cleanUp() }
        let support = OtherDataScanner.applicationSupport(home: home)
        // Профиль Chromium: рядом Local State — кэши берём, данные нет.
        try makeFile(support.appending(path: "Slack/Local State"), bytes: 10)
        for folder in ["Cache/Cache_Data/data_0", "Code Cache/js/index", "GPUCache/index", "Local Storage/leveldb/000.log",
                       "Service Worker/CacheStorage/abc/index", "IndexedDB/x/1.log"] {
            try makeFile(support.appending(path: "Slack/\(folder)"), bytes: 1_000)
        }
        try makeFile(support.appending(path: "Figma/DesktopProfile/v37/Preferences"), bytes: 10)
        try makeFile(support.appending(path: "Figma/DesktopProfile/v37/Cache/data_1"), bytes: 1_000)
        // Без признака профиля папка Cache может быть чем угодно; слишком глубоко; остаток; ссылка.
        try makeFile(support.appending(path: "Plain/Cache/important.db"), bytes: 1_000)
        try makeFile(support.appending(path: "Deep/a/b/c/Local State"), bytes: 10)
        try makeFile(support.appending(path: "Deep/a/b/c/Cache/data"), bytes: 1_000)
        try makeFile(support.appending(path: "com.example.gone/Local State"), bytes: 10)
        try makeFile(support.appending(path: "com.example.gone/Cache/data"), bytes: 1_000)
        try makeFile(support.appending(path: "Folder/Preferences/settings"), bytes: 10)
        try makeFile(support.appending(path: "Folder/Cache/data"), bytes: 1_000)
        try makeFile(support.appending(path: "Linked/Local State"), bytes: 10)
        try FileManager.default.createSymbolicLink(at: support.appending(path: "Linked/Cache"), withDestinationURL: support.appending(path: "Plain/Cache"))

        let result = await scanner().scan(.applicationSupportCaches)
        let titles = Set(result.items.map(\.title))
        let safetyGuard = SafetyGuard(home: home)

        #expect(titles == ["Slack · Cache", "Slack · Code Cache", "Slack · GPUCache", "Figma · Cache"])
        #expect(result.items.allSatisfy { $0.isRecommended && $0.isDeletable && !$0.category.autoSelectsRecommended })
        #expect(result.items.allSatisfy { safetyGuard.canDelete($0.url, as: .applicationSupportCaches) })
        for path in ["Slack/Local Storage", "Slack/Service Worker/CacheStorage", "Slack", "Plain/Cache", "Deep/a/b/c/Cache", "Folder/Cache",
                     "com.example.gone/Cache", "Linked/Cache", "Slack/Cache/Cache_Data"] {
            #expect(!safetyGuard.canDelete(support.appending(path: path), as: .applicationSupportCaches), "\(path)")
        }
        #expect(!safetyGuard.canDelete(support.appending(path: "Slack/Cache")), "Application Support — не корень")
    }

    @Test func installersAreOnlyTopLevelDiskImagesAndPackages() async throws {
        defer { cleanUp() }
        let downloads = OtherDataScanner.downloads(home: home)
        try makeFile(downloads.appending(path: "Claude.dmg"), bytes: 1_000)
        try makeFile(downloads.appending(path: "Tool.pkg/Contents/Archive.pax"), bytes: 1_000)
        try makeFile(downloads.appending(path: "Xcode_27.XIP"), bytes: 1_000)
        try makeFile(downloads.appending(path: "Project.zip"), bytes: 1_000)
        try makeFile(downloads.appending(path: "Folder/Nested.dmg"), bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: downloads.appending(path: "Link.dmg"), withDestinationURL: downloads.appending(path: "Claude.dmg"))
        // Папка с расширением .dmg — ваша, не установщик; папкой бывает только .pkg.
        try makeFile(downloads.appending(path: "Photos.dmg/IMG_1.jpg"), bytes: 1_000)

        let result = await scanner().scan(.downloadedInstallers)
        let safetyGuard = SafetyGuard(home: home)

        #expect(Set(result.items.map(\.title)) == ["Claude.dmg", "Tool.pkg", "Xcode_27.XIP"])
        #expect(result.items.allSatisfy { !$0.isRecommended }, "образ диска бывает и вашим — мусором не помечаем")
        #expect(result.items.allSatisfy { safetyGuard.canDelete($0.url, as: .downloadedInstallers) })
        for path in ["Project.zip", "Folder/Nested.dmg", "Link.dmg", "Photos.dmg", ""] {
            #expect(!safetyGuard.canDelete(downloads.appending(path: path), as: .downloadedInstallers), "\(path)")
        }
    }

    /// Настоящий `lsof`: файл, открытый самим тестом, — папка занята; закрытая папка — свободна. `lsof` выходит с 1
    /// и при найденных процессах, поэтому решает вывод.
    @Test func openFilesAreDetectedByOutputNotExitCode() async throws {
        defer { cleanUp() }
        let busy = home.appending(path: "Busy/Cache/data_0")
        let idle = home.appending(path: "Idle/Cache/data_0")
        try makeFile(busy, bytes: 10)
        try makeFile(idle, bytes: 10)
        let handle = try FileHandle(forReadingFrom: busy)
        defer { try? handle.close() }
        let cleaner = Cleaner(safetyGuard: SafetyGuard(home: home))

        #expect(await cleaner.hasOpenFiles(home.appending(path: "Busy")) == true)
        #expect(await cleaner.hasOpenFiles(home.appending(path: "Idle")) == false)
    }

    // MARK: - Helpers

    private func scanner() -> CleanupScanner {
        CleanupScanner(home: home, commandRunner: CommandRunner { _, _ in throw CommandRunner.Failure.exitStatus(1) })
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}
