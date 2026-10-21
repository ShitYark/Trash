import Foundation

/// Формула Homebrew из `brew info --json=v2 --installed`.
struct HomebrewFormula: Sendable, Equatable {
    struct InstalledVersion: Sendable, Equatable {
        let version: String
        let isOnRequest: Bool
        let isPouredFromBottle: Bool
        let runtimeDependencies: [String]
    }

    let name: String
    let fullName: String
    /// Другие имена формулы — зависимости могут ссылаться на них: `aliases`, `oldnames`.
    let otherNames: [String]
    let summary: String?
    let linkedVersion: String?
    let installed: [InstalledVersion]
    let buildDependencies: [String]
    /// Свежая версия формулы в тапе с ревизией, как папка в `Cellar`: `1.5.7_1`.
    let latestVersion: String?
    let isOutdated: Bool
    let isPinned: Bool

    /// Текущая версия: подключённая (`linked_keg`); у keg-only формул её нет — тогда последняя установленная.
    var currentVersion: String? { linkedVersion ?? installed.last?.version }
    var current: InstalledVersion? { installed.first { $0.version == currentVersion } }
    var isOnRequest: Bool { installed.contains(where: \.isOnRequest) }
    var isBuiltFromSource: Bool { current.map { !$0.isPouredFromBottle } ?? false }

    /// Свежая версия установлена. Нет — `brew cleanup` старые версии формулы не трогает, ждёт обновления.
    var isLatestInstalled: Bool {
        latestVersion.map { latest in installed.contains { $0.version == latest } } ?? !isOutdated
    }

    /// Версия, которую удалил бы `brew cleanup`: не подключённая и старше свежей версии формулы.
    /// Закрепление и `.keepme` проверяет вызывающий — это состояние диска.
    func isCleanable(_ version: String) -> Bool {
        guard isLatestInstalled, version != linkedVersion, let newest = latestVersion ?? currentVersion else { return false }
        return HomebrewCatalog.isOlder(version, than: newest)
    }
}

/// Cask Homebrew.
struct HomebrewCask: Sendable, Equatable {
    let token: String
    let summary: String?
    let version: String?
    let formulaDependencies: [String]
}

/// Разбор JSON `brew info --json=v2 --installed` и правила `brew autoremove` и `brew cleanup`. Ничего не запускает.
enum HomebrewCatalog {
    static let infoArguments = ["info", "--json=v2", "--installed"]

    static func parse(_ data: Data) throws -> (formulae: [HomebrewFormula], casks: [HomebrewCask]) {
        let info = try JSONDecoder().decode(Info.self, from: data)
        let formulae = info.formulae.map { formula in
            HomebrewFormula(
                name: formula.name,
                fullName: formula.full_name ?? formula.name,
                otherNames: (formula.aliases ?? []) + (formula.oldnames ?? []),
                summary: formula.desc,
                linkedVersion: formula.linked_keg,
                installed: formula.installed.map {
                    HomebrewFormula.InstalledVersion(
                        version: $0.version,
                        isOnRequest: $0.installed_on_request ?? false,
                        isPouredFromBottle: $0.poured_from_bottle ?? true,
                        runtimeDependencies: ($0.runtime_dependencies ?? []).map(\.full_name)
                    )
                },
                buildDependencies: formula.build_dependencies ?? [],
                latestVersion: formula.versions?.stable.map { stable in
                    (formula.revision ?? 0) > 0 ? "\(stable)_\(formula.revision ?? 0)" : stable
                },
                isOutdated: formula.outdated ?? false,
                isPinned: formula.pinned ?? false
            )
        }
        let casks = (info.casks ?? []).map {
            HomebrewCask(token: $0.token, summary: $0.desc, version: $0.installed, formulaDependencies: $0.depends_on?.formula ?? [])
        }
        return (formulae, casks)
    }

    /// Полные имена нужных формул — как у `brew autoremove`: поставленные явно, собранные из исходников
    /// вместе с их build-зависимостями, зависимости cask и всё это по цепочке. Остальное больше ничему не нужно.
    static func requiredFormulae(_ formulae: [HomebrewFormula], casks: [HomebrewCask]) -> Set<String> {
        let byName = formulaeByAnyName(formulae)
        let sourceBuilt = formulae.filter(\.isBuiltFromSource)
        var queue = formulae.filter(\.isOnRequest).map(\.fullName) + casks.flatMap(\.formulaDependencies)
            + sourceBuilt.map(\.fullName) + sourceBuilt.flatMap(\.buildDependencies)
        var required = Set<String>()

        while let name = queue.popLast() {
            guard let formula = byName[name], required.insert(formula.fullName).inserted else { continue }
            queue += formula.current?.runtimeDependencies ?? []
        }
        return required
    }

    /// Кто из нужных пакетов держит формулу: `["icu4c": ["node", "php"]]`.
    /// `runtime_dependencies` транзитивны — в списке и косвенные пользователи.
    static func users(_ formulae: [HomebrewFormula], casks: [HomebrewCask], required: Set<String>) -> [String: [String]] {
        let byName = formulaeByAnyName(formulae)
        var users: [String: [String]] = [:]
        for formula in formulae where required.contains(formula.fullName) {
            for dependency in Set(formula.current?.runtimeDependencies ?? []) {
                guard let target = byName[dependency]?.fullName else { continue }
                users[target, default: []].append(formula.name)
            }
        }
        for cask in casks {
            for dependency in Set(cask.formulaDependencies) {
                guard let target = byName[dependency]?.fullName else { continue }
                users[target, default: []].append(cask.token)
            }
        }
        return users.mapValues { $0.sorted() }
    }

    /// Сравнение версий Homebrew по числам: `1.5.7` < `1.5.7_1` < `1.10.0`.
    static func isOlder(_ version: String, than other: String) -> Bool {
        let numbers = { (value: String) in value.matches(of: #/\d+/#).compactMap { Int($0.output) } }
        return numbers(version).lexicographicallyPrecedes(numbers(other))
    }

    private static func formulaeByAnyName(_ formulae: [HomebrewFormula]) -> [String: HomebrewFormula] {
        var byName: [String: HomebrewFormula] = [:]
        for formula in formulae {
            for name in [formula.fullName, formula.name] + formula.otherNames where byName[name] == nil {
                byName[name] = formula
            }
        }
        return byName
    }
}

// Имена полей — как в JSON Homebrew.
private struct Info: Decodable {
    struct Formula: Decodable {
        struct Installed: Decodable {
            struct Dependency: Decodable {
                let full_name: String
            }

            let version: String
            let installed_on_request: Bool?
            let poured_from_bottle: Bool?
            let runtime_dependencies: [Dependency]?
        }

        struct Versions: Decodable {
            let stable: String?
        }

        let name: String
        let full_name: String?
        let aliases: [String]?
        let oldnames: [String]?
        let desc: String?
        let linked_keg: String?
        let installed: [Installed]
        let build_dependencies: [String]?
        let versions: Versions?
        let revision: Int?
        let outdated: Bool?
        let pinned: Bool?
    }

    struct Cask: Decodable {
        struct Dependencies: Decodable {
            let formula: [String]?
        }

        let token: String
        let desc: String?
        let installed: String?
        let depends_on: Dependencies?
    }

    let formulae: [Formula]
    let casks: [Cask]?
}
