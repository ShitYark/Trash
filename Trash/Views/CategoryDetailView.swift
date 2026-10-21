import AppKit
import SwiftUI

struct CategoryDetailView: View {
    let model: CleanupViewModel
    let category: CleanupCategory

    private var result: CategoryScanResult? { model.result(for: category) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                content
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(category.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 32) {
                Text(category.summary)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let result {
                    figure("Найдено", result.totalSize.byteText, color: Theme.text)
                    if category.isDeletable {
                        figure("Отмечено", model.selectedSize(in: category).byteText, color: Theme.accent)
                    }
                }
            }

            if result?.isAccessDenied == true {
                FullDiskAccessBanner()
            }

            if !category.isDeletable {
                SearchOnlyBanner()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            if result.items.isEmpty, let reason = result.unavailableReason {
                ContentUnavailableView("Нет данных", systemImage: "exclamationmark.triangle", description: Text(reason))
            } else if result.items.isEmpty {
                ContentUnavailableView("Здесь чисто", systemImage: "sparkles")
            } else {
                list(result)
            }
        } else if model.phase == .scanning {
            ProgressView("Сканирование…")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView {
                Label("Ещё не сканировали", systemImage: "magnifyingglass")
            } actions: {
                Button("Сканировать") {
                    Task { await model.scan() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func list(_ result: CategoryScanResult) -> some View {
        // Набор отметок читается здесь явно: список зависит от выбора на любой версии macOS,
        // а лишние строки всё равно отсекает `.equatable()`.
        let selection = model.selection
        return VStack(spacing: 0) {
            HStack {
                if category.isDeletable {
                    Toggle(sources: model.selectAllSources(for: category), isOn: \.self) {
                        Text("Выбрать всё (\(result.items.count))")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.checkbox)
                } else {
                    Text("Найдено: \(result.items.count)")
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer()
                Text("по размеру")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Theme.surface)

            LazyVStack(spacing: 0) {
                ForEach(result.items) { item in
                    ItemRow(item: item, isSelected: selection.contains(item.id)) { model.setSelected($0, for: item) }
                        .equatable()
                        .padding(.horizontal, 8)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
        .card(Theme.sunken)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func figure(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.mono(24, weight: .medium))
                .foregroundStyle(color)
        }
        .fixedSize()
    }
}

/// Строка найденного элемента — общая для экрана категории и окна группы.
/// Получает готовые значения и сравнивается по ним (`.equatable()`): щелчок по одной отметке не перерисовывает
/// весь список, а после скана или очистки строка всё равно обновится — сравниваются все поля элемента.
/// Новое поле, от которого зависит `body`, обязано попасть в `==`, иначе строка останется устаревшей.
struct ItemRow: View, Equatable {
    let item: ScanItem
    let isSelected: Bool
    let onToggle: @MainActor @Sendable (Bool) -> Void

    /// Явный мусор, который сам не отмечается — неудаляемый или ждёт вашего решения: подсказываем словами.
    private var showsJunkBadge: Bool { item.isUnmarkedJunk && !isSelected }

    var body: some View {
        HStack(spacing: 12) {
            // Подпись скрыта на экране, но VoiceOver читает, что именно отмечается к удалению.
            Toggle(item.title, isOn: Binding(get: { isSelected }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isDeletable)
                .accessibilityHint(item.isDeletable ? "" : "Приложение это находит, но не удаляет")

            Image(nsImage: FileIcons.icon(for: item.url))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsJunkBadge {
                        Badge(title: "мусор")
                    }
                    // Чекбокс неактивен — словами, почему: серым, чтобы не путать с «мусором».
                    if !item.isDeletable {
                        Badge(title: "только поиск", kind: .neutral)
                            .help("Приложение это находит, но не удаляет")
                    }
                }
                if let details = item.details {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.size.byteText)
                .font(Theme.mono(13))
                .frame(width: 84, alignment: .trailing)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .help("Показать в Finder")
            .accessibilityLabel("Показать в Finder: \(item.title)")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
        .help(item.url.path)
    }

    nonisolated static func == (lhs: ItemRow, rhs: ItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
    }
}

/// Иконки Finder по пути: читаются с диска один раз, дальше — из кэша.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let icon = cache.object(forKey: key) {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

private struct SearchOnlyBanner: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Theme.info)
            Text("Пока только поиск: удаление этой категории появится в следующей версии. Явный мусор помечен.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.infoBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.infoLine, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Theme.info)
            Text("Нет доступа к части папок. Разрешите Trash полный доступ к диску и пересканируйте.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Открыть настройки") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .card(radius: 12)
    }
}
