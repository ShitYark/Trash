import Foundation

/// Найденный файл, папка, симулятор или рантайм.
struct ScanItem: Identifiable, Hashable, Sendable {
    let url: URL
    /// Место на диске в байтах (с учётом всех вложенных файлов).
    let size: Int64
    let category: CleanupCategory
    /// Имя для списка: проект, версия системы, имя симулятора — или имя файла.
    let title: String
    /// Подпись под именем: путь проекта, версия, дата последнего использования.
    let details: String?
    /// Явный мусор. В разделах с `autoSelectsRecommended` отмечается для удаления сразу после сканирования.
    let isRecommended: Bool
    /// Удаление через менеджер вместо файлов — `nil`, если элемент удаляется файлами или не удаляется вовсе.
    let removal: ManagerRemoval?
    /// Только поиск внутри удаляемого раздела: инструмент, а не мусор, — например эмулятор Android или platform-tools.
    let isSearchOnly: Bool

    var id: URL { url }

    /// Можно ли выбрать элемент. В разделах `isManagerOnly` — только с операцией менеджера:
    /// встроенный рантайм или явно поставленный пакет Homebrew удалить нельзя.
    var isDeletable: Bool {
        category.isDeletable && !isSearchOnly && (removal != nil || !category.isManagerOnly)
    }

    /// Явный мусор, который сам не отмечается: неудаляемый или в разделе, где отмечать решает пользователь.
    var isUnmarkedJunk: Bool {
        isRecommended && !(isDeletable && category.autoSelectsRecommended)
    }

    init(
        url: URL,
        size: Int64,
        category: CleanupCategory,
        title: String? = nil,
        details: String? = nil,
        isRecommended: Bool? = nil,
        removal: ManagerRemoval? = nil,
        isSearchOnly: Bool = false
    ) {
        self.url = url
        self.size = size
        self.category = category
        self.title = title ?? url.lastPathComponent
        self.details = details
        self.isRecommended = isRecommended ?? category.isSelectedByDefault
        self.removal = removal
        self.isSearchOnly = isSearchOnly
    }

    /// Тот же элемент, но только для поиска — в разделе, где удаляется лишь мусор определённого вида.
    func searchOnly() -> ScanItem {
        ScanItem(url: url, size: size, category: category, title: title, details: details, isRecommended: isRecommended,
                 removal: removal, isSearchOnly: true)
    }

    /// Тот же элемент с другой подписью и отметкой — для правил, которым нужны все соседи сразу.
    func with(details: String?, isRecommended: Bool) -> ScanItem {
        ScanItem(url: url, size: size, category: category, title: title, details: details, isRecommended: isRecommended,
                 removal: removal, isSearchOnly: isSearchOnly)
    }
}

/// Результат сканирования одной категории.
struct CategoryScanResult: Sendable {
    let category: CleanupCategory
    var items: [ScanItem]
    /// Хотя бы одна корневая папка недоступна из-за отсутствия прав (обычно нужен Full Disk Access).
    var isAccessDenied: Bool
    /// Почему категорию не удалось просканировать: нет Xcode, `simctl` не ответил. Пустой список с причиной — не «чисто».
    var unavailableReason: String? = nil

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }
}

/// Итог очистки.
struct CleanupReport: Sendable {
    struct Failure: Sendable {
        let url: URL
        /// Имя из списка: у строк Docker путь — диск, а не то, что не удалилось.
        var title: String?
        let reason: String
    }

    var removed: [URL] = []
    /// Куда ушло удалённое — для итога в отчёте: режим очистки этого не говорит, у программ, Корзины
    /// и менеджеров путь свой.
    var movedToTrash = 0
    var deletedPermanently = 0
    /// Удалили менеджеры — сразу и без Корзины.
    var removedByManagers = 0
    var freedBytes: Int64 = 0
    var failures: [Failure] = []
}
