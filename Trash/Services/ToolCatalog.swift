import Foundation

/// Инструменты командной строки в одном месте: кэши менеджеров пакетов и менеджеры версий языков.
/// Новый кэш или менеджер версий — одна запись здесь; инструменты со своими правилами — Homebrew, Android, Gradle,
/// Docker, conda, MacPorts, Ollama — живут в `TerminalScanner`.
enum ToolCatalog {
    /// Кэш менеджера пакетов — корень раздела «Кэши менеджеров пакетов». Путь — от домашней папки.
    struct Cache: Sendable {
        let tool: String
        let path: String
        /// Не только кэш: элементы показываются, но сами не отмечаются — решение пользователя 2026-10-12.
        var warning: String? = nil
        /// Папки внутри кэша, которые кэшем не являются: не показываются и не удаляются.
        var keeps: Set<String> = []

        /// Имя папки-корня — по нему сканер узнаёт, чей это кэш.
        var rootName: String { (path as NSString).lastPathComponent }
    }

    static let caches: [Cache] = [
        Cache(tool: "Homebrew", path: "Library/Caches/Homebrew"),
        Cache(tool: "npm", path: ".npm/_cacache"),
        Cache(tool: "Yarn", path: "Library/Caches/Yarn"),
        Cache(tool: "pnpm", path: "Library/pnpm/store"),
        Cache(tool: "pip", path: "Library/Caches/pip"),
        Cache(tool: "Poetry", path: "Library/Caches/pypoetry"),
        Cache(tool: "Go", path: "Library/Caches/go-build"),
        Cache(tool: "Cargo", path: ".cargo/registry"),
        Cache(tool: "Maven", path: ".m2/repository",
              warning: "может содержать ваши сборки из mvn install — их не скачать заново"),
        Cache(tool: "Flutter и Dart (pub)", path: ".pub-cache/hosted",
              warning: "нужен глобальным утилитам Dart из pub global activate"),
        Cache(tool: "Flutter и Dart (pub)", path: ".pub-cache/git",
              warning: "нужен глобальным утилитам Dart из pub global activate"),
        Cache(tool: "~/.cache", path: ".cache",
              warning: "общая папка программ: внутри бывают токены входа и скачанные модели"),
        // Кэш установки Bun: пакеты `имя@версия`. `links` — глобальное хранилище при `install.globalStore`:
        // `node_modules` проектов ссылаются туда, без него проекты сломаются до `bun install`.
        Cache(tool: "Bun", path: ".bun/install/cache", keeps: ["links"]),
    ]

    /// Активна ли версия языка в папке `url` — по тем же правилам, что и отметка при скане.
    enum VersionActivity: Equatable {
        case active
        case inactive
        /// Активную не определить или папка — не версия известного менеджера.
        case unknown
    }

    static func activity(ofVersionAt url: URL, home: URL) -> VersionActivity {
        let folder = url.deletingLastPathComponent().canonicalFileURL.path
        for manager in versionManagers {
            for versions in manager.versionFolders(home) where versions.canonicalFileURL.path == folder {
                guard let active = manager.activeVersions(home: home, in: versions) else { return .unknown }
                return active.contains(url.lastPathComponent) ? .active : .inactive
            }
        }
        return .unknown
    }

    /// Папки внутри кэшей, которые не удаляются никогда, — для `SafetyGuard`.
    static func keptFolders(home: URL) -> [URL] {
        caches.flatMap { cache in cache.keeps.map { home.appending(path: cache.path).appending(path: $0) } }
    }

    /// Кэш по имени папки-корня, в которой найден элемент.
    static func cache(forRootNamed name: String) -> Cache? {
        caches.first { $0.rootName == name }
    }

    static let versionManagers: [VersionManager] = [
        VersionManager(name: "nvm", versionFolders: { [$0.appending(path: ".nvm/versions/node")] }, language: { _ in "Node.js" }) { home, versions in
            // `alias/default` — `18`, `v18.17.0` или `lts/*`; последнее без сети не разрешить.
            guard let alias = firstLine(home.appending(path: ".nvm/alias/default")) else { return nil }
            let names = folderNames(versions)
            return names.first { $0 == alias || $0 == "v\(alias)" }
                ?? names.filter { $0.hasPrefix("v\(alias).") }.max { (VersionPolicy.version(in: $0) ?? []).lexicographicallyPrecedes(VersionPolicy.version(in: $1) ?? []) }
        },
        VersionManager(
            name: "fnm",
            versionFolders: { home in
                [".local/share/fnm/node-versions", "Library/Application Support/fnm/node-versions"].map { home.appending(path: $0) }
            },
            language: { _ in "Node.js" }
        ) { _, versions in
            // `aliases/default` → `node-versions/<версия>/installation`: версия — папка над `installation`.
            let alias = versions.deletingLastPathComponent().appending(path: "aliases/default")
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path) else { return nil }
            let target = URL(filePath: destination)
            return target.lastPathComponent == "installation" ? target.deletingLastPathComponent().lastPathComponent : target.lastPathComponent
        },
        VersionManager(name: "Volta", versionFolders: { [$0.appending(path: ".volta/tools/image/node")] }, language: { _ in "Node.js" }) { home, _ in
            let platform = home.appending(path: ".volta/tools/user/platform.json")
            let json = (try? Data(contentsOf: platform)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (json?["node"] as? [String: Any])?["runtime"] as? String
        },
        VersionManager(
            name: "pyenv",
            versionFolders: { [$0.appending(path: ".pyenv/versions")] },
            language: { _ in "Python" },
            activeVersions: { home, _ in
                // `pyenv global 3.12 3.11` пишет несколько версий — активны все. `~/.python-version` действует
                // во всей домашней папке: pyenv ищет его от текущей папки вверх.
                let listed = [".pyenv/version", ".python-version"].flatMap { versionFileWords(home.appending(path: $0)) }
                return listed.isEmpty ? nil : Set(listed)
            }
        ),
        VersionManager(
            name: "rbenv",
            versionFolders: { [$0.appending(path: ".rbenv/versions")] },
            language: { _ in "Ruby" },
            activeVersions: { home, _ in
                // Глобальная версия и `~/.ruby-version`: он, как и у pyenv, действует во всей домашней папке.
                let listed = [".rbenv/version", ".ruby-version"].compactMap { firstLine(home.appending(path: $0)) }
                return listed.isEmpty ? nil : Set(listed)
            }
        ),
        VersionManager(
            name: "rustup",
            versionFolders: { [$0.appending(path: ".rustup/toolchains")] },
            language: { _ in "Rust" },
            activeVersions: { home, _ in
                // Тулчейн по умолчанию и тулчейны папок из `rustup override set`: ключ-путь папки — в кавычках.
                let settings = (try? String(contentsOf: home.appending(path: ".rustup/settings.toml"), encoding: .utf8)) ?? ""
                var defaultToolchain: String?
                var overrides: [String] = []
                for rawLine in settings.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    if key == "default_toolchain" {
                        defaultToolchain = value
                    } else if key.hasPrefix("\"") {
                        overrides.append(value)
                    }
                }
                guard let defaultToolchain else { return nil }
                return Set([defaultToolchain] + overrides)
            }
        ),
        VersionManager(
            name: "SDKMAN",
            versionFolders: { subfolders(of: $0.appending(path: ".sdkman/candidates")) },
            language: { $0.lastPathComponent }
        ) { _, versions in
            symlinkTargetName(versions.appending(path: "current"))
        },
        VersionManager(
            name: "asdf",
            versionFolders: { subfolders(of: $0.appending(path: ".asdf/installs")) },
            language: { $0.lastPathComponent },
            activeVersions: { home, versions in
                // `~/.tool-versions`: первая версия основная, остальные — запасные, активны все. `ref:x` лежит в папке `ref-x`.
                let listed = toolVersions(versions.lastPathComponent, in: home.appending(path: ".tool-versions"))
                    .map { $0.hasPrefix("ref:") ? "ref-" + $0.dropFirst(4) : $0 }
                return listed.isEmpty ? nil : Set(listed)
            }
        ),
        VersionManager(
            name: "mise",
            versionFolders: { subfolders(of: $0.appending(path: ".local/share/mise/installs")) },
            language: { $0.lastPathComponent },
            activeVersions: { home, versions in
                // Конфиги mise складываются по иерархии папок, поэтому активны версии из всех, что действуют во всей
                // домашней папке: так нужная версия не сойдёт за лишнюю из-за того, что её перекрыл другой конфиг.
                let tool = versions.lastPathComponent
                let requested = miseConfigFiles(home: home).flatMap { miseToolVersions(tool, in: $0) }
                    + toolVersions(tool, in: home.appending(path: ".tool-versions"))
                return requested.isEmpty ? nil : Set(requested)
            }
        ),
    ]

    private static func firstLine(_ url: URL) -> String? {
        let text = try? String(contentsOf: url, encoding: .utf8)
        return text?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Слова файла версий: версии через пробел или с новой строки, `#` — комментарий.
    private static func versionFileWords(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").flatMap { line in
            (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }

    /// Конфиги mise, действующие во всей домашней папке: глобальный с `config.local.toml` и фрагментами `conf.d`,
    /// а также конфиги самой домашней папки. Несуществующие пропускаются при чтении.
    private static func miseConfigFiles(home: URL) -> [URL] {
        let global = home.appending(path: ".config/mise")
        let fragments = subfolders(of: global.appending(path: "conf.d")).flatMap { entry in
            entry.pathExtension == "toml" ? [entry] : ["mise.toml", "mise.local.toml"].map { entry.appending(path: $0) }
        }
        return ["config.toml", "config.local.toml"].map { global.appending(path: $0) }
            + ["mise.toml", "mise.local.toml", ".mise.toml", ".mise.local.toml", ".config/mise.toml", ".mise/config.toml"].map { home.appending(path: $0) }
            + fragments
    }

    private static func symlinkTargetName(_ url: URL) -> String? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map { URL(filePath: $0).lastPathComponent }
    }

    /// Версии инструмента из файла формата `.tool-versions`: `<инструмент> <версия> [<версия>…]  # комментарий`.
    private static func toolVersions(_ tool: String, in file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        for line in text.split(separator: "\n") {
            let tokens = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .split(whereSeparator: \.isWhitespace) ?? []
            if tokens.count >= 2, tokens[0] == tool {
                return tokens.dropFirst().map(String.init)
            }
        }
        return []
    }

    /// Версии инструмента из секции `[tools]` конфига mise: `node = "22"` или `python = ["3.12", "3.11"]`.
    private static func miseToolVersions(_ tool: String, in file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var isTools = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                isTools = line == "[tools]"
                continue
            }
            guard isTools, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard key == tool else { continue }
            let value = line[line.index(after: equals)...]
            // После разбиения по кавычкам строки внутри кавычек — на нечётных местах.
            let parts = value.split(separator: "\"", omittingEmptySubsequences: false)
            return parts.indices.filter { $0 % 2 == 1 }.map { String(parts[$0]) }
        }
        return []
    }

    private static func subfolders(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private static func folderNames(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)
    }

    /// Папки версий — то, что показывает скан: без скрытых и без ссылок-псевдонимов.
    static func installedVersions(in folder: URL) -> [URL] {
        subfolders(of: folder).filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true }
    }
}

/// Менеджер версий языка: где лежат версии и как узнать активные.
struct VersionManager: Sendable {
    let name: String
    let versionFolders: @Sendable (URL) -> [URL]
    let language: @Sendable (URL) -> String
    /// Версии из настроек менеджера как есть: имя, префикс или псевдоним; `nil` — настроек нет.
    /// У asdf и mise активны и запасные версии из списка.
    let listedVersions: @Sendable (_ home: URL, _ versionsFolder: URL) -> Set<String>?

    init(name: String, versionFolders: @escaping @Sendable (URL) -> [URL], language: @escaping @Sendable (URL) -> String,
         activeVersions: @escaping @Sendable (_ home: URL, _ versionsFolder: URL) -> Set<String>?) {
        self.name = name
        self.versionFolders = versionFolders
        self.language = language
        self.listedVersions = activeVersions
    }

    /// Имена папок активных версий или `nil`, если их не определить. Ссылка-псевдоним (`22` у mise, окружение
    /// pyenv-virtualenv) — папка, в которую она ведёт; префикс (`3.12`, `stable`) — все версии с ним: какую из них
    /// возьмёт менеджер, не гадаем. Запись, не нашедшая ни одной папки, — `nil`: иначе настоящую активную версию
    /// под другим именем приняли бы за неактивную. `system` — версия вне менеджера, папки у неё нет.
    func activeVersions(home: URL, in versionsFolder: URL) -> Set<String>? {
        guard let listed = listedVersions(home, versionsFolder) else { return nil }
        let installed = ToolCatalog.installedVersions(in: versionsFolder).map(\.lastPathComponent)
        let folder = versionsFolder.canonicalFileURL.pathComponents
        var active = Set<String>()
        for entry in listed where entry != "system" {
            guard !entry.isEmpty, !entry.contains("/"), entry != "..", entry != "." else { return nil }
            if installed.contains(entry) {
                active.insert(entry)
                continue
            }
            let link = versionsFolder.appending(path: entry)
            if (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                // Ссылка наружу — версия вне папки менеджера: ни одна из папок версий из-за неё не активна.
                let target = link.resolvingSymlinksInPath().pathComponents
                if target.count > folder.count, target.starts(with: folder) {
                    active.insert(target[folder.count])
                }
                continue
            }
            let matching = installed.filter { $0.hasPrefix(entry + ".") || $0.hasPrefix(entry + "-") }
            guard !matching.isEmpty else { return nil }
            active.formUnion(matching)
        }
        return active
    }

    /// Менеджер с одной активной версией.
    init(name: String, versionFolders: @escaping @Sendable (URL) -> [URL], language: @escaping @Sendable (URL) -> String,
         activeVersion: @escaping @Sendable (_ home: URL, _ versionsFolder: URL) -> String?) {
        self.init(name: name, versionFolders: versionFolders, language: language) { home, versions in
            activeVersion(home, versions).map { [$0] }
        }
    }
}
