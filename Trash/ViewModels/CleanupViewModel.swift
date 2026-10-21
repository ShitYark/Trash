import Foundation
import Observation

/// Пункт боковой панели: обзор, категория группы «Система» или целая группа — Программы, Xcode, Терминал — одним пунктом.
enum SidebarItem: Hashable, Identifiable {
    case overview
    case category(CleanupCategory)
    case group(CategoryGroup)

    /// Группы боковой панели в порядке показа; категории «Системы» идут отдельными пунктами.
    static let groups = CategoryGroup.allCases.filter { $0 != .system }

    var id: String {
        switch self {
        case .overview: "overview"
        case let .category(category): category.id
        case let .group(group): "group-\(group.id)"
        }
    }

    /// Разделы, которые видны на экране пункта: «Обзор» — все, категория — она сама, группа — её разделы.
    var categories: [CleanupCategory] {
        switch self {
        case .overview: CleanupCategory.allCases
        case let .category(category): [category]
        case let .group(group): group.categories
        }
    }
}

@MainActor
@Observable
final class CleanupViewModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case cleaning
    }

    private(set) var phase: Phase = .idle
    private(set) var results: [CleanupCategory: CategoryScanResult] = [:]
    private(set) var lastReport: CleanupReport?
    /// Том с домашней папкой; обновляется при скане и после очистки.
    private(set) var disk: DiskSpace?
    var selectedItem: SidebarItem? = .overview
    /// Отмеченные для удаления элементы (по `ScanItem.id`).
    var selection: Set<URL> = []
    /// Очистка закончилась — окно очистки показывает отчёт, а не подтверждение.
    var isReportPresented = false

    private let scanner: CleanupScanner
    private let cleaner: Cleaner
    private let diskSpace: @Sendable () async -> DiskSpace?

    var allItems: [ScanItem] {
        results.values.flatMap(\.items)
    }

    /// Всё отмеченное во всех разделах.
    var selectedItems: [ScanItem] {
        selectedItems(in: CleanupCategory.allCases)
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    /// Экран, к которому относятся «Отмечено к удалению» и «Очистить»; без выбора — «Обзор».
    var cleanupScope: SidebarItem {
        selectedItem ?? .overview
    }

    /// Что удалит «Очистить» на текущем экране: отмеченное только в его разделах.
    /// Отметки других разделов сохраняются, но здесь не учитываются и не удаляются.
    var cleanupItems: [ScanItem] {
        selectedItems(in: cleanupScope.categories)
    }

    var cleanupSize: Int64 {
        cleanupItems.reduce(0) { $0 + $1.size }
    }

    /// Всё найденное без дублей — копия Xcode из двух разделов считается один раз.
    var foundSize: Int64 {
        uniqueItems.reduce(0) { $0 + $1.size }
    }

    /// Явный мусор, который не отмечен: неудаляемый или из разделов, где отмечать решает пользователь, —
    /// рантаймы, симуляторы, Homebrew, версии языков.
    var unmarkedJunkSize: Int64 {
        uniqueItems.filter { $0.isUnmarkedJunk && !selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    private var uniqueItems: [ScanItem] {
        var seen = Set<URL>()
        return allItems.filter { seen.insert($0.id).inserted }
    }

    convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let system = SystemLocations()
        let cleaner = Cleaner(
            safetyGuard: SafetyGuard(home: home, system: system),
            catalog: { ApplicationCatalog.scan(system: system, home: home, environment: .live) }
        )
        self.init(
            scanner: CleanupScanner(home: home, system: system),
            cleaner: cleaner,
            diskSpace: { await DiskSpace.current(for: home) }
        )
    }

    init(scanner: CleanupScanner, cleaner: Cleaner, diskSpace: @escaping @Sendable () async -> DiskSpace? = { nil }) {
        self.scanner = scanner
        self.cleaner = cleaner
        self.diskSpace = diskSpace
    }

    func result(for category: CleanupCategory) -> CategoryScanResult? {
        results[category]
    }

    func totalSize(of group: CategoryGroup) -> Int64 {
        group.categories.reduce(0) { $0 + (results[$1]?.totalSize ?? 0) }
    }

    /// Отмечено к удалению в группе — только удаляемые элементы, неудаляемые выбрать нельзя.
    /// Копия Xcode, отмеченная один раз, видна и в «Программах», и в «Xcode»; внутри группы — без дублей.
    func selectedSize(in group: CategoryGroup) -> Int64 {
        selectedItems(in: group.categories).reduce(0) { $0 + $1.size }
    }

    /// Отмечено к удалению в разделе.
    func selectedSize(in category: CleanupCategory) -> Int64 {
        deletableItems(in: category).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// Элементы раздела, которые можно выбрать.
    func deletableItems(in category: CleanupCategory) -> [ScanItem] {
        (results[category]?.items ?? []).filter(\.isDeletable)
    }

    /// Все категории группы просканированы.
    func isScanned(_ group: CategoryGroup) -> Bool {
        group.categories.allSatisfy { results[$0] != nil }
    }

    /// Разделы группы на экране. Где `hidesEmptySections`, пустой раздел без причины и без отказа в доступе скрыт:
    /// инструмента нет или он ничего не оставил. «Нет данных» и замок остаются видны. Пока идёт скан, видно всё.
    func visibleCategories(in group: CategoryGroup) -> [CleanupCategory] {
        guard group.hidesEmptySections, phase != .scanning else { return group.categories }
        return group.categories.filter { category in
            guard let result = results[category] else { return true }
            return !result.items.isEmpty || result.unavailableReason != nil || result.isAccessDenied
        }
    }

    /// Явный мусор группы, который не отмечен.
    func unmarkedJunkSize(in group: CategoryGroup) -> Int64 {
        group.categories
            .flatMap { results[$0]?.items ?? [] }
            .filter { $0.isUnmarkedJunk && !selection.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    // MARK: - Выбор

    func isSelected(_ item: ScanItem) -> Bool {
        selection.contains(item.id)
    }

    /// Неудаляемые элементы выбрать нельзя. Элементы, которые удаляет одна команда менеджера, — например все старые
    /// версии формулы для `brew cleanup`, — отмечаются вместе: что видно отмеченным, то и удалится.
    func setSelected(_ isSelected: Bool, for item: ScanItem) {
        let linked = if let removal = item.removal, removal.isGrouped {
            allItems.filter { $0.removal == removal }
        } else {
            [item]
        }
        for linkedItem in linked {
            if isSelected, linkedItem.isDeletable {
                selection.insert(linkedItem.id)
            } else {
                selection.remove(linkedItem.id)
            }
        }
    }

    // MARK: - Действия

    func scan() async {
        guard phase == .idle else { return }
        phase = .scanning
        results = [:]
        selection = []
        disk = await diskSpace()

        let scanner = scanner
        await withTaskGroup(of: CategoryScanResult.self) { group in
            for category in CleanupCategory.allCases {
                group.addTask { await scanner.scan(category) }
            }
            for await result in group {
                results[result.category] = result
                // Явный мусор отмечается сам только там, где это обратимо и решать не пользователю.
                selection.formUnion(result.items.filter { $0.isRecommended && $0.isDeletable && $0.category.autoSelectsRecommended }.map(\.id))
            }
        }

        phase = .idle
    }

    /// Удаляет отмеченное на текущем экране — `cleanupItems`.
    func cleanSelected(permanently: Bool) async {
        let items = cleanupItems
        guard phase == .idle, !items.isEmpty else { return }
        phase = .cleaning

        let report = await cleaner.clean(items, permanently: permanently)
        let removed = Set(report.removed)
        results = results.mapValues { result in
            var result = result
            result.items.removeAll { removed.contains($0.url) }
            return result
        }
        selection.subtract(removed)
        disk = await diskSpace()

        lastReport = report
        isReportPresented = true
        phase = .idle
    }

    // MARK: - Помощники

    /// Отмеченное в разделах без дублей: одна и та же программа бывает в двух разделах —
    /// «Установленные программы» и «Старые версии Xcode», — а в `Cleaner` она должна уйти один раз.
    private func selectedItems(in categories: [CleanupCategory]) -> [ScanItem] {
        var seen = Set<URL>()
        return categories
            .flatMap { results[$0]?.items ?? [] }
            .filter { selection.contains($0.id) && seen.insert($0.id).inserted }
    }
}
