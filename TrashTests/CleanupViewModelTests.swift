import Foundation
import Testing
@testable import Trash

/// Сводка окна Xcode во view model. Временная «домашняя папка», запуск утилит подменён — реальный диск не трогается.
@MainActor
struct CleanupViewModelTests {
    static let unavailableUDID = "33333333-3333-3333-3333-333333333333"
    /// Формула с двумя старыми версиями, которые убрал бы `brew cleanup`.
    nonisolated static let brewJSON = Data("""
    {"formulae": [{"name": "freetype", "full_name": "freetype", "linked_keg": "2.13.3", "outdated": false, "pinned": false,
      "versions": {"stable": "2.13.3"},
      "installed": [{"version": "2.13.1", "installed_on_request": true}, {"version": "2.13.2", "installed_on_request": true},
                    {"version": "2.13.3", "installed_on_request": true}]}],
     "casks": []}
    """.utf8)

    let base: URL
    let home: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "TrashViewModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @Test func xcodeSummaryCountsOnlyDeletableItemsAsSelected() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz")
        try makeFile(derivedData.appending(path: "Build/app.o"), bytes: 100_000)
        let simulator = home.appending(path: "Library/Developer/CoreSimulator/Devices/\(Self.unavailableUDID)")
        try makeFile(simulator.appending(path: "data/file.bin"), bytes: 300_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()

        let derivedDataSize = CleanupScanner.allocatedSize(of: derivedData)
        let simulatorSize = CleanupScanner.allocatedSize(of: simulator)
        let simulatorItem = try #require(model.result(for: .simulators)?.items.first)

        #expect(model.isScanned(.xcode))
        #expect(simulatorItem.isRecommended, "недоступный симулятор — явный мусор")
        #expect(!model.isSelected(simulatorItem), "но неудаляемый элемент автоскан не отмечает")
        #expect(model.totalSize(of: .xcode) == derivedDataSize + simulatorSize)
        #expect(model.selectedSize(in: .xcode) == derivedDataSize)
    }

    @Test func oldHomebrewVersionsAreSelectedTogether() async throws {
        // `brew` есть — сканер спросит у него JSON; удалит старые версии одна команда, `brew cleanup freetype`.
        try makeFile(base.appending(path: "homebrew/bin/brew"), bytes: 0)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let items = try #require(model.result(for: .homebrew)?.items.filter { $0.removal == .brewCleanup(formula: "freetype") })
        let first = try #require(items.first)
        let last = try #require(items.last)

        #expect(items.count == 2)
        #expect(!model.isSelected(first), "сам не отмечается")
        model.setSelected(true, for: first)
        #expect(model.isSelected(last), "отметка одной старой версии отмечает все, что удалит brew cleanup")
        model.setSelected(false, for: last)
        #expect(!model.isSelected(first))
    }

    @Test func managerSectionIsSelectableButNotAutomatically() async throws {
        let simulator = home.appending(path: "Library/Developer/CoreSimulator/Devices/\(Self.unavailableUDID)")
        try makeFile(simulator.appending(path: "data/file.bin"), bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let item = try #require(model.result(for: .simulators)?.items.first)

        #expect(item.isRecommended && !model.isSelected(item), "мусор, но сам не отмечен: удаление через simctl необратимо")
        model.setSelected(true, for: item)
        #expect(model.isSelected(item), "отметить вручную можно")
        #expect(model.unmarkedJunkSize == 0)
    }

    @Test func searchOnlyItemsCannotBeSelected() async throws {
        // Служба удалённой программы — мусор, её можно отметить; работающая — только поиск.
        try writePlist(["Label": "com.example.gone", "Program": "/nonexistent/gone"],
                       to: home.appending(path: "Library/LaunchAgents/com.example.gone.plist"))
        try writePlist(["Label": "com.example.alive", "Program": "/bin/sh"],
                       to: home.appending(path: "Library/LaunchAgents/com.example.alive.plist"))
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let items = try #require(model.result(for: .backgroundServices)?.items)
        let gone = try #require(items.first { $0.title == "com.example.gone" })
        let alive = try #require(items.first { $0.title == "com.example.alive" })

        #expect(gone.isRecommended && !model.isSelected(gone), "мусор, но сам не отмечается")
        #expect(model.unmarkedJunkSize(in: .terminal) == gone.size)
        #expect(model.selectAllSources(for: .backgroundServices).count == 1, "«выбрать всё» — только по удаляемым")
        model.setSelected(true, for: alive)
        model.setSelected(true, for: gone)
        #expect(!model.isSelected(alive) && model.isSelected(gone))
    }

    @Test func partialSelectionIsVisibleInSectionSummary() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
        try makeFile(derivedData.appending(path: "One-abc/file.o"), bytes: 100_000)
        try makeFile(derivedData.appending(path: "Two-xyz/file.o"), bytes: 200_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let sources = model.selectAllSources(for: .xcodeDerivedData)
        let result = try #require(model.result(for: .xcodeDerivedData))
        let first = try #require(result.items.first)
        model.setSelected(false, for: first)

        #expect(sources.count == 2)
        #expect(sources.filter(\.wrappedValue).count == 1, "частичный выбор — смешанный чекбокс")
        #expect(model.selectedSize(in: .xcodeDerivedData) == result.totalSize - first.size)
    }

    @Test func applicationInTwoSectionsIsSelectedAndCountedOnce() async throws {
        let applications = base.appending(path: "Applications", directoryHint: .isDirectory)
        let copy = applications.appending(path: "Xcode-beta.app", directoryHint: .isDirectory)
        try makeFile(copy.appending(path: "Contents/MacOS/Xcode"), bytes: 10_000)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
            .write(to: copy.appending(path: "Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let item = try #require(model.result(for: .installedApplications)?.items.first { $0.url.lastPathComponent == "Xcode-beta.app" })
        #expect(model.result(for: .xcodeApplications)?.items.contains { $0.id == item.id } == true, "одна копия — в двух разделах")
        model.setSelected(true, for: item)

        #expect(model.selectedItems.filter { $0.id == item.id }.count == 1)
        #expect(model.selectedSize(in: .applications) == item.size)
        #expect(model.selectedSize(in: .xcode) == item.size)

        model.selectedItem = .group(.applications)
        #expect(model.cleanupItems.filter { $0.id == item.id }.count == 1, "копия — в области «Программ», один раз")
        model.selectedItem = .group(.xcode)
        #expect(model.cleanupItems.filter { $0.id == item.id }.count == 1, "и в области «Xcode», тоже один раз")
    }

    @Test func emptyTerminalSectionsAreHiddenButFailuresStay() async throws {
        try makeFile(home.appending(path: ".gradle/caches/modules-2/file.jar"), bytes: 10_000)
        // `brew` есть, но отвечает не тем — раздел с причиной «brew не ответил» должен остаться.
        try makeFile(base.appending(path: "homebrew/bin/brew"), bytes: 0)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel(brew: Data("{".utf8))
        await model.scan()
        let visible = model.visibleCategories(in: .terminal)

        #expect(visible.contains(.gradle), "найденное видно")
        #expect(visible.contains(.homebrew), "ошибка видна, чтобы было понятно, что раздел не досчитался")
        #expect(model.result(for: .homebrew)?.unavailableReason != nil)
        #expect(!visible.contains(.androidSDK), "Android SDK нет — раздела нет")
        #expect(!visible.contains(.languageVersions), "менеджеров версий нет — раздела нет")
        #expect(model.visibleCategories(in: .xcode) == CategoryGroup.xcode.categories, "в Xcode пустые разделы не скрываются")
    }

    @Test func cleanupScopeFollowsCurrentScreen() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz")
        try makeFile(derivedData.appending(path: "Build/app.o"), bytes: 100_000)
        let cache = home.appending(path: "Library/Caches/com.example.app")
        try makeFile(cache.appending(path: "data.bin"), bytes: 40_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let derivedDataSize = CleanupScanner.allocatedSize(of: derivedData)
        let cacheSize = CleanupScanner.allocatedSize(of: cache)

        model.selectedItem = .overview
        #expect(model.cleanupSize == model.selectedSize, "на «Обзоре» — всё отмеченное")
        #expect(model.cleanupSize == derivedDataSize + cacheSize)

        model.selectedItem = nil
        #expect(model.cleanupSize == derivedDataSize + cacheSize, "без выбранного пункта — как «Обзор»")

        model.selectedItem = .category(.userCaches)
        #expect(model.cleanupSize == cacheSize, "на экране категории — только она")

        model.selectedItem = .group(.xcode)
        #expect(model.cleanupSize == derivedDataSize, "на экране группы — только её разделы")

        model.selectedItem = .group(.applications)
        #expect(model.cleanupItems.isEmpty, "в «Программах» ничего не отмечено — отметки других разделов не считаются")
    }

    @Test func cleaningOnGroupScreenKeepsOtherSectionsSelection() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz")
        try makeFile(derivedData.appending(path: "Build/app.o"), bytes: 100_000)
        let cache = home.appending(path: "Library/Caches/com.example.app")
        try makeFile(cache.appending(path: "data.bin"), bytes: 40_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let cacheItem = try #require(model.result(for: .userCaches)?.items.first { $0.url.lastPathComponent == "com.example.app" })
        #expect(model.isSelected(cacheItem), "кэш отмечен автосканом")

        model.selectedItem = .group(.xcode)
        await model.cleanSelected(permanently: true)

        #expect(!FileManager.default.fileExists(atPath: derivedData.path), "DerivedData на экране Xcode удалена")
        #expect(FileManager.default.fileExists(atPath: cache.path), "кэш из «Системы» не тронут")
        #expect(model.isSelected(cacheItem), "и остаётся отмеченным")
        #expect(model.lastReport?.removed.count == 1)
    }

    @Test func overviewIsSelectedAtLaunch() throws {
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()

        #expect(model.selectedItem == .overview)
    }

    @Test func foundSizeCountsApplicationInTwoSectionsOnce() async throws {
        let copy = base.appending(path: "Applications/Xcode-beta.app", directoryHint: .isDirectory)
        try makeFile(copy.appending(path: "Contents/MacOS/Xcode"), bytes: 10_000)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
            .write(to: copy.appending(path: "Contents/Info.plist"))
        try makeFile(home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz/Build/app.o"), bytes: 50_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let item = try #require(model.result(for: .installedApplications)?.items.first { $0.url.lastPathComponent == "Xcode-beta.app" })
        let sumOfSections = CleanupCategory.allCases.reduce(Int64(0)) { $0 + (model.result(for: $1)?.totalSize ?? 0) }

        #expect(model.result(for: .xcodeApplications)?.items.contains { $0.id == item.id } == true)
        #expect(model.foundSize == sumOfSections - item.size, "копия Xcode из двух разделов — в «найдено» один раз")
    }

    @Test func unmarkedJunkIsCountedSeparatelyFromWhatCanBeFreed() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz")
        try makeFile(derivedData.appending(path: "Build/app.o"), bytes: 100_000)
        let simulator = home.appending(path: "Library/Developer/CoreSimulator/Devices/\(Self.unavailableUDID)")
        try makeFile(simulator.appending(path: "data/file.bin"), bytes: 300_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let model = try makeModel()
        await model.scan()
        let simulatorSize = CleanupScanner.allocatedSize(of: simulator)

        #expect(model.unmarkedJunkSize == simulatorSize, "недоступный симулятор — мусор, который сам не отмечается")
        #expect(model.unmarkedJunkSize(in: .xcode) == simulatorSize)
        #expect(model.unmarkedJunkSize(in: .terminal) == 0)
        #expect(model.selectedSize == CleanupScanner.allocatedSize(of: derivedData), "«можно освободить» — только удаляемое")
    }

    @Test func diskSpaceIsReadOnScanAndAfterCleaning() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData/Gone-xyz")
        try makeFile(derivedData.appending(path: "Build/app.o"), bytes: 100_000)
        defer { try? FileManager.default.removeItem(at: base) }

        let reads = ReadCounter()
        let model = try makeModel {
            let read = await reads.next()
            return DiskSpace(name: "Test", total: 1_000, available: Int64(read) * 100)
        }
        await model.scan()

        #expect(model.disk == DiskSpace(name: "Test", total: 1_000, available: 100))
        #expect(model.disk?.used == 900)

        await model.cleanSelected(permanently: true)

        #expect(!FileManager.default.fileExists(atPath: derivedData.path), "удалено во временной папке")
        #expect(model.disk?.available == 200, "после очистки место на диске перечитано")
        #expect(model.lastReport?.deletedPermanently == model.lastReport?.removed.count, "отчёт знает, что удалено навсегда")
    }

    // MARK: - Helpers

    private func makeModel(brew: Data = Self.brewJSON,
                           diskSpace: @escaping @Sendable () async -> DiskSpace? = { nil }) throws -> CleanupViewModel {
        let developer = base.appending(path: "Xcode.app/Contents/Developer", directoryHint: .isDirectory)
        try makeFile(developer.appending(path: "usr/bin/simctl"), bytes: 0)
        let applications = base.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        let devices = Data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-15-5": [
          {"udid": "\(Self.unavailableUDID)", "name": "iPhone 8", "state": "Shutdown", "isAvailable": false}
        ]}}
        """.utf8)
        let developerPath = developer.path
        let runner = CommandRunner { executable, arguments in
            if executable == XcodeScanner.xcodeSelect { return Data(developerPath.utf8) }
            if executable.hasSuffix("/brew") { return brew }
            return arguments.contains("runtime") ? Data("{}".utf8) : devices
        }
        // Все системные папки — временные: полный скан не читает реальные /usr/local и /Library.
        let system = SystemLocations(applications: applications, usrLocal: base.appending(path: "usr-local"),
                                     library: base.appending(path: "Library"), systemApplications: [],
                                     homebrewPrefixes: [base.appending(path: "homebrew")],
                                     opt: base.appending(path: "opt"), macPortsPrefix: base.appending(path: "opt-local"))
        let noApplications = ApplicationEnvironment(lookup: { _ in nil }, signature: { _ in CodeSignature() }, isRunning: { _ in false })
        let scanner = CleanupScanner(home: home, system: system, commandRunner: runner, applications: noApplications)
        // Удаление через менеджер — тем же подменённым simctl: тесты не доходят до настоящего.
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home))
        let simctl = developer.appending(path: "usr/bin/simctl").path
        cleaner.remover = ManagerRemover(runner: runner, simctl: { simctl }, brew: { nil })
        return CleanupViewModel(scanner: scanner, cleaner: cleaner, diskSpace: diskSpace)
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }
}

/// Считает чтения места на диске: каждое следующее возвращает новое значение.
private actor ReadCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
