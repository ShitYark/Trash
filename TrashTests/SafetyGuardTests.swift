import Foundation
import Testing
@testable import Trash

struct SafetyGuardTests {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    var caches: URL { home.appending(path: "Library/Caches", directoryHint: .isDirectory) }
    var safetyGuard: SafetyGuard { SafetyGuard(allowedRoots: [caches], home: home) }

    @Test func allowsItemInsideRoot() {
        #expect(safetyGuard.canDelete(caches.appending(path: "com.example.app")))
        #expect(safetyGuard.canDelete(caches.appending(path: "com.example.app/nested/file.db")))
    }

    @Test func rejectsRootItself() {
        #expect(!safetyGuard.canDelete(caches))
    }

    @Test func rejectsPathsOutsideRoots() {
        #expect(!safetyGuard.canDelete(home.appending(path: "Documents/important.txt")))
        #expect(!safetyGuard.canDelete(home.appending(path: "Library/Preferences/com.apple.finder.plist")))
    }

    @Test func rejectsSiblingWithSamePrefix() {
        #expect(!safetyGuard.canDelete(home.appending(path: "Library/CachesBackup/file")))
    }

    @Test func rejectsParentDirectoryTraversal() {
        #expect(!safetyGuard.canDelete(caches.appending(path: "../Preferences")))
        #expect(!safetyGuard.canDelete(caches.appending(path: "com.example/../../../Documents")))
    }

    @Test func searchOnlyCategoriesAreNotDeletable() {
        let defaultGuard = SafetyGuard(home: home)
        let developer = home.appending(path: "Library/Developer", directoryHint: .isDirectory)

        #expect(!defaultGuard.canDelete(home.appending(path: "Library/Android/sdk/platforms/android-36")), "Android — только поиск")
        #expect(!defaultGuard.canDelete(developer.appending(path: "CoreSimulator/Devices")), "папка симуляторов целиком — никогда")
        #expect(!defaultGuard.canDelete(URL(filePath: "/Applications")), "папка программ целиком — никогда")
        #expect(!defaultGuard.canDelete(URL(filePath: "/Applications/Xcode-beta.app/Contents")), "содержимое бандла — никогда")
        #expect(defaultGuard.canDelete(developer.appending(path: "Xcode/DerivedData/App-abc")))
        #expect(defaultGuard.canDelete(developer.appending(path: "Xcode/UserData/Previews/Simulator Devices")))
    }

    /// Соседи корней Xcode — настройки и данные пользователя. Сдвиг корня на уровень выше уронит этот тест.
    @Test func xcodeUserDataNextToRootsIsNotDeletable() {
        let defaultGuard = SafetyGuard(home: home)
        let library = home.appending(path: "Library", directoryHint: .isDirectory)

        for path in ["Developer/Xcode/UserData/KeyBindings", "Developer/Xcode/UserData/CodeSnippets",
                     "Developer/Xcode/UserData/FontAndColorThemes", "Developer/Xcode/Templates",
                     "Developer/Xcode/UserData", "Developer/Xcode", "Developer/CoreSimulator",
                     "org.swift.swiftpm/configuration", "Preferences/com.apple.dt.Xcode.plist"] {
            #expect(!defaultGuard.canDelete(library.appending(path: path)), "\(path)")
        }
    }

    @Test func rejectsProtectedPaths() {
        let unsafeGuard = SafetyGuard(allowedRoots: [URL(filePath: "/")], home: home)
        #expect(!unsafeGuard.canDelete(URL(filePath: "/")))
        #expect(!unsafeGuard.canDelete(URL(filePath: "/System")))
        #expect(!unsafeGuard.canDelete(home))
        #expect(!unsafeGuard.canDelete(home.appending(path: "Documents")))
    }

    /// Настройки инструментов рядом с удаляемыми кэшами Терминала не удаляются.
    @Test func toolSettingsNextToTerminalCachesAreNotDeletable() {
        let defaultGuard = SafetyGuard(home: home)

        for path in [".gradle/gradle.properties", ".gradle/init.d/init.gradle", ".npmrc", ".npm/_logs/debug.log",
                     ".cargo/config.toml", ".cargo/bin/ripgrep", ".m2/settings.xml", ".pub-cache/bin/flutterfire",
                     ".pub-cache/global_packages/x", ".android/avd/tablet.avd", "Library/Android/sdk/platforms/android-36",
                     "Library/LaunchAgents/com.example.plist", ".local/bin/tool", ".pyenv/version", ".pyenv/versions",
                     ".bun/bin/bun", ".bun/install/global/node_modules/x", ".bunfig.toml", ".asdf/installs/nodejs/20.1.0",
                     ".local/share/mise/installs/node/22.11.0", ".ollama/models/blobs/sha256-a", "miniforge3/envs/ml"] {
            #expect(!defaultGuard.canDelete(home.appending(path: path)), "\(path)")
        }
        #expect(defaultGuard.canDelete(home.appending(path: ".gradle/caches/modules-2")))
        #expect(defaultGuard.canDelete(home.appending(path: ".npm/_cacache/content-v2")))
        #expect(defaultGuard.canDelete(home.appending(path: ".cache/firebase")))
        #expect(defaultGuard.canDelete(home.appending(path: ".bun/install/cache/react@18.3.1@@@1")))
        // Глобальное хранилище Bun: на него ссылаются node_modules проектов — страж не пускает и без сканера.
        #expect(!defaultGuard.canDelete(home.appending(path: ".bun/install/cache/links")))
        #expect(!defaultGuard.canDelete(home.appending(path: ".bun/install/cache/links/react@18.3.1-hash"), as: .toolCaches))
    }

    /// Симуляторы и версии языков — узкими правилами: только сама папка симулятора или версии, не соседи
    /// и не содержимое; чужим разделам эти папки не достаются.
    @Test func simulatorAndVersionFoldersAreDeletableOnlyThemselves() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "TrashSafetyGuardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let devices = home.appending(path: "Library/Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
        let udid = UUID().uuidString
        try FileManager.default.createDirectory(at: devices.appending(path: "\(udid)/data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".pyenv/versions/3.11.0/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appending(path: ".pyenv/versions/latest").path, withDestinationPath: "3.11.0")
        let defaultGuard = SafetyGuard(home: home)
        // asdf поставлен после создания стража — его папки версий всё равно учитываются.
        try FileManager.default.createDirectory(at: home.appending(path: ".asdf/installs/nodejs/20.1.0/bin"), withIntermediateDirectories: true)

        #expect(defaultGuard.canDelete(devices.appending(path: udid), as: .simulators))
        #expect(defaultGuard.canDelete(home.appending(path: ".pyenv/versions/3.11.0"), as: .languageVersions))
        #expect(defaultGuard.canDelete(home.appending(path: ".asdf/installs/nodejs/20.1.0"), as: .languageVersions))

        for path in ["device_set.plist", "\(udid)/data", "not-a-uuid", ""] {
            #expect(!defaultGuard.canDelete(devices.appending(path: path), as: .simulators), "Devices/\(path)")
        }
        for path in [".pyenv/versions", ".pyenv/version", ".pyenv/versions/3.11.0/bin", ".pyenv/versions/.hidden", ".pyenv/versions/latest",
                     ".asdf/installs/nodejs", ".asdf/installs/nodejs/20.1.0/bin", "Library/Caches/com.example"] {
            #expect(!defaultGuard.canDelete(home.appending(path: path), as: .languageVersions), "\(path)")
        }
        #expect(!defaultGuard.canDelete(devices.appending(path: udid), as: .xcodeCaches))
        #expect(!defaultGuard.canDelete(devices.appending(path: udid)), "папка симуляторов — не корень")
        #expect(!defaultGuard.canDelete(home.appending(path: ".pyenv/versions/3.11.0"), as: .toolCaches))
    }

    /// Android — узким правилом: пакет SDK с `package.xml` на своей глубине или `<имя>.avd` прямо в папке эмуляторов.
    @Test func androidPackagesAndEmulatorsAreDeletableOnlyThemselves() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "TrashSafetyGuardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let packages = ["system-images/android-34/google_apis/arm64-v8a", "build-tools/35.0.0", "ndk/27.0.1", "platforms/android-36"]
        for package in packages {
            try makeFile(sdk.appending(path: "\(package)/package.xml"))
        }
        try makeFile(sdk.appending(path: "build-tools/30.0.3/aapt"))
        try makeFile(sdk.appending(path: "emulator/package.xml"))
        let avds = home.appending(path: ".android/avd", directoryHint: .isDirectory)
        try makeFile(avds.appending(path: "tablet.avd/config.ini"))
        try makeFile(avds.appending(path: "tablet.ini"))
        let defaultGuard = SafetyGuard(home: home)

        for package in packages {
            #expect(defaultGuard.canDelete(sdk.appending(path: package), as: .androidSDK), "\(package)")
        }
        #expect(defaultGuard.canDelete(avds.appending(path: "tablet.avd"), as: .androidSDK))

        for path in ["build-tools/30.0.3", "emulator", "system-images/android-34", "system-images/android-34/google_apis/arm64-v8a/package.xml",
                     "build-tools", "", "licenses/android-sdk-license"] {
            #expect(!defaultGuard.canDelete(sdk.appending(path: path), as: .androidSDK), "sdk/\(path) — без package.xml или не на своей глубине")
        }
        for path in ["tablet.ini", "tablet.avd/config.ini", ""] {
            #expect(!defaultGuard.canDelete(avds.appending(path: path), as: .androidSDK), "avd/\(path)")
        }
        // Ссылка на пакет и скрытые папки — нет, даже с package.xml.
        try FileManager.default.createSymbolicLink(at: sdk.appending(path: "build-tools/link"), withDestinationURL: sdk.appending(path: "build-tools/35.0.0"))
        try makeFile(sdk.appending(path: ".temp/build-tools/package.xml"))
        try makeFile(sdk.appending(path: "build-tools/.partial/package.xml"))
        for path in ["build-tools/link", "build-tools/.partial"] {
            #expect(!defaultGuard.canDelete(sdk.appending(path: path), as: .androidSDK), "sdk/\(path)")
        }
        #expect(defaultGuard.canDeleteEmulatorConfig(avds.appending(path: "tablet.ini")))
        try FileManager.default.createDirectory(at: avds.appending(path: "folder.ini"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: avds.appending(path: "link.ini"), withDestinationURL: avds.appending(path: "tablet.ini"))
        for name in ["folder.ini", "link.ini", "tablet.avd"] {
            #expect(!defaultGuard.canDeleteEmulatorConfig(avds.appending(path: name)), "\(name) — не обычный файл ini")
        }
        #expect(!defaultGuard.canDelete(sdk.appending(path: "build-tools/35.0.0"), as: .toolCaches), "папка SDK — не корень для других разделов")
        #expect(!defaultGuard.canDelete(avds.appending(path: "tablet.avd")))
    }

    /// Ссылки и службы — узкими правилами, в том числе вне `~`: только битая ссылка прямо в папке команд
    /// и только обычный plist прямо в папке служб.
    @Test func brokenLinksAndServicePlistsAreDeletableOnlyThemselves() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "TrashSafetyGuardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appending(path: "home", directoryHint: .isDirectory)
        var system = SystemLocations()
        system.usrLocal = base.appending(path: "usr-local", directoryHint: .isDirectory)
        system.library = base.appending(path: "Library", directoryHint: .isDirectory)
        let bin = system.usrLocal.appending(path: "bin")
        try makeFile(bin.appending(path: "program"))
        let link = { (url: URL, destination: String) in try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination) }
        try link(bin.appending(path: "broken"), "/nonexistent/program")
        try link(bin.appending(path: "alive"), bin.appending(path: "program").path)
        try link(bin.appending(path: ".hidden"), "/nonexistent/program")
        try makeFile(home.appending(path: ".local/bin/.keep"))
        try link(home.appending(path: ".local/bin/broken"), "/nonexistent/program")
        try makeFile(system.usrLocal.appending(path: "lib/.keep"))
        try link(system.usrLocal.appending(path: "lib/broken"), "/nonexistent/program")
        let daemons = system.library.appending(path: "LaunchDaemons")
        try makeFile(daemons.appending(path: "com.example.gone.plist"))
        try makeFile(daemons.appending(path: "notes.txt"))
        try link(daemons.appending(path: "com.example.link.plist"), daemons.appending(path: "com.example.gone.plist").path)
        try makeFile(system.library.appending(path: "Preferences/com.example.plist"))
        try makeFile(home.appending(path: "Library/LaunchAgents/com.example.agent.plist"))
        let defaultGuard = SafetyGuard(home: home, system: system)

        #expect(defaultGuard.canDelete(bin.appending(path: "broken"), as: .terminalPrograms))
        #expect(defaultGuard.canDelete(home.appending(path: ".local/bin/broken"), as: .terminalPrograms))
        for path in ["alive", "program", ".hidden"] {
            #expect(!defaultGuard.canDelete(bin.appending(path: path), as: .terminalPrograms), "bin/\(path) — не битая ссылка")
        }
        #expect(!defaultGuard.canDelete(system.usrLocal.appending(path: "lib/broken"), as: .terminalPrograms), "не папка команд")
        #expect(!defaultGuard.canDelete(bin.appending(path: "broken"), as: .userCaches), "другой раздел ссылку не получит")

        #expect(defaultGuard.canDelete(daemons.appending(path: "com.example.gone.plist"), as: .backgroundServices))
        #expect(defaultGuard.canDelete(home.appending(path: "Library/LaunchAgents/com.example.agent.plist"), as: .backgroundServices))
        for url in [daemons.appending(path: "notes.txt"), daemons.appending(path: "com.example.link.plist"), daemons,
                    system.library.appending(path: "Preferences/com.example.plist")] {
            #expect(!defaultGuard.canDelete(url, as: .backgroundServices), "\(url.lastPathComponent)")
        }
        #expect(!defaultGuard.canDelete(home.appending(path: "Library/LaunchAgents/com.example.agent.plist")), "папка агентов — не корень")
    }

    @Test func everyCategoryRootIsInsideHomeAndNotProtected() {
        for category in CleanupCategory.allCases {
            for root in category.roots(home: home) {
                #expect(root.path.hasPrefix(home.path + "/"), "\(category) → \(root.path)")
                #expect(!safetyGuard.protectedPaths.contains(SafetyGuard.normalized(root).path), "\(category) → \(root.path)")
            }
        }
    }

    // MARK: - Helpers

    private func makeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
