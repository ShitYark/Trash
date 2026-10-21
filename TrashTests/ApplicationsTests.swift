import Foundation
import Testing
@testable import Trash

/// Раздел «Программы». Временные папки программ и `~/Library`; Launch Services, подпись кода,
/// запущенные процессы и Корзина подменены — реальные программы и Корзина не трогаются.
struct ApplicationsTests {
    let base: URL
    let home: URL
    let system: SystemLocations

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "TrashApplicationsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        system = SystemLocations(
            applications: base.appending(path: "Applications", directoryHint: .isDirectory),
            usrLocal: base.appending(path: "usr-local", directoryHint: .isDirectory),
            library: base.appending(path: "Library", directoryHint: .isDirectory),
            systemApplications: [],
            homebrewPrefixes: []
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: - Установленные программы

    @Test func installedApplicationsAreListedWithDetails() async throws {
        try makeApplication("Foo", identifier: "com.example.foo", version: "1.2", appStore: true)
        try makeApplication("Vendor/Bar", identifier: "com.vendor.bar")
        try makeApplication("Baz", identifier: "com.example.baz", in: home.appending(path: "Applications"))
        defer { cleanUp() }

        let baz = home.appending(path: "Applications/Baz.app")
        let result = await scanner(running: [baz]).scan(.installedApplications)
        let byTitle = Dictionary(result.items.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(result.items.map(\.title).sorted() == ["Bar", "Baz", "Foo"], "программы из подпапки и из ~/Applications тоже")
        #expect(byTitle["Foo"]?.details?.contains("App Store") == true)
        #expect(byTitle["Baz"]?.details?.contains("запущена") == true)
        #expect(result.items.allSatisfy { !$0.isRecommended && $0.isDeletable }, "программы сами не отмечаются")
    }

    // MARK: - Остатки

    @Test func leftoversFollowOwnershipRules() async throws {
        try makeApplication("Foo", identifier: "com.example.foo")
        try makeApplication("Office", identifier: "com.microsoft.Word")
        let elsewhere = base.appending(path: "Elsewhere/Tool.app")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        for path in ["Containers/com.gone.app", "Containers/com.example.foo.helper", "Containers/com.example.other",
                     "Containers/com.installed.elsewhere", "Containers/com.apple.Safari",
                     "Group Containers/UBF8T346G9.com.microsoft.oneauth", "Group Containers/ABCDE12345.com.gone.shared",
                     "Group Containers/group.com.docker", "Application Support/MobileSync", "Application Support/com.gone.app",
                     "Saved Application State/com.gone.app.savedState", "HTTPStorages/com.gone.app"] {
            try makeFile(library.appending(path: "\(path)/data.bin"), bytes: 1_000)
        }
        try makeFile(library.appending(path: "Preferences/com.gone.app.plist"), bytes: 100)
        defer { cleanUp() }

        let scanner = scanner(teams: ["com.microsoft.Word": "UBF8T346G9"], lookup: ["com.installed.elsewhere": elsewhere])
        let result = await scanner.scan(.appLeftovers)
        let titles = Set(result.items.map(\.title))
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(titles == ["com.gone.app", "com.example.other", "ABCDE12345.com.gone.shared", "group.com.docker",
                           "com.gone.app.savedState", "com.gone.app.plist"],
                "не остатки: помощник установленной программы, найденная Launch Services, com.apple, общий вход Microsoft, MobileSync")
        #expect(recommended == ["com.gone.app", "ABCDE12345.com.gone.shared", "group.com.docker", "com.gone.app.savedState"],
                "у производителя com.example есть программа — проверьте; настройки сами не отмечаются")
        #expect(result.items.allSatisfy { $0.isDeletable })
    }

    // MARK: - Защита

    @Test func guardAllowsOnlyApplicationBundlesAndLeftoverEntries() throws {
        let safetyGuard = SafetyGuard(home: home, system: system)
        let applications = system.applications
        let library = home.appending(path: "Library", directoryHint: .isDirectory)

        let allowedPaths: [(URL, CleanupCategory)] = [
            (applications.appending(path: "Foo.app"), .installedApplications),
            (applications.appending(path: "Vendor/Bar.app"), .installedApplications),
            (home.appending(path: "Applications/Baz.app"), .installedApplications),
            (applications.appending(path: "Xcode-beta.app"), .xcodeApplications),
            (library.appending(path: "Containers/com.gone.app"), .appLeftovers),
            (library.appending(path: "Group Containers/group.com.docker"), .appLeftovers),
            (library.appending(path: "Preferences/com.gone.app.plist"), .appLeftovers),
        ]
        for (allowed, category) in allowedPaths {
            #expect(safetyGuard.canDelete(allowed, as: category), "\(allowed.path)")
            #expect(!safetyGuard.canDelete(allowed, as: .userCaches), "чужая категория не проходит узкое правило: \(allowed.path)")
        }
        // Правило программ не пускает остатки, даже если имя остатка кончается на `.app`, и наоборот.
        #expect(!safetyGuard.canDelete(library.appending(path: "Containers/com.gone.app"), as: .installedApplications))
        #expect(!safetyGuard.canDelete(applications.appending(path: "Foo.app"), as: .appLeftovers))
        for denied in [applications, applications.appending(path: "Vendor"), applications.appending(path: "notes.txt"),
                       applications.appending(path: "Foo.app/Contents/MacOS/Foo"), applications.appending(path: "Foo.app/Contents/Helpers/Helper.app"),
                       library.appending(path: "Containers"), library.appending(path: "Containers/com.apple.Safari"),
                       library.appending(path: "Application Support/MobileSync"), library.appending(path: "Containers/com.gone.app/Data/file"),
                       library.appending(path: "Preferences/.GlobalPreferences.plist")] {
            #expect(!safetyGuard.canDelete(denied, as: .installedApplications), "\(denied.path)")
            #expect(!safetyGuard.canDelete(denied, as: .appLeftovers), "\(denied.path)")
        }
    }

    // MARK: - Удаление

    @Test func cleanerRecyclesApplicationsButNotRunningOnes() async throws {
        let foo = try makeApplication("Foo", identifier: "com.example.foo")
        let running = try makeApplication("Running", identifier: "com.example.running")
        defer { cleanUp() }

        let recycled = Recorded()
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { $0.lastPathComponent == "Running.app" }
        cleaner.recycler = Recycler { url in recycled.append(url) }
        let items = [foo, running].map { ScanItem(url: $0, size: 100, category: .installedApplications) }
        let report = await cleaner.clean(items, permanently: true)

        #expect(recycled.urls == [foo], "навсегда программы не удаляются — только в Корзину")
        #expect(report.failures.map(\.url) == [running])
        #expect(FileManager.default.fileExists(atPath: running.path))
    }

    @Test func cleanerRechecksLeftoversBeforeDeleting() async throws {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let gone = library.appending(path: "Containers/com.gone.app")
        let reinstalled = library.appending(path: "Containers/com.back.app")
        try makeFile(gone.appending(path: "data.bin"), bytes: 1_000)
        try makeFile(reinstalled.appending(path: "data.bin"), bytes: 1_000)
        let backApp = try makeApplication("Back", identifier: "com.back.app")
        defer { cleanUp() }

        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        // Программу com.back.app поставили уже после скана: свежий каталог её видит.
        cleaner.catalog = { ApplicationCatalog.scan(system: system, home: home, environment: environment()) }
        let items = [gone, reinstalled].map { ScanItem(url: $0, size: 1_000, category: .appLeftovers) }
        let report = await cleaner.clean(items, permanently: true)

        #expect(report.removed == [gone])
        #expect(report.failures.map(\.url) == [reinstalled])
        #expect(FileManager.default.fileExists(atPath: reinstalled.path))
        #expect(FileManager.default.fileExists(atPath: backApp.path))
    }

    // MARK: - Ложные остатки, найденные ревью

    @Test func groupsDeclaredBySystemAndInstalledApplicationsAreNotLeftovers() async throws {
        let systemFolder = base.appending(path: "System/Applications", directoryHint: .isDirectory)
        try makeApplication("Notes Helper", identifier: "com.vendor.notes", in: systemFolder)
        try makeApplication("Foo", identifier: "com.example.foo")
        try makeLeftovers(["Group Containers/group.net.vendor.notes.store", "Group Containers/group.net.shared.store",
                           "Group Containers/group.net.gone.store"])
        defer { cleanUp() }

        var withSystem = system
        withSystem.systemApplications = [systemFolder]
        let titles = await leftoverTitles(scanner(
            groups: ["com.vendor.notes": ["group.net.vendor.notes.store"], "com.example.foo": ["group.net.shared.store"]],
            system: withSystem
        ))

        #expect(titles == ["group.net.gone.store"], "группа из подписи системной или установленной программы — не остаток")
    }

    @Test func systemMarkersAnywhereInNameAreNeverCandidates() {
        let names: [(String, LeftoverPolicy.Kind)] = [
            ("group.is.workflow.my.app", .groupContainer), ("group.is.workflow.shortcuts", .groupContainer),
            ("243LU875E5.groups.com.apple.podcasts", .groupContainer), ("systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist", .preferences),
            ("org.cups.PrintingPrefs.plist", .preferences), ("com.apple.Safari", .container),
        ]
        for (name, kind) in names {
            #expect(LeftoverPolicy.owner(ofEntryNamed: name, kind: kind) == nil, "\(name)")
        }
        #expect(LeftoverPolicy.owner(ofEntryNamed: "group.com.docker", kind: .groupContainer)?.identifier == "com.docker")
        #expect(LeftoverPolicy.owner(ofEntryNamed: "ABCDE12345.groups.com.vendor.app", kind: .groupContainer)?.identifier == "com.vendor.app")
    }

    @Test func wrappedIOSApplicationProtectsItsData() async throws {
        let wrapper = system.applications.appending(path: "Tato Talk.app/Wrapper/TatoTalk.app", directoryHint: .isDirectory)
        let info: [String: Any] = ["CFBundleIdentifier": "com.backendtech.tatotalk", "CFBundleShortVersionString": "2.0"]
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: wrapper.appending(path: "Info.plist"))
        try FileManager.default.createSymbolicLink(at: system.applications.appending(path: "Tato Talk.app/WrappedBundle"),
                                                   withDestinationURL: wrapper)
        try makeLeftovers(["Group Containers/group.com.backendtech.tatotalk.beta", "Containers/com.backendtech.tatotalk"])
        defer { cleanUp() }

        let scanner = scanner()
        let installed = await scanner.scan(.installedApplications)

        #expect(await leftoverTitles(scanner).isEmpty, "у iOS-программы идентификатор в WrappedBundle — её данные не остатки")
        #expect(installed.items.first?.details?.contains("версия 2.0") == true)
    }

    @Test func applicationRememberedByLaunchServicesIsNotConfident() async throws {
        try makeLeftovers(["Containers/com.mygame.FirstGame"])
        defer { cleanUp() }

        let missing = base.appending(path: "Unmounted Volume/FirstGame.app")
        let result = await scanner(lookup: ["com.mygame.FirstGame": missing]).scan(.appLeftovers)
        let item = try #require(result.items.first)

        #expect(!item.isRecommended, "внешний диск или своя сборка — только «проверьте»")
        #expect(item.details?.contains("macOS помнит программу") == true)
    }

    @Test func nestedExtensionsOfInstalledApplicationsAreNotLeftovers() async throws {
        let application = try makeApplication("ImageOptim", identifier: "net.pornel.ImageOptim")
        let plugin = application.appending(path: "Contents/PlugIns/ImageOptimize.appex/Contents/Info.plist")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "net.pornel.ImageOptimizeExtension"], format: .xml, options: 0)
            .write(to: plugin)
        try makeLeftovers(["Containers/net.pornel.ImageOptimizeExtension"])
        defer { cleanUp() }

        #expect(await leftoverTitles(scanner()).isEmpty)
    }

    @Test func xcodeCopyGoesToTrashEvenWhenPermanentIsChosen() async throws {
        let copy = try makeApplication("Xcode-beta", identifier: "com.apple.dt.Xcode")
        defer { cleanUp() }

        let recycled = Recorded()
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { _ in false }
        cleaner.recycler = Recycler { url in recycled.append(url) }
        let report = await cleaner.clean([ScanItem(url: copy, size: 100, category: .xcodeApplications)], permanently: true)

        #expect(recycled.urls == [copy])
        #expect(report.removed == [copy])
        #expect(FileManager.default.fileExists(atPath: copy.path), "подменённая Корзина ничего не удаляет")
    }

    @Test func applicationDeniedByPermissionsGoesToTrashThroughFinder() async throws {
        let app = try makeApplication("Locked", identifier: "com.example.locked", appStore: true)
        defer { cleanUp() }

        let viaWorkspace = Recorded()
        let viaFinder = Recorded()
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { _ in false }
        cleaner.recycler = Recycler(
            recycle: { url in
                viaWorkspace.append(url)
                throw CocoaError(.fileWriteNoPermission)
            },
            recycleWithPassword: { url in viaFinder.append(url) }
        )
        let report = await cleaner.clean([ScanItem(url: app, size: 100, category: .installedApplications)], permanently: true)

        #expect(viaWorkspace.urls == [app])
        #expect(viaFinder.urls == [app], "отказ по правам — в Корзину через Finder с паролем")
        #expect(report.removed == [app])
        #expect(report.movedToTrash == 1 && report.deletedPermanently == 0, "в отчёте — «в Корзину», хотя выбрано «навсегда»")
        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: app.path), "даже при «навсегда» программа не удаляется мимо Корзины")
    }

    @Test func otherRecycleErrorsDoNotAskForPassword() async throws {
        let app = try makeApplication("Gone", identifier: "com.example.gone")
        defer { cleanUp() }

        let viaFinder = Recorded()
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { _ in false }
        cleaner.recycler = Recycler(
            recycle: { _ in throw CocoaError(.fileNoSuchFile) },
            recycleWithPassword: { url in viaFinder.append(url) }
        )
        let report = await cleaner.clean([ScanItem(url: app, size: 100, category: .installedApplications)], permanently: false)

        #expect(viaFinder.urls.isEmpty, "пароль нужен только при отказе по правам")
        #expect(report.removed.isEmpty)
        #expect(report.failures.count == 1)
    }

    @Test func finderRefusalIsReportedWithReason() async throws {
        let app = try makeApplication("Locked", identifier: "com.example.locked", appStore: true)
        defer { cleanUp() }

        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { _ in false }
        cleaner.recycler = Recycler(
            // Отказ по правам может прийти вложенной ошибкой POSIX.
            recycle: { _ in throw NSError(domain: "Workspace", code: 1, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)]) },
            recycleWithPassword: { _ in throw FinderTrashError(code: -128) }
        )
        let report = await cleaner.clean([ScanItem(url: app, size: 100, category: .installedApplications)], permanently: false)

        let failure = try #require(report.failures.first)
        #expect(report.removed.isEmpty)
        #expect(failure.reason == "Пароль администратора не введён — удаление отменено")
    }

    @Test func declinedPasswordIsNotAskedAgainInSameCleanup() async throws {
        let first = try makeApplication("First", identifier: "com.example.first", appStore: true)
        let second = try makeApplication("Second", identifier: "com.example.second", appStore: true)
        defer { cleanUp() }

        let viaFinder = Recorded()
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { _ in false }
        cleaner.recycler = Recycler(
            recycle: { _ in throw CocoaError(.fileWriteNoPermission) },
            recycleWithPassword: { url in
                viaFinder.append(url)
                throw FinderTrashError.cancelled
            }
        )
        let items = [first, second].map { ScanItem(url: $0, size: 100, category: .installedApplications) }
        let report = await cleaner.clean(items, permanently: false)

        #expect(viaFinder.urls == [first], "после отмены пароль больше не спрашивается")
        #expect(report.failures.count == 2)
        #expect(report.failures.allSatisfy { $0.reason == FinderTrashError.cancelled.localizedDescription })
    }

    @Test func symlinkedApplicationIsNotPassedToFinder() async throws {
        let real = try makeApplication("Real", identifier: "com.example.real", in: base.appending(path: "Elsewhere", directoryHint: .isDirectory))
        let link = system.applications.appending(path: "Link.app")
        try FileManager.default.createDirectory(at: system.applications, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { cleanUp() }

        let viaFinder = Recorded()
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.isRunning = { _ in false }
        cleaner.recycler = Recycler(
            recycle: { _ in throw CocoaError(.fileWriteNoPermission) },
            recycleWithPassword: { url in viaFinder.append(url) }
        )
        let report = await cleaner.clean([ScanItem(url: link, size: 100, category: .installedApplications)], permanently: false)

        #expect(viaFinder.urls.isEmpty, "ссылку Finder с правами администратора не получает")
        #expect(report.failures.count == 1)
    }

    @Test func guardRefusesSystemLinksNestedBundlesAndAcceptsLinkedUserFolder() throws {
        let applications = system.applications
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: applications.appending(path: "Finder.app").path,
                                                   withDestinationPath: "/System/Library/CoreServices/Finder.app")
        let realUserApplications = base.appending(path: "Dotfiles/Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realUserApplications.appending(path: "Baz.app"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "Applications"), withDestinationURL: realUserApplications)
        defer { cleanUp() }

        let safetyGuard = SafetyGuard(home: home, system: system)

        #expect(!safetyGuard.canDelete(applications.appending(path: "Finder.app"), as: .installedApplications), "ссылка в /System — системная программа")
        #expect(!safetyGuard.canDelete(applications.appending(path: "Foo.app/Bar.app"), as: .installedApplications), "бандл внутри бандла")
        #expect(safetyGuard.canDelete(home.appending(path: "Applications/Baz.app"), as: .installedApplications), "~/Applications — ссылка")
        #expect(safetyGuard.canDelete(realUserApplications.appending(path: "Baz.app"), as: .installedApplications))
    }

    // MARK: - Helpers

    /// Подпись подменена по идентификатору программы: Team ID и группы данных из entitlements.
    private func environment(teams: [String: String] = [:], groups: [String: [String]] = [:], lookup: [String: URL] = [:],
                             running: [URL] = []) -> ApplicationEnvironment {
        ApplicationEnvironment(
            lookup: { lookup[$0] },
            signature: { url in
                let identifier = Bundle(url: url)?.bundleIdentifier ?? ""
                return CodeSignature(team: teams[identifier], applicationGroups: groups[identifier] ?? [])
            },
            isRunning: { url in running.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path } }
        )
    }

    private func scanner(teams: [String: String] = [:], groups: [String: [String]] = [:], lookup: [String: URL] = [:],
                         running: [URL] = [], system: SystemLocations? = nil) -> CleanupScanner {
        CleanupScanner(home: home, system: system ?? self.system,
                       commandRunner: CommandRunner { _, _ in throw CommandRunner.Failure.exitStatus(1) },
                       applications: environment(teams: teams, groups: groups, lookup: lookup, running: running))
    }

    private func makeLeftovers(_ paths: [String]) throws {
        for path in paths {
            try makeFile(home.appending(path: "Library/\(path)/data.bin"), bytes: 1_000)
        }
    }

    private func leftoverTitles(_ scanner: CleanupScanner) async -> Set<String> {
        Set(await scanner.scan(.appLeftovers).items.map(\.title))
    }

    @discardableResult
    private func makeApplication(_ path: String, identifier: String, version: String = "1.0", appStore: Bool = false, in folder: URL? = nil) throws -> URL {
        let application = (folder ?? system.applications).appending(path: "\(path).app", directoryHint: .isDirectory)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        let info = application.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        if appStore {
            try makeFile(application.appending(path: "Contents/_MASReceipt/receipt"), bytes: 10)
        }
        return application
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}

/// Список адресов, которые подменённая Корзина «получила».
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    var urls: [URL] { lock.withLock { stored } }

    func append(_ url: URL) {
        lock.withLock { stored.append(url) }
    }
}
