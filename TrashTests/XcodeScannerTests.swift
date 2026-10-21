import Foundation
import Testing
@testable import Trash

/// Поиск мусора Xcode. Работает во временной «домашней папке»; `xcrun` и `xcode-select`
/// подменены заготовленными ответами — реальные симуляторы и Xcode пользователя не трогаются.
struct XcodeScannerTests {
    static let bootedUDID = "11111111-1111-1111-1111-111111111111"
    static let idleUDID = "22222222-2222-2222-2222-222222222222"
    static let unavailableUDID = "33333333-3333-3333-3333-333333333333"
    static let bootedUnavailableUDID = "44444444-4444-4444-4444-444444444444"
    static let orphanUDID = "55555555-5555-5555-5555-555555555555"

    /// Структура — как у `xcrun simctl list devices -j` в Xcode 27.
    static let devicesJSON = Data("""
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          {"udid": "\(bootedUDID)", "name": "iPhone 17", "state": "Booted", "isAvailable": true,
           "lastUsedAt": "2026-10-10T09:00:00Z", "dataPath": "/x", "dataPathSize": 100, "logPath": "/y",
           "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
          {"udid": "\(idleUDID)", "name": "iPad Pro", "state": "Shutdown", "isAvailable": true,
           "lastUsedAt": "2026-09-25T10:28:15.123Z"}
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-15-5": [
          {"udid": "\(unavailableUDID)", "name": "iPhone 8", "state": "Shutdown", "isAvailable": false,
           "availabilityError": "runtime profile not found"},
          {"udid": "\(bootedUnavailableUDID)", "name": "iPhone SE", "state": "Booted", "isAvailable": false}
        ]
      }
    }
    """.utf8)

    /// Структура — как у `xcrun simctl runtime list -j` в Xcode 27.
    static let runtimesJSON = Data("""
    {
      "AAAA": {"identifier": "AAAA", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
               "version": "27.0", "build": "24A434", "sizeBytes": 9000000000, "deletable": true,
               "lastUsedAt": "2026-10-10T09:00:00Z", "mountPath": "/Library/Developer/CoreSimulator/Volumes/iOS_24A434",
               "state": "Ready"},
      "BBBB": {"identifier": "BBBB", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-3",
               "version": "18.3.1", "build": "22D8075", "sizeBytes": 8708125252, "deletable": true,
               "mountPath": "/Library/Developer/CoreSimulator/Volumes/iOS_22D8075", "state": "Ready"},
      "CCCC": {"identifier": "CCCC", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5",
               "version": "17.5", "build": "21F79", "sizeBytes": 7000000000, "deletable": false,
               "kind": "Legacy Download", "state": "Ready",
               "runtimeBundlePath": "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 17.5.simruntime"}
    }
    """.utf8)

    let home: URL
    let applications: URL
    let developer: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "TrashXcodeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        applications = base.appending(path: "Applications", directoryHint: .isDirectory)
        developer = base.appending(path: "Xcode.app/Contents/Developer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: developer.appending(path: "usr/bin"), withIntermediateDirectories: true)
        try Data().write(to: developer.appending(path: "usr/bin/simctl"))
    }

    // MARK: - simctl

    @Test func devicesAreParsedFromSimctlJSON() throws {
        defer { cleanUp() }
        let devices = try SimulatorCatalog.devices(from: Self.devicesJSON)
        let idle = try #require(devices.first { $0.udid == Self.idleUDID })

        #expect(devices.count == 4)
        #expect(idle.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(idle.lastUsedAt != nil, "дата с долями секунды тоже разбирается")
        #expect(devices.first { $0.udid == Self.unavailableUDID }?.isAvailable == false)
        #expect(devices.first { $0.udid == Self.bootedUDID }?.isBooted == true)
    }

    @Test func runtimeNamesAreReadable() {
        defer { cleanUp() }
        #expect(SimulatorCatalog.displayName(ofRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0") == "iOS 27.0")
        #expect(SimulatorCatalog.displayName(ofRuntime: "com.apple.CoreSimulator.SimRuntime.xrOS-2-0") == "visionOS 2.0")
        #expect(SimulatorCatalog.platform(ofRuntime: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == "watchOS")
    }

    @Test func simulatorsRecommendUnavailableAndOrphans() async throws {
        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
        for udid in [Self.bootedUDID, Self.idleUDID, Self.unavailableUDID, Self.bootedUnavailableUDID, Self.orphanUDID] {
            try makeFile(devices.appending(path: "\(udid)/data/file.bin"), bytes: 1_000)
        }
        try makeFile(devices.appending(path: "device_set.plist"), bytes: 10)
        try makeFile(devices.appending(path: "not-a-uuid/file.bin"), bytes: 10)
        defer { cleanUp() }

        let result = await scanner().scan(.simulators)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.url.lastPathComponent))

        #expect(result.items.count == 5, "4 симулятора из simctl + 1 папка-сирота")
        #expect(recommended == [Self.unavailableUDID, Self.orphanUDID])
        #expect(result.items.allSatisfy { $0.isDeletable })
        #expect(result.items.first { $0.url.lastPathComponent == Self.idleUDID }?.removal == .simulator(udid: Self.idleUDID), "симулятор удаляет simctl")
        #expect(result.items.first { $0.url.lastPathComponent == Self.orphanUDID }?.removal == nil, "папку без симулятора — файлами")
        #expect(result.items.first { $0.url.lastPathComponent == Self.bootedUDID }?.details?.contains("запущен") == true)
    }

    @Test func simulatorsWithoutSimctlAreNotGuessed() async throws {
        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
        try makeFile(devices.appending(path: "\(Self.orphanUDID)/file.bin"), bytes: 10)
        defer { cleanUp() }

        let result = await scanner(devices: nil).scan(.simulators)

        #expect(result.items.isEmpty, "без списка simctl нельзя отличить сироту от симулятора")
        #expect(result.unavailableReason == XcodeScanner.simctlFailedReason)
    }

    @Test func simctlIsNotRunWithoutXcode() async {
        defer { cleanUp() }
        let noXcode = scanner(developerDirectory: nil)

        let simulators = await noXcode.scan(.simulators)
        let runtimes = await noXcode.scan(.simulatorRuntimes)

        #expect(simulators.unavailableReason == XcodeScanner.noXcodeReason, "до simctl дело не дошло")
        #expect(runtimes.unavailableReason == XcodeScanner.noXcodeReason)
    }

    @Test func runtimesRecommendOnlyUnusedDeletable() async {
        defer { cleanUp() }
        let result = await scanner().scan(.simulatorRuntimes)
        let unused = result.items.first { $0.title == "iOS 18.3.1" }

        #expect(result.items.count == 3)
        #expect(result.items.filter { $0.isRecommended }.map { $0.title } == ["iOS 18.3.1"])
        #expect(unused?.size == 8_708_125_252)
        #expect(unused?.details?.contains("не нужен ни одному симулятору") == true)
        #expect(unused?.isDeletable == true)
        #expect(result.items.allSatisfy { $0.isDeletable == ($0.removal != nil) }, "встроенный рантайм удалить нельзя — операции нет")
        #expect(result.items.first { $0.title == "iOS 17.5" }?.url.path == "/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 17.5.simruntime")
    }

    @Test func runtimesWithoutDeviceListRecommendNothing() async {
        defer { cleanUp() }
        let result = await scanner(devices: nil).scan(.simulatorRuntimes)

        #expect(result.items.count == 3)
        #expect(result.items.allSatisfy { !$0.isRecommended })
    }

    // MARK: - Файлы Xcode

    @Test func derivedDataNamesProjectsAndMarksMissingOnes() async throws {
        let derivedData = home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
        let existingProject = home.appending(path: "Projects/App.xcodeproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existingProject, withIntermediateDirectories: true)
        try writePlist(["WorkspacePath": existingProject.path], to: derivedData.appending(path: "App-abc/info.plist"))
        try writePlist(["WorkspacePath": home.appending(path: "Projects/Gone.xcodeproj").path],
                       to: derivedData.appending(path: "Gone-xyz/info.plist"))
        try makeFile(derivedData.appending(path: "ModuleCache.noindex/module.pcm"), bytes: 1_000)
        defer { cleanUp() }

        let result = await scanner().scan(.xcodeDerivedData)
        let byTitle = Dictionary(uniqueKeysWithValues: result.items.map { ($0.title, $0) })

        #expect(Set(byTitle.keys) == ["App", "Gone", "ModuleCache.noindex"])
        #expect(byTitle["Gone"]?.details?.contains("проекта больше нет") == true)
        #expect(byTitle["App"]?.details?.contains("проекта больше нет") == false)
        #expect(byTitle["ModuleCache.noindex"]?.details == "Общий кэш сборки Xcode")
        #expect(result.items.allSatisfy { $0.isRecommended && $0.isDeletable })
    }

    @Test func deviceSupportKeepsNewestVersionPerPlatform() async throws {
        let xcode = home.appending(path: "Library/Developer/Xcode", directoryHint: .isDirectory)
        for folder in ["iOS DeviceSupport/iPhone14,3 18.5 (22F76)", "iOS DeviceSupport/iPad13,16 26.4.2 (23E261)",
                       "iOS DeviceSupport/17.5 (21F79) arm64e", "watchOS DeviceSupport/Watch6,1 10.1 (21S71)"] {
            try makeFile(xcode.appending(path: "\(folder)/Symbols/file.bin"), bytes: 1_000)
        }
        defer { cleanUp() }

        let result = await scanner().scan(.xcodeDeviceSupport)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(result.items.count == 4)
        #expect(recommended == ["iPhone14,3 18.5 (22F76)", "17.5 (21F79) arm64e"], "самая свежая версия каждой платформы остаётся")
        #expect(VersionPolicy.version(in: "iPad13,16 26.4.2 (23E261)") == [26, 4, 2])
    }

    @Test func archivesShowAppAndVersionAndAreNotRecommended() async throws {
        let archive = home.appending(path: "Library/Developer/Xcode/Archives/2026-10-01/App 01.10.2026.xcarchive")
        try writePlist([
            "Name": "App",
            "CreationDate": try Date("2026-10-01T12:00:00Z", strategy: .iso8601),
            "ApplicationProperties": ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"],
        ], to: archive.appending(path: "Info.plist"))
        defer { cleanUp() }

        let result = await scanner().scan(.xcodeArchives)
        let item = try #require(result.items.first)

        #expect(result.items.count == 1)
        #expect(item.title == "App")
        #expect(item.details?.contains("версия 1.2 (34)") == true)
        #expect(item.details?.contains("окт") == true, "дата по-русски")
        #expect(!item.isRecommended)
    }

    @Test func onlyInactiveXcodeCopiesAreFound() async throws {
        try makeApplication("Xcode", bundleIdentifier: XcodeScanner.xcodeBundleIdentifier)
        try makeApplication("Xcode-beta", bundleIdentifier: XcodeScanner.xcodeBundleIdentifier)
        try makeApplication("Other", bundleIdentifier: "com.example.other")
        defer { cleanUp() }

        let active = applications.appending(path: "Xcode.app/Contents/Developer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let result = await scanner(developerDirectory: active.path + "\n").scan(.xcodeApplications)

        #expect(result.items.map(\.title) == ["Xcode-beta"])
        #expect(result.items.allSatisfy { !$0.isRecommended && $0.isDeletable }, "копия Xcode удаляется как программа — только в Корзину")
    }

    @Test func xcodeCopiesAreHiddenWhenActiveOneIsUnknown() async throws {
        try makeApplication("Xcode-beta", bundleIdentifier: XcodeScanner.xcodeBundleIdentifier)
        defer { cleanUp() }

        let result = await scanner(developerDirectory: nil).scan(.xcodeApplications)

        #expect(result.items.isEmpty)
        #expect(result.unavailableReason == XcodeScanner.unknownActiveXcodeReason)
    }

    @Test func xcodeFoldersAreNotCountedTwice() async throws {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        try makeFile(library.appending(path: "Caches/org.swift.swiftpm/repositories/pkg"), bytes: 100)
        try makeFile(library.appending(path: "Caches/com.apple.dt.Xcode/cache.db"), bytes: 100)
        try makeFile(library.appending(path: "Caches/com.example.app/cache.db"), bytes: 100)
        try makeFile(library.appending(path: "Logs/CoreSimulator/sim.log"), bytes: 100)
        try makeFile(library.appending(path: "Logs/SomeApp/app.log"), bytes: 100)
        defer { cleanUp() }

        let scanner = scanner()
        let userCaches = await scanner.scan(.userCaches)
        let userLogs = await scanner.scan(.userLogs)
        let packages = await scanner.scan(.packageCaches)
        let xcodeCaches = await scanner.scan(.xcodeCaches)
        let xcodeLogs = await scanner.scan(.xcodeLogs)

        #expect(userCaches.items.map(\.title) == ["com.example.app"])
        #expect(userLogs.items.map(\.title) == ["SomeApp"])
        #expect(packages.items.map(\.title) == ["repositories"])
        #expect(packages.items.first?.details == "Swift Package Manager")
        #expect(xcodeCaches.items.map(\.title) == ["cache.db"])
        #expect(xcodeLogs.items.map(\.title) == ["sim.log"])
    }

    /// Кэши dyld: мусор — рантаймы, которые macOS не поддерживает; рабочие — с подписью «создастся заново»;
    /// без рантайма и старые сборки macOS — только поиск.
    @Test func dyldCachesAreMatchedToRuntimeAvailability() async throws {
        let library = home.appending(path: "Library-root", directoryHint: .isDirectory)
        let dyld = library.appending(path: "Developer/CoreSimulator/Caches/dyld")
        let host = try #require(XcodeScanner.hostBuild())
        for name in ["com.apple.CoreSimulator.SimRuntime.iOS-16-0.20A360", "com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86",
                     "com.apple.CoreSimulator.SimRuntime.iOS-12-0.16A366"] {
            try makeFile(dyld.appending(path: "\(host)/\(name)/dyld_sim_shared_cache_arm64e"), bytes: 1_000)
        }
        try FileManager.default.createDirectory(at: dyld.appending(path: "\(host)/inc"), withIntermediateDirectories: true)
        try makeFile(dyld.appending(path: "00A000/com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86/cache"), bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let availability = Data("""
        {"runtimes": [
          {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-0", "buildversion": "20A360", "isAvailable": false,
           "availabilityError": "The iOS 16.0 simulator runtime is not supported on hosts after macOS 26.99.99."},
          {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "buildversion": "22G86", "isAvailable": true}
        ]}
        """.utf8)
        let developerPath = developer.path
        let runner = CommandRunner { executable, arguments in
            executable == XcodeScanner.xcodeSelect ? Data(developerPath.utf8) : availability
        }
        let scanner = CleanupScanner(home: home, system: SystemLocations(library: library), commandRunner: runner)

        let result = await scanner.scan(.simulatorDyldCaches)
        let item = { (name: String) in result.items.first { $0.url.lastPathComponent == name && $0.url.path.contains(host) } }

        #expect(result.items.count == 4, "inc не показывается")
        let unsupported = try #require(item("com.apple.CoreSimulator.SimRuntime.iOS-16-0.20A360"))
        #expect(unsupported.isRecommended && unsupported.removal == .dyldCacheRemove(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-16-0", build: "20A360"))
        #expect(unsupported.details?.contains("not supported on hosts after macOS 26.99.99") == true, "причина — словами simctl")
        let working = try #require(item("com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86"))
        #expect(!working.isRecommended && working.isDeletable && working.details?.contains("создаст заново") == true)
        #expect(item("com.apple.CoreSimulator.SimRuntime.iOS-12-0.16A366")?.isDeletable == false, "рантайма нет — только поиск")
        #expect(result.items.filter { !$0.url.path.contains(host) }.allSatisfy { !$0.isDeletable }, "старая сборка macOS — только поиск")
    }

    // MARK: - Helpers

    private func scanner(devices: Data? = devicesJSON, developerDirectory: String?? = .some(nil)) -> CleanupScanner {
        let runtimes = Self.runtimesJSON
        // .some(nil) — папка разработчика по умолчанию (временный Xcode с simctl); nil — Xcode не установлен.
        let developerPath = developerDirectory.map { $0 ?? developer.path }
        let runner = CommandRunner { executable, arguments in
            let answer: Data? = if executable == XcodeScanner.xcodeSelect {
                developerPath.map { Data($0.utf8) }
            } else if arguments.contains("runtime") {
                runtimes
            } else {
                devices
            }
            guard let answer else { throw CommandRunner.Failure.exitStatus(1) }
            return answer
        }
        return CleanupScanner(home: home, system: SystemLocations(applications: applications), commandRunner: runner)
    }

    private func makeApplication(_ name: String, bundleIdentifier: String) throws {
        try writePlist(
            ["CFBundleIdentifier": bundleIdentifier, "CFBundleShortVersionString": "27.0", "CFBundlePackageType": "APPL"],
            to: applications.appending(path: "\(name).app/Contents/Info.plist")
        )
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }
}
