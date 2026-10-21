import AppKit
import Security

/// Подпись кода программы: Team ID разработчика и группы данных из entitlements.
struct CodeSignature: Sendable, Equatable {
    var team: String?
    /// `com.apple.security.application-groups`: `group.is.workflow.my.app`, `UBF8T346G9.com.microsoft.oneauth`.
    var applicationGroups: [String] = []
}

/// Откуда берутся сведения о программах: Launch Services, подпись кода, запущенные процессы.
/// В тестах подменяется, чтобы результат не зависел от программ на машине.
struct ApplicationEnvironment: Sendable {
    /// Путь программы по идентификатору, если Launch Services её знает — даже если файла уже нет.
    var lookup: @Sendable (String) -> URL?
    var signature: @Sendable (URL) -> CodeSignature
    /// Запущена именно эта копия: у двух копий Xcode один идентификатор, поэтому сравнивается путь.
    var isRunning: @Sendable (URL) -> Bool

    static let live = ApplicationEnvironment(
        lookup: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        signature: { url in
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return CodeSignature() }
            var information: CFDictionary?
            // Entitlements приходят только с флагом требований.
            let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
            guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
                  let values = information as? [String: Any] else { return CodeSignature() }
            let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            return CodeSignature(
                team: values[kSecCodeInfoTeamIdentifier as String] as? String,
                applicationGroups: entitlements?["com.apple.security.application-groups"] as? [String] ?? []
            )
        },
        isRunning: { url in
            let path = url.resolvingSymlinksInPath().path
            return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath().path == path }
        }
    )
}

/// Установленная программа.
struct InstalledApplication: Sendable, Equatable {
    let url: URL
    let bundleIdentifier: String?
    /// Идентификаторы самой программы и её вложенных частей: расширений, помощников, служб входа.
    let identifiers: [String]
    let name: String
    let version: String?
    let signature: CodeSignature
    let isFromAppStore: Bool
    let isOwnedByRoot: Bool
    /// Часть macOS — настоящий путь в `/System`. Не показывается и не удаляется, но её данные — не остатки.
    let isSystem: Bool
}

/// Программы — пользовательские и системные — и правило «программа установлена»:
/// по нему решается, чьи данные остались без программы.
struct ApplicationCatalog: Sendable {
    let applications: [InstalledApplication]
    let environment: ApplicationEnvironment

    private var installedIdentifiers: [String] {
        applications.flatMap(\.identifiers)
    }

    /// Папки программ пользователя: `/Applications` с подпапками на один уровень и `~/Applications`.
    static func folders(system: SystemLocations, home: URL) -> [URL] {
        [system.applications, home.appending(path: "Applications", directoryHint: .isDirectory)]
    }

    static func scan(system: SystemLocations, home: URL, environment: ApplicationEnvironment) -> ApplicationCatalog {
        var bundles: [URL] = []
        for folder in folders(system: system, home: home) + system.systemApplications {
            for entry in contents(of: folder) {
                if entry.pathExtension == "app" {
                    bundles.append(entry)
                } else if isDirectory(entry) {
                    bundles += contents(of: entry).filter { $0.pathExtension == "app" }
                }
            }
        }
        return ApplicationCatalog(applications: bundles.map { application(at: $0, environment: environment) }, environment: environment)
    }

    /// Программа установлена: Launch Services знает её и файл на месте; или идентификатор её или вложенной части —
    /// префикс кандидата и наоборот (расширения и помощники живут под идентификатором программы).
    func isInstalled(_ identifier: String) -> Bool {
        if let url = environment.lookup(identifier), FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return installedIdentifiers.contains { identifier == $0 || identifier.hasPrefix($0 + ".") || $0.hasPrefix(identifier + ".") }
    }

    /// Launch Services помнит программу, хотя файла нет: внешний диск, своя сборка разработчика, игра лаунчера.
    func isKnownToLaunchServices(_ identifier: String) -> Bool {
        environment.lookup(identifier) != nil
    }

    /// У производителя — первые две части идентификатора — есть установленная программа.
    func hasVendorInstalled(_ identifier: String) -> Bool {
        guard let vendor = Self.vendor(of: identifier) else { return false }
        return installedIdentifiers.contains { Self.vendor(of: $0) == vendor }
    }

    func hasTeamInstalled(_ team: String) -> Bool {
        applications.contains { $0.signature.team == team }
    }

    /// Группа данных объявлена в подписи установленной или системной программы.
    func declaresGroup(_ name: String) -> Bool {
        applications.contains { $0.signature.applicationGroups.contains(name) }
    }

    /// `com.microsoft.rdc.macos` → `com.microsoft`.
    static func vendor(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        return parts.count >= 2 ? parts.prefix(2).joined(separator: ".") : nil
    }

    private static func application(at url: URL, environment: ApplicationEnvironment) -> InstalledApplication {
        // iOS-программа на Apple Silicon — обёртка: Info.plist и подпись лежат в `WrappedBundle`.
        let wrapped = url.appending(path: "WrappedBundle").resolvingSymlinksInPath()
        let isWrapped = !FileManager.default.fileExists(atPath: url.appending(path: "Contents/Info.plist").path)
            && FileManager.default.fileExists(atPath: wrapped.appending(path: "Info.plist").path)
        let code = isWrapped ? wrapped : url
        let info = propertyList(at: isWrapped ? wrapped.appending(path: "Info.plist") : url.appending(path: "Contents/Info.plist"))
        let bundleIdentifier = info?["CFBundleIdentifier"] as? String
        let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountName] as? String

        return InstalledApplication(
            url: url,
            bundleIdentifier: bundleIdentifier,
            identifiers: [bundleIdentifier].compactMap { $0 } + (isWrapped ? [] : nestedIdentifiers(in: url)),
            // Имя файла, как в Finder: у копий Xcode имя в Info.plist одинаковое, а файлы — «Xcode» и «Xcode beta1».
            name: url.deletingPathExtension().lastPathComponent,
            version: info?["CFBundleShortVersionString"] as? String,
            signature: environment.signature(code),
            isFromAppStore: FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path),
            isOwnedByRoot: owner == "root",
            isSystem: url.resolvingSymlinksInPath().path.hasPrefix("/System/")
        )
    }

    /// Расширения, помощники, службы входа и XPC внутри программы — у них свои идентификаторы и свои данные.
    private static func nestedIdentifiers(in application: URL) -> [String] {
        let folders = ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/XPCServices", "Contents/Helpers"]
        return folders.flatMap { folder in
            contents(of: application.appending(path: folder)).compactMap { nested in
                propertyList(at: nested.appending(path: "Contents/Info.plist"))?["CFBundleIdentifier"] as? String
            }
        }
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Папка бывает ссылкой — читаем то, на что она ведёт.
    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Остатки удалённых программ: где искать и как по имени понять, чья это программа.
enum LeftoverPolicy {
    enum Kind: CaseIterable, Sendable {
        case container
        case groupContainer
        case applicationSupport
        case preferences
        case savedState
        case httpStorage
        case webKit

        var folder: String {
            switch self {
            case .container: "Library/Containers"
            case .groupContainer: "Library/Group Containers"
            case .applicationSupport: "Library/Application Support"
            case .preferences: "Library/Preferences"
            case .savedState: "Library/Saved Application State"
            case .httpStorage: "Library/HTTPStorages"
            case .webKit: "Library/WebKit"
            }
        }

        var title: String {
            switch self {
            case .container: "данные программы (контейнер)"
            case .groupContainer: "общие данные программ разработчика"
            case .applicationSupport: "данные программы"
            case .preferences: "файл настроек"
            case .savedState: "сохранённые окна"
            case .httpStorage: "cookie и HTTP-хранилище"
            case .webKit: "данные WebKit"
            }
        }
    }

    /// Чья программа: идентификатор, Team ID у Group Container и имя элемента как есть — для сверки с группами из подписи.
    struct Owner: Sendable, Equatable {
        let identifier: String
        let team: String?
        let entryName: String
    }

    enum Status: Equatable {
        case installed
        case orphan(Confidence)
    }

    enum Confidence: Equatable {
        /// У производителя нет ни одной установленной программы — отмечается сам.
        case confident
        case vendorInstalled
        /// Launch Services помнит программу, хотя файла нет.
        case knownToLaunchServices
    }

    /// Признаки системных данных в любом месте имени: Apple, «Быстрые команды» (`is.workflow`), система печати CUPS.
    private static let systemMarkers = ["com.apple.", "is.workflow.", "org.cups.", "systemgroup."]

    static func folders(home: URL) -> [(URL, Kind)] {
        Kind.allCases.map { (home.appending(path: $0.folder, directoryHint: .isDirectory), $0) }
    }

    /// Владелец по имени элемента или `nil`: имя — не идентификатор (`MobileSync`, `Google`), системное или самого Trash.
    static func owner(ofEntryNamed name: String, kind: Kind) -> Owner? {
        let lowercasedName = name.lowercased()
        guard !systemMarkers.contains(where: { lowercasedName.hasPrefix($0) || lowercasedName.contains("." + $0) }) else {
            return nil
        }

        var identifier = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where identifier.hasSuffix(suffix) {
            identifier.removeLast(suffix.count)
        }

        var team: String?
        var hasGroupPrefix = false
        if kind == .groupContainer {
            let parts = identifier.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                team = parts[0]
                identifier = parts[1]
            }
            for prefix in ["group.", "groups."] where identifier.hasPrefix(prefix) {
                identifier.removeFirst(prefix.count)
                hasGroupPrefix = true
            }
        }

        if identifier.lowercased() == Bundle.main.bundleIdentifier?.lowercased() {
            return nil
        }
        // Обычно — три части и больше; после `group.` хватает двух: `group.com.docker` — сам префикс уже говорит, что это группа программ.
        let isIdentifier = hasGroupPrefix
            ? identifier.wholeMatch(of: #/[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+/#) != nil
            : identifier.wholeMatch(of: #/[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+){2,}/#) != nil
        // У Group Container с Team ID судим по разработчику, даже если остаток имени — не идентификатор.
        guard isIdentifier || team != nil else { return nil }
        return Owner(identifier: identifier, team: team, entryName: name)
    }

    static func status(of owner: Owner, in catalog: ApplicationCatalog) -> Status {
        if catalog.declaresGroup(owner.entryName) {
            return .installed
        }
        if let team = owner.team, catalog.hasTeamInstalled(team) {
            return .installed
        }
        if catalog.isInstalled(owner.identifier) {
            return .installed
        }
        if catalog.isKnownToLaunchServices(owner.identifier) {
            return .orphan(.knownToLaunchServices)
        }
        return .orphan(catalog.hasVendorInstalled(owner.identifier) ? .vendorInstalled : .confident)
    }
}
