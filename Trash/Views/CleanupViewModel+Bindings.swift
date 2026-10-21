import SwiftUI

/// Биндинги чекбоксов поверх методов выбора view model — общие для экрана категории и окна Xcode.
extension CleanupViewModel {
    func selectionBinding(for item: ScanItem) -> Binding<Bool> {
        Binding {
            self.isSelected(item)
        } set: { isSelected in
            self.setSelected(isSelected, for: item)
        }
    }

    /// Источники для `Toggle(sources:)` «выбрать всё»: только удаляемые элементы.
    /// Частичный выбор такой чекбокс показывает смешанным, а не пустым.
    func selectAllSources(for category: CleanupCategory) -> [Binding<Bool>] {
        deletableItems(in: category).map(selectionBinding)
    }
}
