import Foundation
import Testing
@testable import Trash

/// Удаление через менеджер. `simctl` и `brew` подменены: настоящие команды не запускаются, файлы — только во временной папке.
struct ManagerRemovalTests {
    static let idleUDID = "11111111-1111-1111-1111-111111111111"
    static let bootedUDID = "22222222-2222-2222-2222-222222222222"
    static let bootingUDID = "33333333-3333-3333-3333-333333333333"
    static let runtimeID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    static let simctl = "/fake/simctl"
    static let brew = "/fake/brew"
    static let docker = "/fake/docker"
    static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"

    let base: URL
    let home: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "TrashManagerRemovalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    @Test func simulatorIsDeletedBySimctlAfterFreshCheck() async throws {
        defer { cleanUp() }
        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { _ in Self.devices([(Self.idleUDID, "Shutdown", Self.runtime)]) }
        let item = ScanItem(url: home.appending(path: Self.idleUDID), size: 10, category: .simulators, removal: .simulator(udid: Self.idleUDID))

        let report = await cleaner.clean([item], permanently: false)

        #expect(commands.list.contains([Self.simctl, "delete", Self.idleUDID]))
        #expect(report.removed == [item.url], "simctl удаляет сразу, режим «в Корзину» его не меняет")
        #expect(report.removedByManagers == 1)
    }

    @Test func busySimulatorsAndUsedRuntimeAreRefusedBeforeAnyCommand() async throws {
        defer { cleanUp() }
        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { _ in
            Self.devices([(Self.bootedUDID, "Booted", Self.runtime), (Self.bootingUDID, "Booting", Self.runtime)])
        }
        let items = [
            ScanItem(url: home.appending(path: Self.bootedUDID), size: 10, category: .simulators, removal: .simulator(udid: Self.bootedUDID)),
            ScanItem(url: home.appending(path: Self.bootingUDID), size: 10, category: .simulators, removal: .simulator(udid: Self.bootingUDID)),
            ScanItem(url: home.appending(path: "rt"), size: 10, category: .simulatorRuntimes,
                     removal: .runtime(identifier: Self.runtimeID, runtimeIdentifier: Self.runtime)),
        ]

        let report = await cleaner.clean(items, permanently: true)

        #expect(report.removed.isEmpty)
        #expect(Set(report.failures.map { $0.reason }) == [ManagerRemovalError.simulatorNotShutdown("Booted").localizedDescription,
                                                       ManagerRemovalError.simulatorNotShutdown("Booting").localizedDescription,
                                                       ManagerRemovalError.runtimeInUse.localizedDescription])
        #expect(!commands.list.contains { $0.contains("delete") }, "до команды удаления дело не дошло")
    }

    @Test func simulatorsAreDeletedBeforeTheirRuntime() async throws {
        defer { cleanUp() }
        let commands = Commands()
        // Симулятор пропадает из списка после `delete` — тогда рантайм уже никому не нужен.
        let cleaner = makeCleaner(commands: commands) { history in
            history.contains([Self.simctl, "delete", Self.idleUDID]) ? Self.devices([]) : Self.devices([(Self.idleUDID, "Shutdown", Self.runtime)])
        }
        let items = [
            ScanItem(url: home.appending(path: "rt"), size: 10, category: .simulatorRuntimes,
                     removal: .runtime(identifier: Self.runtimeID, runtimeIdentifier: Self.runtime)),
            ScanItem(url: home.appending(path: Self.idleUDID), size: 10, category: .simulators, removal: .simulator(udid: Self.idleUDID)),
        ]

        let report = await cleaner.clean(items, permanently: true)
        let deletions = commands.list.filter { $0.contains("delete") }

        #expect(deletions == [[Self.simctl, "delete", Self.idleUDID], [Self.simctl, "runtime", "delete", Self.runtimeID]])
        #expect(report.removed.count == 2)
    }

    @Test func forgedIdentifiersAndForeignOperationsAreRefused() async throws {
        defer { cleanUp() }
        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { _ in Self.devices([(Self.idleUDID, "Shutdown", Self.runtime)]) }
        let foreign = home.appending(path: "d")
        let mismatched = home.appending(path: Self.bootedUDID)
        let gone = home.appending(path: Self.bootingUDID)
        let items = [
            ScanItem(url: home.appending(path: "--all"), size: 1, category: .simulators, removal: .simulator(udid: "--all")),
            ScanItem(url: home.appending(path: "b"), size: 1, category: .homebrew, removal: .brewUninstall(formula: "--force")),
            ScanItem(url: home.appending(path: "c"), size: 1, category: .homebrew, removal: .brewCleanup(formula: "../etc")),
            ScanItem(url: foreign, size: 1, category: .homebrew, removal: .simulator(udid: Self.idleUDID)),
            // Операция указывает на настоящий выключенный симулятор, но не на тот, чья это папка.
            ScanItem(url: mismatched, size: 1, category: .simulators, removal: .simulator(udid: Self.idleUDID)),
            ScanItem(url: home.appending(path: "f"), size: 1, category: .simulatorRuntimes,
                     removal: .runtime(identifier: "not-a-uuid", runtimeIdentifier: Self.runtime)),
            ScanItem(url: home.appending(path: "g"), size: 1, category: .simulatorRuntimes,
                     removal: .runtime(identifier: Self.runtimeID, runtimeIdentifier: Self.runtime + " --all")),
            ScanItem(url: gone, size: 1, category: .simulators, removal: .simulator(udid: Self.bootingUDID)),
        ]

        let report = await cleaner.clean(items, permanently: true)
        let reason = { (url: URL) in report.failures.first { $0.url == url }?.reason }

        #expect(report.removed.isEmpty)
        #expect(report.failures.count == items.count)
        #expect(reason(foreign) == "Операция не своего раздела — удаление отменено")
        #expect(reason(mismatched) == "Операция не совпадает с элементом — удаление отменено")
        #expect(reason(gone) == ManagerRemovalError.simulatorGone.localizedDescription)
        #expect(report.failures.filter { $0.reason == ManagerRemovalError.invalidIdentifier.localizedDescription }.count == 5)
        #expect(!commands.list.contains { $0.contains("uninstall") || $0.contains("cleanup") || $0.contains("delete") })
    }

    @Test func brewUninstallKeepsDependenciesAndRemovesAllVersions() async throws {
        let formula = home.appending(path: "Cellar/libfoo", directoryHint: .isDirectory)
        let versions = ["1.0", "0.9"].map { formula.appending(path: $0, directoryHint: .isDirectory) }
        for version in versions {
            try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        }
        defer { cleanUp() }

        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { history in
            if history.last?.contains("uninstall") == true {
                try? FileManager.default.removeItem(at: formula)
            }
            return Data()
        }
        let items = versions.map { ScanItem(url: $0, size: 10, category: .homebrew, removal: .brewUninstall(formula: "libfoo")) }

        let report = await cleaner.clean(items, permanently: false)

        // Без `HOMEBREW_NO_AUTOREMOVE` brew удалил бы и неотмеченные зависимости, без `--force` — только текущую версию.
        #expect(commands.list == [[ManagerRemover.env] + ManagerRemover.brewEnvironment + [Self.brew, "uninstall", "--formula", "--force", "libfoo"]])
        #expect(ManagerRemover.brewEnvironment.contains("HOMEBREW_NO_AUTOREMOVE=1"))
        #expect(report.removed == versions)
        #expect(report.removedByManagers == 2)
    }

    @Test func formulaPinnedAfterScanIsNotUninstalled() async throws {
        let keg = home.appending(path: "Cellar/libfoo/1.0", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: keg, withIntermediateDirectories: true)
        // `brew pin` после скана: ссылка в `<префикс>/var/homebrew/pinned`, здесь — битая.
        let pins = home.appending(path: "var/homebrew/pinned", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: pins.appending(path: "libfoo").path, withDestinationPath: "../../../Cellar/libfoo/gone")
        defer { cleanUp() }

        let commands = Commands()
        var cleaner = makeCleaner(commands: commands) { _ in Data() }
        let brew = home.appending(path: "bin/brew").path
        cleaner.remover.brew = { brew }
        let item = ScanItem(url: keg, size: 10, category: .homebrew, removal: .brewUninstall(formula: "libfoo"))

        let report = await cleaner.clean([item], permanently: true)

        #expect(report.failures.map { $0.reason } == [ManagerRemovalError.formulaPinned.localizedDescription])
        #expect(commands.list.isEmpty, "с --force brew снял бы закрепление молча")
    }

    @Test func brewCleanupRunsOnceAfterMatchingDryRunAndChecksWhatIsGone() async throws {
        let older = home.appending(path: "Cellar/freetype/2.13.1", directoryHint: .isDirectory)
        let old = home.appending(path: "Cellar/freetype/2.13.2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { cleanUp() }

        let commands = Commands()
        let preview = dryRun([older, old, homebrewCache.appending(path: "downloads/abc--freetype--2.13.1.bottle.tar.gz")])
        // Подменённый brew убирает только одну версию — вторая должна попасть в отказы.
        let cleaner = makeCleaner(commands: commands) { history in
            let command = history.last ?? []
            if command.contains("--dry-run") {
                return Data(preview.utf8)
            }
            if command.contains("cleanup") {
                try? FileManager.default.removeItem(at: older)
            }
            return Data()
        }
        let items = [older, old].map {
            ScanItem(url: $0, size: 10, category: .homebrew, removal: .brewCleanup(formula: "freetype"))
        }

        let report = await cleaner.clean(items, permanently: true)
        let brew = [ManagerRemover.env] + ManagerRemover.brewEnvironment + [Self.brew, "cleanup"]

        #expect(commands.list == [brew + ["--dry-run", "freetype"], brew + ["freetype"]], "сначала вхолостую, потом одна команда на формулу")
        #expect(report.removed == [older])
        #expect(report.failures.map { $0.reason } == [CleanerError.leftInPlace.localizedDescription])
    }

    @Test func brewCleanupThatWouldRemoveMoreThanSelectedIsRefused() async throws {
        let hidden = home.appending(path: "Cellar/freetype/2.13.0", directoryHint: .isDirectory)
        let selected = home.appending(path: "Cellar/freetype/2.13.1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { cleanUp() }

        let commands = Commands()
        // brew вычистил бы и версию, которую в окне отметить нельзя.
        let preview = dryRun([hidden, selected])
        let cleaner = makeCleaner(commands: commands) { history in
            Data((history.last?.contains("--dry-run") == true ? preview : "").utf8)
        }
        let item = ScanItem(url: selected, size: 10, category: .homebrew, removal: .brewCleanup(formula: "freetype"))

        let report = await cleaner.clean([item], permanently: true)

        #expect(report.removed.isEmpty)
        #expect(report.failures.map { $0.reason } == [ManagerRemovalError.cleanupMismatch(formula: "freetype").localizedDescription])
        #expect(commands.list.count == 1 && commands.list[0].contains("--dry-run"), "настоящий cleanup не запускался")
        #expect(FileManager.default.fileExists(atPath: hidden.path) && FileManager.default.fileExists(atPath: selected.path))
    }

    @Test func cleanupPreviewMustMatchSelectionExactly() {
        let cellar = URL(filePath: "/opt/homebrew/Cellar")
        let cache = URL(filePath: "/Users/tester/Library/Caches/Homebrew", directoryHint: .isDirectory)
        let kegs = ["2.13.1", "2.13.2"].map { cellar.appending(path: "freetype/\($0)").path }
        let cached = cache.appending(path: "downloads/abc--freetype.bottle.tar.gz").path
        let matches = { (expected: [String], removed: [String]) in
            ManagerRemover.cleanupRemovesExactly(Set(expected), preview: self.dryRun(removed.map { URL(filePath: $0) }), formula: "freetype", cache: cache)
        }

        #expect(matches(kegs, kegs + [cached]), "файлы кэша загрузок — можно")
        #expect(!matches(kegs, kegs + ["/opt/homebrew/lib/libfreetype.dylib"]), "чужой путь вне кэша")
        #expect(!matches(kegs, [kegs[0]]), "удалил бы меньше отмеченного")
        #expect(!matches([kegs[0]], kegs), "удалил бы больше отмеченного")
        #expect(!matches(kegs, kegs + [cellar.appending(path: "harfbuzz/8.0").path]), "версия другой формулы")
        #expect(!matches(kegs, []), "пустой вывод — не подтверждение")
    }

    @Test func orphanSimulatorFolderIsRecheckedWithSimctl() async throws {
        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
        let appeared = devices.appending(path: Self.idleUDID)
        let orphan = devices.appending(path: Self.bootedUDID)
        try makeFile(appeared.appending(path: "data/file.bin"), bytes: 100)
        try makeFile(orphan.appending(path: "data/file.bin"), bytes: 100)
        defer { cleanUp() }

        // После скана simctl узнал одну из папок — её трогать нельзя.
        let cleaner = makeCleaner(commands: Commands()) { _ in Self.devices([(Self.idleUDID, "Shutdown", Self.runtime)]) }
        let items = [appeared, orphan].map { ScanItem(url: $0, size: 100, category: .simulators) }

        let report = await cleaner.clean(items, permanently: true)

        #expect(report.removed == [orphan])
        #expect(report.failures.first?.reason == "simctl теперь знает этот симулятор — пересканируйте")
        #expect(FileManager.default.fileExists(atPath: appeared.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func activeLanguageVersionIsNotDeleted() async throws {
        let versions = home.appending(path: ".pyenv/versions", directoryHint: .isDirectory)
        try makeFile(versions.appending(path: "3.12.0/bin/python3"), bytes: 100)
        try makeFile(versions.appending(path: "3.11.0/bin/python3"), bytes: 100)
        try makeFile(home.appending(path: ".pyenv/version"), bytes: 0)
        try Data("3.12.0\n".utf8).write(to: home.appending(path: ".pyenv/version"))
        defer { cleanUp() }

        let items = ["3.12.0", "3.11.0"].map { ScanItem(url: versions.appending(path: $0), size: 100, category: .languageVersions) }
        let report = await makeCleaner(commands: Commands()) { _ in Data() }.clean(items, permanently: true)

        #expect(report.removed == [versions.appending(path: "3.11.0")])
        #expect(report.failures.first?.reason == "Это активная версия — сначала переключитесь на другую")
        #expect(FileManager.default.fileExists(atPath: versions.appending(path: "3.12.0").path))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".pyenv/version").path), "файл выбора версии рядом не тронут")
    }

    @Test func versionIsNotDeletedWhenActiveOneIsUnknown() async throws {
        let versions = home.appending(path: ".pyenv/versions", directoryHint: .isDirectory)
        try makeFile(versions.appending(path: "3.12.0/bin/python3"), bytes: 100)
        try makeFile(versions.appending(path: "3.11.0/bin/python3"), bytes: 100)
        // Выбрана версия, которой нет среди папок: какая из установленных на деле активна — не знаем.
        try makeFile(home.appending(path: ".pyenv/version"), bytes: 0)
        try Data("3.13\n".utf8).write(to: home.appending(path: ".pyenv/version"))
        defer { cleanUp() }

        let items = ["3.12.0", "3.11.0"].map { ScanItem(url: versions.appending(path: $0), size: 100, category: .languageVersions) }
        let report = await makeCleaner(commands: Commands()) { _ in Data() }.clean(items, permanently: true)

        #expect(report.removed.isEmpty)
        #expect(report.failures.map(\.reason) == Array(repeating: "Активную версию не определить — удалите через менеджер", count: 2))
        #expect(items.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    // MARK: - Android

    @Test func runningEmulatorIsNotDeleted() async throws {
        let avds = home.appending(path: ".android/avd", directoryHint: .isDirectory)
        let running = avds.appending(path: "running.avd")
        let locked = avds.appending(path: "locked.avd")
        let stale = avds.appending(path: "stale.avd")
        for avd in [running, locked, stale] {
            try makeFile(avd.appending(path: "config.ini"), bytes: 10)
            try makeFile(avd.deletingPathExtension().appendingPathExtension("ini"), bytes: 10)
        }
        // PID самого теста — живой процесс; у «stale» — лок после сбоя с PID, которого нет.
        try Data("\(ProcessInfo.processInfo.processIdentifier)\0".utf8).write(to: running.appending(path: "hardware-qemu.ini.lock"))
        try Data("999999\0".utf8).write(to: stale.appending(path: "hardware-qemu.ini.lock"))
        try makeFile(stale.appending(path: "multiinstance.lock"), bytes: 0)
        // Работающий эмулятор держит `multiinstance.lock` под flock.
        try makeFile(locked.appending(path: "multiinstance.lock"), bytes: 0)
        let holder = open(locked.appending(path: "multiinstance.lock").path, O_RDONLY)
        #expect(flock(holder, LOCK_EX) == 0)
        defer {
            close(holder)
            cleanUp()
        }

        let items = [running, locked, stale].map { ScanItem(url: $0, size: 10, category: .androidSDK) }
        let report = await makeCleaner(commands: Commands()) { _ in Data() }.clean(items, permanently: true)

        #expect(report.removed == [stale])
        #expect(report.failures.map(\.reason) == Array(repeating: "Эмулятор запущен — закройте его и повторите", count: 2))
        #expect(!FileManager.default.fileExists(atPath: avds.appending(path: "stale.ini").path), "ini удалён вместе с папкой")
        #expect(FileManager.default.fileExists(atPath: running.path) && FileManager.default.fileExists(atPath: avds.appending(path: "running.ini").path))
    }

    @Test func imageNeededByEmulatorIsKeptUnlessEmulatorGoesFirst() async throws {
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let avds = home.appending(path: ".android/avd", directoryHint: .isDirectory)
        let used = sdk.appending(path: "system-images/android-36/google_apis/arm64-v8a")
        let leavingImage = sdk.appending(path: "system-images/android-34/google_apis/arm64-v8a")
        for image in [used, leavingImage] {
            try makeFile(image.appending(path: "package.xml"), bytes: 10)
        }
        let leaving = avds.appending(path: "leaving.avd")
        try makeFile(avds.appending(path: "keeper.avd/config.ini"), bytes: 0)
        try Data("image.sysdir.1 = system-images/android-36/google_apis/arm64-v8a/\n".utf8).write(to: avds.appending(path: "keeper.avd/config.ini"))
        try makeFile(leaving.appending(path: "config.ini"), bytes: 0)
        try Data("image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\n".utf8).write(to: leaving.appending(path: "config.ini"))
        defer { cleanUp() }

        // Образ android-34 нужен только удаляемому эмулятору: эмулятор уходит первым, образ — следом.
        let items = [leavingImage, used, leaving].map { ScanItem(url: $0, size: 10, category: .androidSDK) }
        let report = await makeCleaner(commands: Commands()) { _ in Data() }.clean(items, permanently: true)

        #expect(report.removed == [leaving, leavingImage])
        #expect(report.failures.map(\.reason) == ["Образ нужен эмулятору — сначала удалите эмулятор"])
        #expect(FileManager.default.fileExists(atPath: used.path))
    }

    @Test func imageIsKeptWhenEmulatorConfigCannotBeRead() async throws {
        let image = home.appending(path: "Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
        try makeFile(image.appending(path: "package.xml"), bytes: 10)
        // Вместо config.ini — папка: какой образ нужен эмулятору, неизвестно.
        try FileManager.default.createDirectory(at: home.appending(path: ".android/avd/odd.avd/config.ini"), withIntermediateDirectories: true)
        defer { cleanUp() }

        let report = await makeCleaner(commands: Commands()) { _ in Data() }
            .clean([ScanItem(url: image, size: 10, category: .androidSDK)], permanently: true)

        #expect(report.failures.map(\.reason) == ["Не прочитать эмуляторы — какой образ им нужен, неизвестно"])
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func imageIsKeptWhenEmulatorsCannotBeKnownForSure() async throws {
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let image = sdk.appending(path: "system-images/android-34/google_apis/arm64-v8a")
        try makeFile(image.appending(path: "package.xml"), bytes: 10)
        let avds = home.appending(path: ".android", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: avds, withIntermediateDirectories: true)
        defer { cleanUp() }
        let item = ScanItem(url: image, size: 10, category: .androidSDK)
        let unknown = "Не прочитать эмуляторы — какой образ им нужен, неизвестно"

        // Папка эмуляторов — ссылка на неподключённый диск: это не «эмуляторов нет».
        try FileManager.default.createSymbolicLink(at: avds.appending(path: "avd"), withDestinationURL: home.appending(path: "Volumes/External/avd"))
        var report = await makeCleaner(commands: Commands()) { _ in Data() }.clean([item], permanently: true)
        #expect(report.failures.map(\.reason) == [unknown])

        // Эмулятор вне папки — по `path=` в его ini — с этим образом; и эмулятор без `image.sysdir.1`.
        try FileManager.default.removeItem(at: avds.appending(path: "avd"))
        let external = home.appending(path: "Emulators/pixel.avd")
        try makeFile(external.appending(path: "config.ini"), bytes: 0)
        try Data("image.sysdir.1=/Users/x/Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/\n".utf8)
            .write(to: external.appending(path: "config.ini"))
        try makeFile(avds.appending(path: "avd/pixel.ini"), bytes: 0)
        try Data("path=\(external.path)\n".utf8).write(to: avds.appending(path: "avd/pixel.ini"))
        report = await makeCleaner(commands: Commands()) { _ in Data() }.clean([item], permanently: true)
        #expect(report.failures.map(\.reason) == ["Образ нужен эмулятору — сначала удалите эмулятор"], "эмулятор вне ~/.android/avd тоже считается")

        try Data("hw.ramSize=2048\n".utf8).write(to: external.appending(path: "config.ini"))
        report = await makeCleaner(commands: Commands()) { _ in Data() }.clean([item], permanently: true)
        #expect(report.failures.map(\.reason) == [unknown], "образ эмулятора не указан — неизвестно")
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func emulatorWithOddConfigNextToItIsNotDeleted() async throws {
        let avd = home.appending(path: ".android/avd/tablet.avd")
        try makeFile(avd.appending(path: "config.ini"), bytes: 10)
        // На месте tablet.ini — папка: удалять её рекурсивно нельзя.
        try FileManager.default.createDirectory(at: home.appending(path: ".android/avd/tablet.ini/data"), withIntermediateDirectories: true)
        defer { cleanUp() }

        let report = await makeCleaner(commands: Commands()) { _ in Data() }
            .clean([ScanItem(url: avd, size: 10, category: .androidSDK)], permanently: true)

        #expect(report.failures.map(\.reason) == ["Рядом с эмулятором не обычный файл tablet.ini — удалите вручную"])
        #expect(FileManager.default.fileExists(atPath: avd.path))
    }

    // MARK: - С паролем администратора

    /// Системные папки без права записи — одним скриптом администратора; своя папка — файлом, без пароля.
    @Test func systemFoldersGoThroughOneAdministratorScript() async throws {
        let system = temporarySystem()
        let bin = system.usrLocal.appending(path: "bin", directoryHint: .isDirectory)
        let daemons = system.library.appending(path: "LaunchDaemons", directoryHint: .isDirectory)
        let ownBin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        for folder in [bin, daemons, ownBin] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let link = bin.appending(path: "gone")
        let ownLink = ownBin.appending(path: "gone")
        for url in [link, ownLink] {
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/nonexistent/gone")
        }
        let plist = daemons.appending(path: "com.example.gone.plist")
        try writePlist(["Label": "com.example.gone", "Program": "/nonexistent/gone"], to: plist)
        // Как у root: писать в системные папки нельзя.
        lock([bin, daemons])
        defer {
            unlock([bin, daemons])
            cleanUp()
        }

        let scripts = Commands()
        var cleaner = makeCleaner(commands: Commands(), system: system) { _ in Data() }
        // «Пароль введён»: скрипт исполняется обычным sh, папки на время открыты — как у root.
        cleaner.administrator = { script in
            scripts.append([script])
            self.unlock([bin, daemons])
            return String(decoding: try await CommandRunner.system.run("/bin/sh", ["-c", script]), as: UTF8.self)
        }
        let items = [ScanItem(url: link, size: 0, category: .terminalPrograms, isRecommended: true),
                     ScanItem(url: plist, size: 10, category: .backgroundServices, isRecommended: true),
                     ScanItem(url: ownLink, size: 0, category: .terminalPrograms, isRecommended: true)]

        let report = await cleaner.clean(items, permanently: true)

        #expect(scripts.list.count == 1, "один скрипт — один запрос пароля")
        #expect(!scripts.list[0][0].contains(ownLink.path), "своя папка — без root")
        #expect(Set(report.removed) == Set([link, plist, ownLink]))
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plist.path) && (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    /// Своя папка без права записи — отказ, а не root: её права мог поменять кто угодно.
    @Test func ownLockedFolderIsRefusedNotEscalated() async throws {
        let ownBin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ownBin, withIntermediateDirectories: true)
        let link = ownBin.appending(path: "gone")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/gone")
        lock([ownBin])
        defer {
            unlock([ownBin])
            cleanUp()
        }

        let scripts = Commands()
        var cleaner = makeCleaner(commands: Commands(), system: temporarySystem()) { _ in Data() }
        cleaner.administrator = { script in
            scripts.append([script])
            return ""
        }

        let report = await cleaner.clean([ScanItem(url: link, size: 0, category: .terminalPrograms, isRecommended: true)], permanently: true)

        #expect(scripts.list.isEmpty)
        #expect(report.failures.map(\.reason) == ["Нет права записи в папку — удалите вручную"])
    }

    @Test func cancelledOrInterruptedAdministratorScriptIsReportedHonestly() async throws {
        let system = temporarySystem()
        let bin = system.usrLocal.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let links = ["first", "second"].map { bin.appending(path: $0) }
        for link in links {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/x")
        }
        lock([bin])
        defer {
            unlock([bin])
            cleanUp()
        }
        let items = links.map { ScanItem(url: $0, size: 0, category: .terminalPrograms, isRecommended: true) }

        var cleaner = makeCleaner(commands: Commands(), system: system) { _ in Data() }
        cleaner.administrator = { _ in throw AdministratorScriptError.cancelled }
        let cancelled = await cleaner.clean(items, permanently: true)
        #expect(cancelled.removed.isEmpty)
        #expect(cancelled.failures.map(\.reason) == Array(repeating: AdministratorScriptError.cancelled.localizedDescription, count: 2))

        // Скрипт прервали по тайм-ауту после первого шага: отчёт перепроверяет диск.
        cleaner.administrator = { _ in
            self.unlock([bin])
            try FileManager.default.removeItem(at: links[0])
            throw AdministratorScriptError.timedOut
        }
        let interrupted = await cleaner.clean(items, permanently: true)
        #expect(interrupted.removed == [links[0]])
        #expect(interrupted.failures.map(\.reason) == [AdministratorScriptError.timedOut.localizedDescription])
    }

    @Test func serviceWithProgramBackOrAliveLinkIsKept() async throws {
        let agents = home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        let gone = agents.appending(path: "com.example.gone.plist")
        let back = agents.appending(path: "com.example.back.plist")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try writePlist(["Label": "com.example.gone", "ProgramArguments": ["/nonexistent/gone", "--run"]], to: gone)
        // После скана программу поставили снова.
        try writePlist(["Label": "com.example.back", "Program": "/bin/sh"], to: back)
        let alive = home.appending(path: ".local/bin/alive")
        try FileManager.default.createDirectory(at: alive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alive.path, withDestinationPath: "/bin/sh")
        defer { cleanUp() }

        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { _ in Data() }
        let items = [gone, back].map { ScanItem(url: $0, size: 10, category: .backgroundServices, isRecommended: true) }
            + [ScanItem(url: alive, size: 0, category: .terminalPrograms, isRecommended: true)]

        let report = await cleaner.clean(items, permanently: true)

        #expect(commands.list.isEmpty, "службы не выгружаются: по метке можно снять другую, живую")
        #expect(report.removed == [gone])
        #expect(report.failures.map(\.reason) == ["Программа службы снова на месте — службу не трогаем",
                                                   "Ссылка снова ведёт на программу или это не ссылка — не трогаем"])
        #expect(FileManager.default.fileExists(atPath: back.path))
    }

    @Test func macPortsChecksFreshInactiveListAndOwnership() async throws {
        let prefix = home.appending(path: "macports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix.appending(path: "var/macports"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appending(path: "bin"), withIntermediateDirectories: true)
        defer { cleanUp() }

        let commands = Commands()
        var cleaner = makeCleaner(commands: commands) { history in
            // libbar активировали после скана — в свежем списке неактивных его нет.
            history.last?.contains("inactive") == true ? Data("The following ports are currently installed:\n  libfoo @1.0_0\n".utf8) : Data()
        }
        cleaner.remover.macPortsPrefix = prefix
        let scripts = Commands()
        cleaner.administrator = { script in
            scripts.append([script])
            return "0 done\n"
        }
        let port = prefix.appending(path: "bin/port").path
        let item = { (name: String, version: String) in
            ScanItem(url: self.home.appending(path: "\(name)-\(version).tbz2"), size: 10, category: .macPorts,
                     removal: .portUninstall(name: name, version: version))
        }

        // Своя установка — `port` без пароля; активированная версия — отказ.
        let own = await cleaner.clean([item("libfoo", "1.0_0"), item("libbar", "2.0_1")], permanently: false)
        #expect(commands.list.contains([port, "-N", "uninstall", "libfoo", "@1.0_0"]))
        #expect(!commands.list.contains { $0.contains("libbar") })
        #expect(own.failures.map(\.reason) == ["Версия снова активна или уже удалена — не трогаем"])
        #expect(scripts.list.isEmpty)

        // Установка root — шаг скрипта администратора; но `bin` можно переписать — смешанные права, отказ.
        lock([prefix.appending(path: "var/macports")])
        defer { unlock([prefix.appending(path: "var/macports")]) }
        let mixed = await cleaner.clean([item("libfoo", "1.0_0")], permanently: false)
        #expect(mixed.failures.map(\.reason) == ["Права MacPorts смешаны — удалите вручную: sudo port uninstall"])
        lock([prefix.appending(path: "bin")])
        defer { unlock([prefix.appending(path: "bin")]) }
        let root = await cleaner.clean([item("libfoo", "1.0_0")], permanently: false)
        #expect(scripts.list.count == 1 && scripts.list[0][0].contains("-N uninstall 'libfoo' '@1.0_0'"))
        #expect(root.removedByManagers == 1)
    }

    // MARK: - Остальные данные

    @Test func dyldCacheIsRemovedBySimctlUnlessItsSimulatorRuns() async throws {
        let cache = home.appending(path: "dyld/com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { cleanUp() }

        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { history in
            if history.last?.contains("dyld_shared_cache") == true {
                try? FileManager.default.removeItem(at: cache)
            }
            return Self.devices([(Self.bootedUDID, "Booted", "com.apple.CoreSimulator.SimRuntime.iOS-26-1")])
        }
        let item = { (runtime: String, build: String) in
            ScanItem(url: cache, size: 10, category: .simulatorDyldCaches, removal: .dyldCacheRemove(runtimeIdentifier: runtime, build: build))
        }

        let running = home.appending(path: "dyld/com.apple.CoreSimulator.SimRuntime.iOS-26-1.23B86")
        let busy = await cleaner.clean([ScanItem(url: running, size: 10, category: .simulatorDyldCaches,
                                                 removal: .dyldCacheRemove(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-1", build: "23B86"))],
                                       permanently: false)
        #expect(busy.failures.map(\.reason) == [ManagerRemovalError.runtimeBusy.localizedDescription])

        let forged = await cleaner.clean([item("com.apple.CoreSimulator.SimRuntime.iOS-18-6", "22G86 --all")], permanently: false)
        #expect(forged.failures.map(\.reason) == ["Операция не совпадает с элементом — удаление отменено"], "операция — не этой папки")

        let report = await cleaner.clean([item("com.apple.CoreSimulator.SimRuntime.iOS-18-6", "22G86")], permanently: false)
        #expect(commands.list.filter { $0.contains("dyld_shared_cache") }
                == [[Self.simctl, "runtime", "dyld_shared_cache", "remove", "com.apple.CoreSimulator.SimRuntime.iOS-18-6/22G86"]])
        #expect(report.removedByManagers == 1 && report.failures.isEmpty)
    }

    @Test func applicationCachesAreKeptWhileProgramHoldsFiles() async throws {
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        for program in ["Busy", "Idle", "Unknown"] {
            try makeFile(support.appending(path: "\(program)/Local State"), bytes: 10)
            try makeFile(support.appending(path: "\(program)/Cache/data_0"), bytes: 100)
        }
        defer { cleanUp() }

        let checked = Commands()
        var cleaner = makeCleaner(commands: Commands()) { _ in Data() }
        cleaner.hasOpenFiles = { folder in
            checked.append([folder.lastPathComponent])
            return switch folder.lastPathComponent {
            case "Busy": true
            case "Idle": false
            default: nil
            }
        }
        let items = ["Busy", "Idle", "Unknown"].map {
            ScanItem(url: support.appending(path: "\($0)/Cache"), size: 100, category: .applicationSupportCaches, isRecommended: true)
        } + [ScanItem(url: support.appending(path: "Idle/Code Cache"), size: 0, category: .applicationSupportCaches, isRecommended: true)]
        try FileManager.default.createDirectory(at: support.appending(path: "Idle/Code Cache"), withIntermediateDirectories: true)

        let report = await cleaner.clean(items, permanently: true)

        #expect(Set(report.removed) == Set([support.appending(path: "Idle/Cache"), support.appending(path: "Idle/Code Cache")]))
        #expect(report.failures.map(\.reason) == ["Программа запущена — закройте её и повторите",
                                                  "Не понять, запущена ли программа, — кэш не трогаем"])
        #expect(checked.list.count == 3, "папка программы проверяется один раз")
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "Busy/Cache").path))
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "Idle/Local State").path), "данные рядом не тронуты")
    }

    // MARK: - Docker, conda, Ollama

    @Test func dockerPrunesOnlyItsTargetAndNeverVolumes() async throws {
        defer { cleanUp() }
        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { history in
            if history.last?.contains("builder") == true {
                throw CommandRunner.Failure.exitStatus(1)
            }
            return Data()
        }
        let disk = home.appending(path: "Docker.raw")
        let items = [ManagerRemoval.DockerTarget.containers, .images, .buildCache].map {
            ScanItem(url: TerminalScanner.dockerPart(disk, $0), size: 10, category: .docker, removal: .dockerPrune($0))
        }

        let report = await cleaner.clean(items, permanently: false)
        let docker = [Self.docker] + TerminalScanner.dockerHost(home: home)

        // Образы раньше контейнеров: иначе снесли бы и образы только что удалённых контейнеров.
        #expect(commands.list == [docker + ["image", "prune", "-a", "-f"], docker + ["builder", "prune", "-a", "-f"],
                                  docker + ["container", "prune", "-f"]])
        #expect(commands.list.allSatisfy { $0.contains("unix://" + home.appending(path: ".docker/run/docker.sock").path) },
                "всегда движок Docker Desktop, а не текущий контекст")
        #expect(!commands.list.joined().contains { $0.contains("volume") }, "тома не трогаем никогда")
        #expect(report.removedByManagers == 2)
        #expect(report.failures.map(\.reason) == [ManagerRemovalError.failed(tool: "docker", status: 1).localizedDescription])
    }

    @Test func condaRemovesOnlyRealEnvironmentsWithItsOwnConda() async throws {
        let base = home.appending(path: "miniforge3")
        try makeFile(base.appending(path: "conda-meta/history"), bytes: 10)
        try makeExecutable(base.appending(path: "bin/conda"))
        let environment = base.appending(path: "envs/ml")
        try makeFile(environment.appending(path: "conda-meta/history"), bytes: 10)
        let project = home.appending(path: "Documents/project")
        try makeFile(project.appending(path: "conda-meta/history"), bytes: 10)
        defer { cleanUp() }

        let conda = base.appending(path: "bin/conda").path
        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { history in
            if history.last?.contains("remove") == true {
                try? FileManager.default.removeItem(at: environment)
            }
            return Data()
        }
        let cache = base.appending(path: "pkgs")
        let items = [
            ScanItem(url: environment, size: 10, category: .conda, removal: .condaRemoveEnvironment(conda: conda, prefix: environment.path)),
            ScanItem(url: cache, size: 10, category: .conda, removal: .condaClean(conda: conda)),
            // База и посторонняя папка с conda-meta — не окружения; чужой исполняемый файл — не conda.
            ScanItem(url: base, size: 1, category: .conda, removal: .condaRemoveEnvironment(conda: conda, prefix: base.path)),
            ScanItem(url: project, size: 1, category: .conda, removal: .condaRemoveEnvironment(conda: conda, prefix: project.path)),
            ScanItem(url: home.appending(path: "x"), size: 1, category: .conda, removal: .condaClean(conda: "/bin/sh")),
            // Операция чужого окружения у этого элемента.
            ScanItem(url: project, size: 1, category: .conda, removal: .condaRemoveEnvironment(conda: conda, prefix: environment.path)),
        ]

        let report = await cleaner.clean(items, permanently: false)

        #expect(commands.list == [[conda, "remove", "-p", environment.path, "--all", "-y"], [conda, "clean", "--all", "-y"]])
        #expect(report.removed == [environment, cache])
        #expect(report.failures.map(\.reason) == Array(repeating: ManagerRemovalError.invalidIdentifier.localizedDescription, count: 3)
                + ["Операция не совпадает с элементом — удаление отменено"])
        #expect(FileManager.default.fileExists(atPath: project.path))
    }

    @Test func ollamaModelIsDeletedByServerAndFailuresAreExplained() async throws {
        defer { cleanUp() }
        let commands = Commands()
        let cleaner = makeCleaner(commands: commands) { history in
            let request = history.last?.joined(separator: " ") ?? ""
            if request.contains("gone:1") {
                return Data("404".utf8)
            }
            if request.contains("offline:1") {
                throw CommandRunner.Failure.exitStatus(7)
            }
            return Data("200".utf8)
        }
        // Манифест модели «elsewhere:1» на месте после ответа 200 — сервер удалил одноимённую модель в другой папке.
        let names = ["user/llama3:8b-q4_K_M", "gone:1", "offline:1", "--output=x", "elsewhere:1"]
        let items = names.map { ScanItem(url: home.appending(path: $0), size: 10, category: .ollama, removal: .ollamaDelete(model: $0)) }
        try makeFile(home.appending(path: "elsewhere:1"), bytes: 10)

        let report = await cleaner.clean(items, permanently: false)
        let request = try #require(commands.list.first)

        #expect(Array(request.prefix(2)) == [ManagerRemover.curl, "-q"] && request.last == ManagerRemover.ollamaDeleteURL, "без ~/.curlrc")
        #expect(request.contains("--noproxy"))
        #expect(request.contains(#"{"model":"user/llama3:8b-q4_K_M"}"#))
        #expect(report.removed == [home.appending(path: "user/llama3:8b-q4_K_M")])
        #expect(report.failures.map(\.reason) == [ManagerRemovalError.ollamaModelGone, .ollamaNotRunning, .invalidIdentifier].map(\.localizedDescription)
                + [CleanerError.leftInPlace.localizedDescription])
        #expect(commands.list.count == 4, "подделанное имя до curl не дошло")
    }

    // MARK: - Helpers

    private var homebrewCache: URL { home.appending(path: "Library/Caches/Homebrew", directoryHint: .isDirectory) }

    /// Cleaner с подменёнными `simctl` и `brew`: `answer` получает историю команд — исполняемый файл и аргументы,
    /// включая текущую.
    private func makeCleaner(commands: Commands, system: SystemLocations = SystemLocations(),
                             answer: @escaping @Sendable ([[String]]) throws -> Data) -> Cleaner {
        let runner = CommandRunner { executable, arguments in
            commands.append([executable] + arguments)
            return try answer(commands.list)
        }
        var cleaner = Cleaner(safetyGuard: SafetyGuard(home: home, system: system))
        cleaner.system = system
        cleaner.remover = ManagerRemover(runner: runner, simctl: { Self.simctl }, brew: { Self.brew }, homebrewCache: homebrewCache)
        let home = home
        cleaner.versionActivity = { ToolCatalog.activity(ofVersionAt: $0, home: home) }
        cleaner.remover.docker = { Self.docker }
        cleaner.remover.dockerHost = TerminalScanner.dockerHost(home: home)
        return cleaner
    }

    private static func devices(_ devices: [(udid: String, state: String, runtime: String)]) -> Data {
        let grouped = Dictionary(grouping: devices, by: \.runtime).mapValues { list in
            list.map { ["udid": $0.udid, "name": "iPhone", "state": $0.state, "isAvailable": true] as [String: Any] }
        }
        return (try? JSONSerialization.data(withJSONObject: ["devices": grouped])) ?? Data()
    }

    /// Вывод `brew cleanup --dry-run` для этих путей.
    private func dryRun(_ paths: [URL]) -> String {
        paths.map { "Would remove: \($0.standardizedFileURL.path) (1.2MB)\n" }.joined()
            + "==> This operation would free approximately 3.6MB of disk space.\n"
    }

    /// Системные папки во временной папке: `/usr/local` и `/Library` своего теста.
    private func temporarySystem() -> SystemLocations {
        var system = SystemLocations()
        system.usrLocal = base.appending(path: "usr-local", directoryHint: .isDirectory)
        system.library = base.appending(path: "Library", directoryHint: .isDirectory)
        system.macPortsPrefix = base.appending(path: "opt-local", directoryHint: .isDirectory)
        return system
    }

    private func lock(_ folders: [URL]) {
        for folder in folders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
    }

    private func unlock(_ folders: [URL]) {
        for folder in folders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
    }

    private func writePlist(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    private func makeExecutable(_ url: URL) throws {
        try makeFile(url, bytes: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}

/// Запущенные команды — исполняемый файл и аргументы, по порядку; общий между потоками, поэтому под замком.
private final class Commands: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    var list: [[String]] { lock.withLock { stored } }

    func append(_ command: [String]) {
        lock.withLock { stored.append(command) }
    }
}
