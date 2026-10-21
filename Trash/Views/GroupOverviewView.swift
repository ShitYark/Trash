import SwiftUI

/// Группа одним экраном — Программы, Xcode или Терминал: сводка и разделы по убыванию размера, каждый раскрывается в список элементов.
struct GroupOverviewView: View {
    let model: CleanupViewModel
    let group: CategoryGroup
    @State private var expandedCategories: Set<CleanupCategory> = []

    /// По убыванию размера. Пока идёт скан — в исходном порядке, чтобы раскрытый раздел не уезжал.
    private var categories: [CleanupCategory] {
        let categories = model.visibleCategories(in: group)
        guard model.phase != .scanning else { return categories }
        return categories.sorted {
            (model.result(for: $0)?.totalSize ?? -1) > (model.result(for: $1)?.totalSize ?? -1)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summary
                LazyVStack(spacing: 10) {
                    ForEach(categories) { category in
                        GroupSection(
                            model: model,
                            category: category,
                            isExpanded: expansionBinding(for: category)
                        )
                    }
                }
                // Все разделы скрыты как пустые — инструментов, которые знает Trash, здесь нет.
                if categories.isEmpty && model.isScanned(group) {
                    ContentUnavailableView(
                        "Здесь чисто",
                        systemImage: "sparkles",
                        description: Text("Инструменты, которые знает Trash, на этом Mac не нашлись или ничего не оставили.")
                    )
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(group.title)
    }

    private var summary: some View {
        HStack(alignment: .bottom, spacing: 44) {
            figure("Найдено", model.totalSize(of: group).byteText, color: Theme.text)
            figure("Отмечено к удалению", model.selectedSize(in: group).byteText, color: Theme.accent)
            let junk = model.unmarkedJunkSize(in: group)
            if junk > 0 {
                figure("Мусор, не отмечен", junk.byteText, color: Theme.info)
            }
            Spacer()
            if model.phase == .scanning && !model.isScanned(group) {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func figure(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.display(38, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func expansionBinding(for category: CleanupCategory) -> Binding<Bool> {
        Binding {
            expandedCategories.contains(category)
        } set: { isExpanded in
            if isExpanded {
                expandedCategories.insert(category)
            } else {
                expandedCategories.remove(category)
            }
        }
    }
}

/// Раздел-карточка: заголовок с чекбоксом «выбрать всё», а под ним — раскрываемый список.
private struct GroupSection: View {
    let model: CleanupViewModel
    let category: CleanupCategory
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            GroupSectionHeader(model: model, category: category, isExpanded: $isExpanded)
            if isExpanded {
                GroupSectionContent(model: model, category: category)
            }
        }
        .card(Theme.sunken, radius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Заголовок раздела: чекбокс «выбрать всё», название, метка «только поиск», отмечено и размер.
private struct GroupSectionHeader: View {
    let model: CleanupViewModel
    let category: CleanupCategory
    @Binding var isExpanded: Bool

    private var result: CategoryScanResult? { model.result(for: category) }

    var body: some View {
        HStack(spacing: 10) {
            selectAll
                .frame(width: 28)

            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                    Image(systemName: category.systemImage)
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(category.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "раскрыт" : "свёрнут")

            if !category.isDeletable {
                Badge(title: "только поиск")
                    .help("Удаление этого раздела появится в следующей версии")
            }

            // Свёрнутый раздел не показывает элементы — отмеченное видно здесь.
            let selected = model.selectedSize(in: category)
            if selected > 0 {
                Text("отмечено \(selected.byteText)")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.accent)
            }
            trailing
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .background(Theme.surface)
    }

    /// Смешанное состояние при частичном выборе. Раздел без удаляемых элементов — пустое место для выравнивания.
    @ViewBuilder
    private var selectAll: some View {
        let sources = model.selectAllSources(for: category)
        if sources.isEmpty {
            Color.clear
                .accessibilityHidden(true)
        } else {
            Toggle(sources: sources, isOn: \.self) {
                Text("Выбрать всё в разделе «\(category.title)»")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let result {
            if result.isAccessDenied {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                    .help("Нет доступа к части папок — нужен полный доступ к диску")
            }
            if result.items.isEmpty, let reason = result.unavailableReason {
                Text("нет данных")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .help(reason)
            } else {
                Text(result.totalSize.byteText)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 80, alignment: .trailing)
            }
        } else if model.phase == .scanning {
            ProgressView()
                .controlSize(.small)
        }
    }
}

/// Содержимое раскрытого раздела: описание, причина пустоты или элементы.
private struct GroupSectionContent: View {
    let model: CleanupViewModel
    let category: CleanupCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 64)
                .padding(.trailing, 18)
                .padding(.vertical, 12)

            if let result = model.result(for: category) {
                if result.isAccessDenied {
                    FullDiskAccessBanner()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                if result.items.isEmpty {
                    Label(result.unavailableReason ?? "Здесь чисто",
                          systemImage: result.unavailableReason == nil ? "sparkles" : "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, 64)
                        .padding(.bottom, 14)
                } else {
                    // Набор отметок читается явно: строки обновятся и после «выбрать всё» в заголовке на любой macOS,
                    // а неизменившиеся отсечёт `.equatable()`.
                    let selection = model.selection
                    LazyVStack(spacing: 0) {
                        ForEach(result.items) { item in
                            ItemRow(item: item, isSelected: selection.contains(item.id)) { model.setSelected($0, for: item) }
                                .equatable()
                                .padding(.horizontal, 8)
                                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                }
            } else if model.phase == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 64)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
