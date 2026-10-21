import Foundation
import Testing
@testable import Trash

/// Раздел «Терминал». Временная «домашняя папка» и временные системные папки; `brew` подменён JSON-фикстурой.
struct TerminalScannerTests {
    /// Структура — как у `brew info --json=v2 --installed` в Homebrew 7: лишние поля пропущены, `depends_on` у cask бывает и с `macos`.
    static let brewJSON = Data("""
    {
      "formulae": [
        {"name": "node", "full_name": "node", "desc": "JavaScript runtime", "linked_keg": "22.0", "outdated": false, "pinned": false,
         "versions": {"stable": "22.0"},
         "installed": [{"version": "22.0", "installed_on_request": true,
                        "runtime_dependencies": [{"full_name": "icu4c@74", "version": "74"}, {"full_name": "brotli", "version": "1.2.0"}]}]},
        {"name": "icu4c", "full_name": "icu4c", "aliases": ["icu4c@74"], "linked_keg": "74", "outdated": false,
         "installed": [{"version": "74", "installed_on_request": false, "runtime_dependencies": []}]},
        {"name": "brotli", "full_name": "brotli", "linked_keg": "1.2.0", "outdated": false, "pinned": false,
         "installed": [{"version": "1.1.0", "installed_on_request": false}, {"version": "1.2.0", "installed_on_request": false}]},
        {"name": "imath", "full_name": "imath", "linked_keg": "3.1.12", "outdated": true, "versions": {"stable": "3.2.3"},
         "installed": [{"version": "3.1.11", "installed_on_request": false}, {"version": "3.1.12", "installed_on_request": true}]},
        {"name": "giflib", "full_name": "giflib", "linked_keg": "5.2.2",
         "installed": [{"version": "5.2.2", "installed_on_request": false}]},
        {"name": "libpng", "full_name": "libpng", "linked_keg": "1.6.59",
         "installed": [{"version": "1.6.59", "installed_on_request": false}]},
        {"name": "openjdk@11", "full_name": "openjdk@11", "linked_keg": null, "keg_only": true,
         "installed": [{"version": "11.0.32.1", "installed_on_request": true}]},
        {"name": "custom-tool", "full_name": "custom-tool", "linked_keg": "1.0", "build_dependencies": ["pkgconf"],
         "installed": [{"version": "1.0", "installed_on_request": false, "poured_from_bottle": false}]},
        {"name": "pkgconf", "full_name": "pkgconf", "linked_keg": "2.0",
         "installed": [{"version": "2.0", "installed_on_request": false}]},
        {"name": "python@3.12", "full_name": "python@3.12", "linked_keg": "3.12.1", "outdated": false, "versions": {"stable": "3.12.4"},
         "installed": [{"version": "3.12.1", "installed_on_request": true}, {"version": "3.12.4", "installed_on_request": true}]}
      ],
      "casks": [
        {"token": "xcodes-app", "desc": "Xcode version manager", "installed": "1.10.0",
         "depends_on": {"macos": {">=": ["14"]}, "formula": ["libpng"]}}
      ]
    }
    """.utf8)

    let base: URL
    let home: URL
    let system: SystemLocations

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "TrashTerminalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = base.appending(path: "home", directoryHint: .isDirectory)
        system = SystemLocations(
            applications: base.appending(path: "Applications", directoryHint: .isDirectory),
            usrLocal: base.appending(path: "usr-local", directoryHint: .isDirectory),
            library: base.appending(path: "Library", directoryHint: .isDirectory),
            homebrewPrefixes: [base.appending(path: "homebrew", directoryHint: .isDirectory)],
            opt: base.appending(path: "opt", directoryHint: .isDirectory),
            macPortsPrefix: base.appending(path: "opt-local", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    // MARK: - Homebrew

    @Test func homebrewMarksUnneededDependenciesAndOldVersionsLikeBrew() async throws {
        let cellar = base.appending(path: "homebrew/Cellar", directoryHint: .isDirectory)
        try makeFile(base.appending(path: "homebrew/bin/brew"), bytes: 0)
        try makeFile(cellar.appending(path: "brotli/1.1.0/lib/libbrotli.dylib"), bytes: 1_000)
        try makeFile(cellar.appending(path: "giflib/5.2.2/lib/libgif.dylib"), bytes: 1_000)
        defer { cleanUp() }

        let result = await scanner(brew: Self.brewJSON).scan(.homebrew)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))
        let titles = Set(result.items.map(\.title))

        #expect(recommended == ["giflib", "brotli 1.1.0"], "giflib не нужен никому, brotli 1.1.0 — старая версия")
        #expect(titles.isSuperset(of: ["node", "icu4c", "brotli", "libpng", "imath 3.1.11", "openjdk@11", "xcodes-app",
                                       "custom-tool", "pkgconf", "python@3.12", "python@3.12 3.12.4"]))
        #expect(result.items.first { $0.title == "icu4c" }?.details?.contains("нужен — node") == true, "зависимость через синоним icu4c@74")
        #expect(result.items.first { $0.title == "python@3.12 3.12.4" }?.details?.contains("не старше свежей") == true,
                "подключена старая 3.12.1 — новую 3.12.4 brew cleanup не удаляет")
        #expect(result.items.first { $0.title == "imath 3.1.11" }?.details?.contains("ждёт обновления") == true,
                "у устаревшей формулы brew cleanup старые версии не чистит")
        #expect(result.items.first { $0.title == "libpng" }?.isRecommended == false, "нужна cask через depends_on")
        // Удалить можно ровно то, что удалил бы brew: ненужное — `uninstall`, старые версии — `cleanup`.
        #expect(Set(result.items.filter { $0.isDeletable }.map { $0.title }) == Set(result.items.filter { $0.isRecommended }.map { $0.title }))
        #expect(result.items.first { $0.title == "giflib" }?.removal == .brewUninstall(formula: "giflib"))
        #expect(result.items.first { $0.title == "brotli 1.1.0" }?.removal == .brewCleanup(formula: "brotli"))
        #expect(result.items.first { $0.title == "node" }?.isDeletable == false, "явно поставленное — только поиск")
        #expect(result.items.first { $0.title == "xcodes-app" }?.isDeletable == false, "cask — только поиск")
    }

    /// Ненужную зависимость, которую закрепили или пометили `.keepme`, держат сознательно: ни операции, ни метки «мусор».
    @Test func pinnedOrKeptUnneededFormulaIsNotRemovable() async throws {
        let cellar = base.appending(path: "homebrew/Cellar", directoryHint: .isDirectory)
        try makeFile(base.appending(path: "homebrew/bin/brew"), bytes: 0)
        for formula in ["libpinned", "libkept", "libfree"] {
            try makeFile(cellar.appending(path: "\(formula)/1.0/lib/lib.dylib"), bytes: 1_000)
        }
        try makeFile(cellar.appending(path: "libkept/1.0/.keepme"), text: "/Applications/Tool.app\n")
        defer { cleanUp() }
        let brew = Data("""
        {"formulae": [
          {"name": "libpinned", "full_name": "libpinned", "linked_keg": "1.0", "pinned": true,
           "installed": [{"version": "1.0", "installed_on_request": false}]},
          {"name": "libkept", "full_name": "libkept", "linked_keg": "1.0",
           "installed": [{"version": "1.0", "installed_on_request": false}]},
          {"name": "libfree", "full_name": "libfree", "linked_keg": "1.0",
           "installed": [{"version": "1.0", "installed_on_request": false}]}
        ], "casks": []}
        """.utf8)

        let result = await scanner(brew: brew).scan(.homebrew)
        let item = { (title: String) in result.items.first { $0.title == title } }

        #expect(item("libfree")?.removal == .brewUninstall(formula: "libfree"))
        for title in ["libpinned", "libkept"] {
            #expect(item(title)?.removal == nil && item(title)?.isRecommended == false, "\(title)")
        }
        #expect(item("libpinned")?.details?.contains("закреплена") == true)
        #expect(item("libkept")?.details?.contains(".keepme") == true)
    }

    @Test func homebrewWithoutBrewIsNotGuessed() async {
        defer { cleanUp() }
        let result = await scanner(brew: Self.brewJSON).scan(.homebrew)

        #expect(result.items.isEmpty)
        #expect(result.unavailableReason == nil, "Homebrew нет — пусто без причины, раздел скрывается")
    }

    @Test func homebrewFailureIsReported() async throws {
        try makeFile(base.appending(path: "homebrew/bin/brew"), bytes: 0)
        defer { cleanUp() }
        let result = await scanner(brew: nil).scan(.homebrew)

        #expect(result.unavailableReason == TerminalScanner.brewFailedReason)
    }

    // MARK: - Android

    @Test func androidMarksUnusedImagesAndOlderBuildTools() async throws {
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        try makeFile(sdk.appending(path: "system-images/android-36/google_apis/arm64-v8a/system.img"), bytes: 2_000)
        try makeFile(sdk.appending(path: "system-images/android-34/google_apis/arm64-v8a/system.img"), bytes: 2_000)
        for version in ["30.0.3", "35.0.0", "36.0.0"] {
            try makeFile(sdk.appending(path: "build-tools/\(version)/aapt"), bytes: 100)
        }
        try makeFile(sdk.appending(path: "platforms/android-36/android.jar"), bytes: 100)
        try makeFile(sdk.appending(path: "emulator/emulator"), bytes: 100)
        try makeFile(sdk.appending(path: "licenses/android-sdk-license"), bytes: 10)
        try writeText("avd.ini.displayname=Tablet\nimage.sysdir.1 = system-images/android-36/google_apis/arm64-v8a/\n",
                      to: home.appending(path: ".android/avd/tablet.avd/config.ini"))
        defer { cleanUp() }

        let result = await scanner().scan(.androidSDK)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(recommended == ["Android 34 · google_apis · arm64-v8a", "build-tools 30.0.3", "build-tools 35.0.0"])
        #expect(result.items.contains { $0.title == "Tablet" }, "эмулятор показан")
        #expect(!result.items.contains { $0.url.lastPathComponent == "licenses" }, "лицензии не показываются")
        let searchOnly = Set(result.items.filter { !$0.isDeletable }.map(\.url.lastPathComponent))
        #expect(searchOnly == ["emulator"], "образы, build-tools, платформы и эмуляторы удаляются; эмулятор-программа — только поиск")
        #expect(!result.items.contains { $0.isRecommended && $0.isDeletable && $0.category.autoSelectsRecommended }, "сами не отмечаются")
    }

    // MARK: - Gradle и кэши

    @Test func gradleKeepsNewestDistributionOnly() async throws {
        let gradle = home.appending(path: ".gradle", directoryHint: .isDirectory)
        try makeFile(gradle.appending(path: "caches/modules-2/files.bin"), bytes: 1_000)
        try makeFile(gradle.appending(path: "wrapper/dists/gradle-6.7.1-all/hash/gradle.zip"), bytes: 1_000)
        try makeFile(gradle.appending(path: "wrapper/dists/gradle-8.13-bin/hash/gradle.zip"), bytes: 1_000)
        try makeFile(gradle.appending(path: "wrapper/dists/CACHEDIR.TAG"), bytes: 10)
        try makeFile(gradle.appending(path: "gradle.properties"), bytes: 10)
        defer { cleanUp() }

        let result = await scanner().scan(.gradle)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(Set(result.items.map(\.title)) == ["modules-2", "gradle-6.7.1-all", "gradle-8.13-bin"], "CACHEDIR.TAG и настройки не показываются")
        #expect(recommended == ["modules-2", "gradle-6.7.1-all"])
        #expect(result.items.allSatisfy { $0.isDeletable })
    }

    @Test func toolCachesAreLabelledAndNotCountedTwice() async throws {
        let caches = home.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try makeFile(caches.appending(path: "Homebrew/downloads/bottle.tar.gz"), bytes: 1_000)
        try makeFile(caches.appending(path: "pip/http-v2/blob"), bytes: 1_000)
        try makeFile(caches.appending(path: "com.example.app/cache.db"), bytes: 1_000)
        try makeFile(home.appending(path: ".npm/_cacache/content-v2/blob"), bytes: 1_000)
        defer { cleanUp() }

        let scanner = scanner()
        let userCaches = await scanner.scan(.userCaches)
        let toolCaches = await scanner.scan(.toolCaches)
        let labels = Dictionary(toolCaches.items.map { ($0.title, $0.details ?? "") }, uniquingKeysWith: { first, _ in first })

        #expect(userCaches.items.map(\.title) == ["com.example.app"], "кэши Homebrew и pip — только в разделе Терминала")
        #expect(labels == ["downloads": "Homebrew", "http-v2": "pip", "content-v2": "npm"])
        #expect(toolCaches.items.allSatisfy { $0.isRecommended && $0.isDeletable })
    }

    @Test func cachesThatAreNotOnlyCacheAreShownButNotMarked() async throws {
        try makeFile(home.appending(path: ".m2/repository/com/example/app/1.0/app-1.0.jar"), bytes: 1_000)
        try makeFile(home.appending(path: ".cache/huggingface/token"), bytes: 10)
        try makeFile(home.appending(path: ".pub-cache/hosted/pub.dev/args-2.0.0/lib/args.dart"), bytes: 100)
        try makeFile(home.appending(path: ".npm/_cacache/content-v2/blob"), bytes: 1_000)
        defer { cleanUp() }

        let result = await scanner().scan(.toolCaches)
        let byTitle = Dictionary(result.items.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(result.items.filter { $0.isRecommended }.map { $0.title } == ["content-v2"], "сам отмечается только настоящий кэш")
        #expect(byTitle["com"]?.details?.contains("mvn install") == true)
        #expect(byTitle["huggingface"]?.details?.contains("токены") == true)
        #expect(byTitle["pub.dev"]?.details?.contains("pub global activate") == true)
        #expect(result.items.allSatisfy { $0.isDeletable }, "удалить по-прежнему можно — вручную")
    }

    // MARK: - Программы и службы

    @Test func programsShowInstallersAndMarkBrokenLinks() async throws {
        let bin = system.usrLocal.appending(path: "bin", directoryHint: .isDirectory)
        let python = system.library.appending(path: "Frameworks/Python.framework/Versions", directoryHint: .isDirectory)
        try makeFile(python.appending(path: "3.12/bin/python3"), bytes: 1_000)
        try FileManager.default.createSymbolicLink(atPath: python.appending(path: "Current").path, withDestinationPath: "3.12")
        try makeFile(system.usrLocal.appending(path: "lib/node_modules/corepack/package.json"), text: #"{"name": "corepack", "version": "0.34.0"}"#)
        try makeFile(base.appending(path: "homebrew/Cellar/jq/1.7/bin/jq"), bytes: 100)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try link(bin.appending(path: "python3"), to: python.appending(path: "3.12/bin/python3").path)
        try link(bin.appending(path: "corepack"), to: "../lib/node_modules/corepack/dist/corepack.js")
        try link(bin.appending(path: "jq"), to: base.appending(path: "homebrew/Cellar/jq/1.7/bin/jq").path)
        try link(bin.appending(path: "docker"), to: system.applications.appending(path: "Docker.app/Contents/Resources/bin/docker").path)
        try makeFile(bin.appending(path: "composer"), text: "#!/usr/bin/env php\n<?php\n")
        defer { cleanUp() }

        let result = await scanner().scan(.terminalPrograms)
        let byTitle = Dictionary(result.items.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(result.items.map(\.title).sorted() == ["Python 3.12", "composer", "corepack", "docker"],
                "ссылки в Python, npm и Homebrew не дублируются — в том числе относительные и через /private/var")
        #expect(result.items.filter { $0.isRecommended }.map { $0.title } == ["docker"])
        #expect(byTitle["docker"]?.details?.contains("ссылка на удалённую программу") == true)
        #expect(byTitle["composer"]?.details?.contains("скрипт php") == true)
        #expect(byTitle["corepack"]?.details?.contains("версия 0.34.0") == true)
    }

    @Test func servicesWithMissingProgramAreMarked() async throws {
        let existing = base.appending(path: "bin/agent")
        try makeFile(existing, bytes: 10)
        try writePlist(["Label": "com.example.alive", "ProgramArguments": [existing.path, "--run"]],
                       to: home.appending(path: "Library/LaunchAgents/com.example.alive.plist"))
        try writePlist(["Label": "com.docker.vmnetd", "Program": base.appending(path: "PrivilegedHelperTools/com.docker.vmnetd").path],
                       to: system.library.appending(path: "LaunchDaemons/com.docker.vmnetd.plist"))
        try writePlist(["Label": "com.example.shell", "ProgramArguments": ["sh", "-c", "true"]],
                       to: system.library.appending(path: "LaunchAgents/com.example.shell.plist"))
        defer { cleanUp() }

        let result = await scanner().scan(.backgroundServices)

        #expect(Set(result.items.map(\.title)) == ["com.example.alive", "com.docker.vmnetd", "com.example.shell"])
        #expect(result.items.filter { $0.isRecommended }.map { $0.title } == ["com.docker.vmnetd"], "команду без пути не считаем удалённой")
        #expect(result.items.filter(\.isDeletable).map(\.title) == ["com.docker.vmnetd"], "удаляются только службы с удалённой программой")
    }

    // MARK: - Версии языков

    /// «Нет файла» — только `ENOENT`: программа в закрытой правами папке — не удалена, ссылка на отключённый диск — не битая.
    @Test func lockedOrUnmountedTargetsAreNotMissing() throws {
        let locked = home.appending(path: "locked", directoryHint: .isDirectory)
        try makeFile(locked.appending(path: "program"), bytes: 10)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            cleanUp()
        }
        try link(home.appending(path: "external"), to: "/Volumes/Unplugged/tool")
        try link(home.appending(path: "gone"), to: "/nonexistent/tool")

        #expect(!TerminalScanner.isMissing(locked.appending(path: "program").path), "нет прав — не значит нет файла")
        #expect(TerminalScanner.isMissing(home.appending(path: "nothing").path))
        #expect(!TerminalScanner.isBrokenLink(home.appending(path: "external")), "диск подключат снова")
        #expect(TerminalScanner.isBrokenLink(home.appending(path: "gone")))
    }

    @Test func languageVersionsKeepActiveOne() async throws {
        for version in ["3.11.4", "3.12.1"] {
            try makeFile(home.appending(path: ".pyenv/versions/\(version)/bin/python"), bytes: 100)
        }
        try writeText("3.12.1\n", to: home.appending(path: ".pyenv/version"))
        for toolchain in ["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin"] {
            try makeFile(home.appending(path: ".rustup/toolchains/\(toolchain)/bin/rustc"), bytes: 100)
        }
        try writeText("default_toolchain = \"stable-aarch64-apple-darwin\"\n", to: home.appending(path: ".rustup/settings.toml"))
        for version in ["v18.17.0", "v20.11.1"] {
            try makeFile(home.appending(path: ".nvm/versions/node/\(version)/bin/node"), bytes: 100)
        }
        try writeText("lts/*\n", to: home.appending(path: ".nvm/alias/default"))
        defer { cleanUp() }

        let result = await scanner().scan(.languageVersions)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(result.items.count == 6)
        #expect(recommended == ["Python 3.11.4", "Rust nightly-aarch64-apple-darwin"], "у nvm с lts/* активная неизвестна — ничего не отмечаем")
        #expect(result.items.allSatisfy { $0.isDeletable }, "версии удаляются папкой; активную не даст удалить Cleaner")
    }

    /// Активная — не только точное имя папки: префикс, ссылка-псевдоним, несколько версий, `system`. Не нашлась
    /// ни одна папка — активная неизвестна, мусором ничего не помечается.
    @Test func languageVersionsResolvePrefixesAliasesAndUnknown() async throws {
        let pyenv = home.appending(path: ".pyenv/versions")
        for version in ["3.12.0", "3.12.1", "3.11.0", "3.10.0"] {
            try makeFile(pyenv.appending(path: "\(version)/bin/python"), bytes: 100)
        }
        // Окружение pyenv-virtualenv: ссылка ведёт внутрь версии 3.11.0.
        try makeFile(pyenv.appending(path: "3.11.0/envs/tools/bin/python"), bytes: 10)
        try link(pyenv.appending(path: "tools"), to: pyenv.appending(path: "3.11.0/envs/tools").path)
        try writeText("3.12 # свежая ветка\ntools\n", to: home.appending(path: ".pyenv/version"))
        for toolchain in ["stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin", "1.75.0-aarch64-apple-darwin"] {
            try makeFile(home.appending(path: ".rustup/toolchains/\(toolchain)/bin/rustc"), bytes: 100)
        }
        try writeText("""
            default_toolchain = "stable"
            profile = "default"

            [overrides]
            "/Users/tester/project" = "nightly-aarch64-apple-darwin"
            """, to: home.appending(path: ".rustup/settings.toml"))
        for version in ["3.2.0", "3.3.0"] {
            try makeFile(home.appending(path: ".rbenv/versions/\(version)/bin/ruby"), bytes: 100)
        }
        try writeText("3.4.0\n", to: home.appending(path: ".rbenv/version"))
        for version in ["18.0.0", "20.0.0"] {
            try makeFile(home.appending(path: ".asdf/installs/nodejs/\(version)/bin/node"), bytes: 100)
        }
        try writeText("nodejs system\n", to: home.appending(path: ".tool-versions"))
        defer { cleanUp() }

        let result = await scanner().scan(.languageVersions)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(recommended == ["Python 3.10.0", "Rust 1.75.0-aarch64-apple-darwin", "nodejs 18.0.0", "nodejs 20.0.0"],
                "3.12 — обе 3.12.x, tools — 3.11.0, stable и override — активны; у rbenv выбрана неустановленная — неизвестно")
        #expect(!result.items.contains { $0.url.lastPathComponent == "tools" }, "ссылка-окружение — не отдельная версия")
        #expect(result.items.filter { $0.title.hasPrefix("Ruby") }.allSatisfy { $0.details?.contains("активная не определена") == true })
        #expect(ToolCatalog.activity(ofVersionAt: pyenv.appending(path: "3.11.0"), home: home) == .active)
        #expect(ToolCatalog.activity(ofVersionAt: home.appending(path: ".rbenv/versions/3.2.0"), home: home) == .unknown)
    }

    /// Конфиги, действующие во всей домашней папке, складываются: активное в любом из них не считается лишним.
    @Test func homeWideVersionFilesAddActiveVersions() async throws {
        let mise = home.appending(path: ".local/share/mise/installs/node")
        for version in ["20.1.0", "22.11.0", "22.12.0", "24.0.0", "18.0.0"] {
            try makeFile(mise.appending(path: "\(version)/bin/node"), bytes: 100)
        }
        try writeText("[tools]\nnode = \"20\"\n", to: home.appending(path: ".config/mise/config.toml"))
        try writeText("[tools]\nnode = \"24.0.0\"\n", to: home.appending(path: ".config/mise/conf.d/work.toml"))
        try writeText("[tools]\nnode = \"22.12.0\"\n", to: home.appending(path: "mise.toml"))
        try writeText("node 22.11.0\n", to: home.appending(path: ".tool-versions"))
        let pyenv = home.appending(path: ".pyenv/versions")
        for version in ["3.12.1", "3.11.4", "3.10.0"] {
            try makeFile(pyenv.appending(path: "\(version)/bin/python"), bytes: 100)
        }
        try writeText("3.12.1\n", to: home.appending(path: ".pyenv/version"))
        try writeText("3.11.4\n", to: home.appending(path: ".python-version"))
        defer { cleanUp() }

        let result = await scanner().scan(.languageVersions)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(recommended == ["node 18.0.0", "Python 3.10.0"])
    }

    @Test func npmBundledWithHomebrewNodeIsSkippedButNodeInstallerIsShown() async throws {
        try makeFile(base.appending(path: "homebrew/bin/brew"), bytes: 0)
        for package in ["npm", "corepack", "typescript"] {
            try makeFile(base.appending(path: "homebrew/lib/node_modules/\(package)/package.json"), text: #"{"version": "1.0.0"}"#)
        }
        try makeFile(system.usrLocal.appending(path: "lib/node_modules/npm/package.json"), text: #"{"name": "npm", "version": "11.5.1"}"#)
        defer { cleanUp() }

        let result = await scanner().scan(.terminalPrograms)
        // <префикс>/lib/node_modules/<пакет> → имя префикса.
        let packages = result.items.map { "\($0.title) @ \($0.url.pathComponents.dropLast(3).last ?? "")" }

        #expect(packages.sorted() == ["npm @ usr-local", "typescript @ homebrew"],
                "npm и corepack из формулы node не показываются; npm от установщика Node.js в /usr/local — показывается")
    }

    @Test func fnmActiveVersionIsFolderAboveInstallation() async throws {
        let fnm = home.appending(path: ".local/share/fnm", directoryHint: .isDirectory)
        for version in ["v18.0.0", "v20.0.0"] {
            try makeFile(fnm.appending(path: "node-versions/\(version)/installation/bin/node"), bytes: 100)
        }
        try FileManager.default.createDirectory(at: fnm.appending(path: "aliases"), withIntermediateDirectories: true)
        try link(fnm.appending(path: "aliases/default"), to: fnm.appending(path: "node-versions/v20.0.0/installation").path)
        defer { cleanUp() }

        let result = await scanner().scan(.languageVersions)

        #expect(result.items.filter { $0.isRecommended }.map { $0.title } == ["Node.js v18.0.0"])
    }

    @Test func workingLinkInSymlinkedCommandFolderIsNotBroken() async throws {
        let dotfiles = home.appending(path: "dotfiles", directoryHint: .isDirectory)
        try makeFile(dotfiles.appending(path: "lib/tool"), text: "#!/bin/sh\n")
        try FileManager.default.createDirectory(at: dotfiles.appending(path: "bin"), withIntermediateDirectories: true)
        try link(dotfiles.appending(path: "bin/tool"), to: "../lib/tool")
        try FileManager.default.createDirectory(at: home.appending(path: ".local"), withIntermediateDirectories: true)
        try link(home.appending(path: ".local/bin"), to: dotfiles.appending(path: "bin").path)
        defer { cleanUp() }

        let result = await scanner().scan(.terminalPrograms)
        let tool = try #require(result.items.first { $0.title == "tool" })

        #expect(!tool.isRecommended, "`..` разбирается от реальной папки, а не от ~/.local/bin")
        #expect(tool.details?.contains("удалённую") == false)
    }

    // MARK: - Новые инструменты

    @Test func bunCacheIsCleanedButGlobalStoreIsNotTouched() async throws {
        let cache = home.appending(path: ".bun/install/cache")
        try makeFile(cache.appending(path: "react@18.3.1@@@1/index.js"), bytes: 4_000)
        try makeFile(cache.appending(path: "links/react@18.3.1/index.js"), bytes: 4_000)
        defer { cleanUp() }

        let result = await scanner().scan(.toolCaches)
        let item = try #require(result.items.first { $0.url.lastPathComponent == "react@18.3.1@@@1" })

        #expect(item.isRecommended)
        #expect(item.details == "Bun")
        #expect(!result.items.contains { $0.url.lastPathComponent == "links" }, "глобальное хранилище — не кэш, проекты ссылаются туда")
    }

    @Test func asdfAndMiseMarkAllButActiveVersion() async throws {
        let asdf = home.appending(path: ".asdf/installs/nodejs")
        try makeFile(asdf.appending(path: "20.1.0/bin/node"), bytes: 100)
        try makeFile(asdf.appending(path: "18.0.0/bin/node"), bytes: 100)
        try makeFile(asdf.appending(path: "16.0.0/bin/node"), bytes: 100)
        try writeText("nodejs 20.1.0 18.0.0  # основная и запасная\n", to: home.appending(path: ".tool-versions"))
        let mise = home.appending(path: ".local/share/mise/installs/python")
        try makeFile(mise.appending(path: "3.12.4/bin/python3"), bytes: 100)
        try makeFile(mise.appending(path: "3.11.9/bin/python3"), bytes: 100)
        try makeFile(mise.appending(path: "3.10.0/bin/python3"), bytes: 100)
        try link(mise.appending(path: "3.12"), to: "3.12.4")
        try link(mise.appending(path: "3.11"), to: "3.11.9")
        try writeText("[settings]\nexperimental = true\n[tools]\npython = [\"3.12\", \"3.11\"]\n", to: home.appending(path: ".config/mise/config.toml"))
        defer { cleanUp() }

        let result = await scanner().scan(.languageVersions)
        let recommended = Set(result.items.filter(\.isRecommended).map(\.title))

        #expect(recommended == ["nodejs 16.0.0", "python 3.10.0"], "активны все версии из списка — основная и запасные")
        #expect(!result.items.contains { $0.url.lastPathComponent == "3.12" }, "ссылка mise — псевдоним версии, а не версия")
        #expect(result.items.allSatisfy { $0.isDeletable && $0.removal == nil }, "версия удаляется папкой, не командой")
    }

    @Test func dockerIsShownOnlyWhenDesktopIsInstalled() async throws {
        let disk = home.appending(path: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        try makeFile(disk, bytes: 50_000)
        defer { cleanUp() }

        let removed = await scanner().scan(.docker)
        #expect(removed.items.isEmpty, "Docker Desktop удалён — диск показывают «Остатки», не Терминал")
        #expect(removed.unavailableReason == nil)

        try makeFile(system.applications.appending(path: "Docker.app/Contents/Info.plist"), bytes: 10)
        try makeExecutable(system.usrLocal.appending(path: "bin/docker"))
        let df = Data("""
        {"Active":"2","Reclaimable":"20kB (71%)","Size":"2.1GB","TotalCount":"5","Type":"Images"}
        {"Active":"2","Reclaimable":"0B (0%)","Size":"12kB","TotalCount":"2","Type":"Containers"}
        {"Active":"1","Reclaimable":"5kB","Size":"9kB","TotalCount":"1","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"8kB","Size":"8kB","TotalCount":"4","Type":"Build Cache"}
        """.utf8)
        let installed = await scanner(commandOutput: df).scan(.docker)
        let item = { (title: String) in installed.items.first { $0.title == title } }

        #expect(Set(installed.items.map(\.title)) == ["Неиспользуемые образы", "Кэш сборки", "Остальное на диске Docker"], "пустые строки не показываются")
        #expect(item("Неиспользуемые образы")?.size == 20_000 && item("Неиспользуемые образы")?.removal == .dockerPrune(.images))
        #expect(item("Кэш сборки")?.removal == .dockerPrune(.buildCache))
        let rest = try #require(item("Остальное на диске Docker"))
        #expect(rest.url == disk && !rest.isDeletable, "тома и всё в работе — только поиск")
        #expect(rest.details?.contains("тома без контейнеров: 5") == true)
        #expect(installed.totalSize == CleanupScanner.allocatedSize(of: disk), "строки вместе — ровно диск, без двойного счёта")
        #expect(installed.items.allSatisfy { !$0.isRecommended }, "сами не отмечаются")

        let stopped = await scanner().scan(.docker)
        #expect(stopped.items.count == 1 && stopped.items.first?.details?.contains("Docker не запущен") == true)
        #expect(stopped.items.first?.isDeletable == false)
    }

    @Test func condaListsEnvironmentsAndPackageCacheWithoutMarking() async throws {
        let base = home.appending(path: "miniforge3")
        try makeFile(base.appending(path: "conda-meta/history"), bytes: 10)
        try makeFile(base.appending(path: "pkgs/numpy-2.0/lib.so"), bytes: 20_000)
        try makeFile(base.appending(path: "envs/ml/bin/python"), bytes: 30_000)
        // conda кладёт пакеты в окружения жёсткими ссылками: общий файл считается один раз — у окружения.
        try FileManager.default.createDirectory(at: base.appending(path: "envs/ml/lib"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: base.appending(path: "pkgs/numpy-2.0/lib.so"), to: base.appending(path: "envs/ml/lib/lib.so"))
        try makeFile(base.appending(path: "pkgs/numpy-2.0/numpy-2.0.conda"), bytes: 6_000)
        try makeFile(system.opt.appending(path: "anaconda3/envs/old/bin/python"), bytes: 10_000)
        defer { cleanUp() }

        let result = await scanner().scan(.conda)

        #expect(Set(result.items.map(\.title)) == ["Кэш пакетов", "Окружение ml", "Окружение old"])
        let cache = try #require(result.items.first { $0.title == "Кэш пакетов" })
        #expect(cache.size == CleanupScanner.allocatedSize(of: base.appending(path: "pkgs/numpy-2.0/numpy-2.0.conda")),
                "в кэше — только то, чего нет в окружениях")
        #expect(result.items.allSatisfy { !$0.isRecommended && !$0.isDeletable }, "без bin/conda удалять нечем — только поиск")
    }

    /// Удаляет conda своей базы; `~/.conda/pkgs` чистит `conda clean` любой базы — при двух базах отметка
    /// не сказала бы правду, поэтому только поиск.
    @Test func condaRemovalUsesOwnCondaAndSkipsSharedCacheOfSeveralBases() async throws {
        for name in ["miniforge3", "miniconda3"] {
            try makeFile(home.appending(path: "\(name)/conda-meta/history"), bytes: 10)
            try makeExecutable(home.appending(path: "\(name)/bin/conda"))
        }
        try makeFile(home.appending(path: "miniforge3/envs/ml/conda-meta/history"), bytes: 100)
        try makeFile(home.appending(path: "miniforge3/pkgs/numpy-2.0.conda"), bytes: 100)
        try makeFile(home.appending(path: ".conda/pkgs/scipy-1.0.conda"), bytes: 100)
        defer { cleanUp() }

        let result = await scanner().scan(.conda)
        let item = { (path: String) in result.items.first { $0.url.path.hasSuffix(path) } }
        let conda = home.appending(path: "miniforge3/bin/conda").path

        let environment = try #require(item("miniforge3/envs/ml"))
        #expect(environment.removal == .condaRemoveEnvironment(conda: conda, prefix: environment.url.path), "окружение — путём самого элемента")
        #expect(item("miniforge3/pkgs")?.removal == .condaClean(conda: conda))
        #expect(item(".conda/pkgs")?.isDeletable == false)
    }

    @Test func macPortsShowsWhatPortReclaimRemoves() async throws {
        let prefix = system.macPortsPrefix
        try makeExecutable(prefix.appending(path: "bin/port"))
        try makeFile(prefix.appending(path: "var/macports/software/libfoo/libfoo-1.0_0.darwin_25.arm64.tbz2"), bytes: 8_000)
        try makeFile(prefix.appending(path: "var/macports/software/libfoo/libfoo-1.1_0.darwin_25.arm64.tbz2"), bytes: 8_000)
        try makeFile(prefix.appending(path: "var/macports/software/libbaz/libbaz-2.0_1.darwin_25.arm64.tbz2"), bytes: 4_000)
        try makeFile(prefix.appending(path: "var/macports/software/libbaz/libbaz-2.0_10.darwin_25.arm64.tbz2"), bytes: 4_000)
        try makeFile(prefix.appending(path: "var/macports/build/libbar/work/x.o"), bytes: 4_000)
        try makeFile(prefix.appending(path: "var/macports/distfiles/libfoo/libfoo-1.1.tar.gz"), bytes: 4_000)
        defer { cleanUp() }

        let output = Data("The following ports are currently installed:\n  libfoo @1.0_0\n  libbaz @2.0_1\n".utf8)
        let result = await scanner(commandOutput: output).scan(.macPorts)
        let inactive = try #require(result.items.first { $0.title == "libfoo @1.0_0" })

        #expect(inactive.isRecommended)
        #expect(inactive.url.lastPathComponent.hasPrefix("libfoo-1.0_0"), "архив именно неактивной версии")
        let baz = try #require(result.items.first { $0.title == "libbaz @2.0_1" })
        #expect(baz.url.lastPathComponent == "libbaz-2.0_1.darwin_25.arm64.tbz2", "2.0_1 — не 2.0_10")
        #expect(baz.size == CleanupScanner.allocatedSize(of: baz.url))
        #expect(result.items.first { $0.title == "Папки сборки" }?.isRecommended == true)
        #expect(result.items.first { $0.title == "Скачанные исходники" }?.isRecommended == false)
        #expect(inactive.removal == .portUninstall(name: "libfoo", version: "1.0_0"))
        #expect(Set(result.items.filter(\.isDeletable).map(\.title)) == ["libfoo @1.0_0", "libbaz @2.0_1"],
                "удаляются только неактивные версии; сборку и исходники чистит port reclaim — вручную")
    }

    @Test func ollamaCountsSharedLayersOnceInBothManifestLayouts() async throws {
        let models = home.appending(path: ".ollama/models")
        try makeFile(models.appending(path: "blobs/sha256-aaa"), bytes: 40_000)
        try makeFile(models.appending(path: "blobs/sha256-bbb"), bytes: 4_000)
        try makeFile(models.appending(path: "blobs/sha256-ccc"), bytes: 8_000)
        try writeText(#"{"config":{"digest":"sha256:bbb"},"layers":[{"digest":"sha256:aaa"}]}"#,
                      to: models.appending(path: "manifests/registry.ollama.ai/library/llama3/latest"))
        try writeText(#"{"config":{"digest":"sha256:ccc"},"layers":[{"digest":"sha256:aaa"}]}"#,
                      to: models.appending(path: "blobs/sha256-manifest"))
        try FileManager.default.createDirectory(at: models.appending(path: "manifests-v2/ollama.com/library/llama3"), withIntermediateDirectories: true)
        try link(models.appending(path: "manifests-v2/ollama.com/library/llama3/8b"), to: "../../../../blobs/sha256-manifest")
        // Битая ссылка v2 — берётся старый манифест той же модели.
        try writeText(#"{"config":{"digest":"sha256:bbb"},"layers":[{"digest":"sha256:aaa"}]}"#,
                      to: models.appending(path: "manifests/hf.co/user/tiny/q4"))
        try FileManager.default.createDirectory(at: models.appending(path: "manifests-v2/hf.co/user/tiny"), withIntermediateDirectories: true)
        try link(models.appending(path: "manifests-v2/hf.co/user/tiny/q4"), to: "../../../../blobs/sha256-missing")
        defer { cleanUp() }

        let result = await scanner().scan(.ollama)
        let blobs = ["aaa", "bbb", "ccc"].reduce(Int64(0)) { $0 + CleanupScanner.allocatedSize(of: models.appending(path: "blobs/sha256-\($1)")) }

        #expect(Set(result.items.map(\.title)) == ["llama3:latest", "llama3:8b", "hf.co/user/tiny:q4"], "чужой реестр — с хостом, как в ollama list")
        #expect(result.totalSize == blobs, "общий слой считается один раз")
        #expect(result.items.allSatisfy { !$0.isRecommended && $0.removal == .ollamaDelete(model: $0.title) }, "удаляет Ollama по имени из ollama list")
    }

    @Test func missingToolsLeaveSectionsEmptyWithoutReason() async throws {
        defer { cleanUp() }
        let scanner = scanner()

        for category in [CleanupCategory.docker, .conda, .macPorts, .ollama, .homebrew, .androidSDK, .languageVersions] {
            let result = await scanner.scan(category)
            #expect(result.items.isEmpty && result.unavailableReason == nil, "\(category) без инструмента — пусто и без причины, раздел скрывается")
        }
    }

    // MARK: - Helpers

    private func scanner(commandOutput: Data) -> CleanupScanner {
        CleanupScanner(home: home, system: system, commandRunner: CommandRunner { _, _ in commandOutput })
    }

    private func makeExecutable(_ url: URL) throws {
        try makeFile(url, bytes: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func scanner(brew: Data? = nil) -> CleanupScanner {
        let runner = CommandRunner { _, _ in
            guard let brew else { throw CommandRunner.Failure.exitStatus(1) }
            return brew
        }
        return CleanupScanner(home: home, system: system, commandRunner: runner)
    }

    private func makeFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func makeFile(_ url: URL, text: String) throws {
        try writeText(text, to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func link(_ url: URL, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}
