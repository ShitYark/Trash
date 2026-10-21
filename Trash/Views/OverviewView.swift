import SwiftUI

/// Экран «Обзор»: сколько можно освободить, что занимает диск, сводка по группам. Во время скана — ход сканирования.
struct OverviewView: View {
    let model: CleanupViewModel

    /// Группы по убыванию найденного; категории «Системы» — одной карточкой.
    private var groups: [CategoryGroup] {
        CategoryGroup.allCases.sorted { model.totalSize(of: $0) > model.totalSize(of: $1) }
    }

    private var hasDeniedAccess: Bool {
        model.results.values.contains(where: \.isAccessDenied)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if model.phase == .scanning {
                    ScanProgress(model: model)
                } else if model.results.isEmpty {
                    notScanned
                } else {
                    hero
                    if let disk = model.disk {
                        DiskComposition(model: model, disk: disk, groups: groups)
                    }
                    if hasDeniedAccess {
                        FullDiskAccessBanner()
                    }
                    groupCards
                    if model.unmarkedJunkSize > 0 {
                        searchOnlyNote
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Обзор")
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(title: "Можно освободить сейчас")
                Text(model.selectedSize.byteText)
                    .font(Theme.display(84))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("Отмечено автоматически из \(model.foundSize.byteText) найденного: то, что программы создадут заново, и данные уже удалённых программ. Любую отметку можно снять перед очисткой.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let disk = model.disk {
                freeSpaceCard(disk)
            }
        }
    }

    private func freeSpaceCard(_ disk: DiskSpace) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(Theme.textMuted)
                Text(disk.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(disk.total.byteText)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(alignment: .bottom, spacing: 14) {
                figure("Свободно сейчас", disk.available.byteText, color: Theme.text)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.textFaint)
                    .padding(.bottom, 6)
                figure("После очистки", (disk.available + model.selectedSize).byteText, color: Theme.accent)
            }
            Text("Если удалить навсегда или потом очистить Корзину.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(22)
        .frame(width: 330, alignment: .leading)
        .card()
    }

    private func figure(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(Theme.mono(22, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var groupCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("По разделам")
                .font(Theme.display(17, weight: .medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                ForEach(groups) { group in
                    GroupCard(model: model, group: group)
                }
            }
        }
    }

    private var searchOnlyNote: some View {
        let titles = CleanupCategory.allCases
            .filter { category in model.result(for: category)?.items.contains { $0.isUnmarkedJunk && !model.isSelected($0) } == true }
            .map(\.title)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "eye")
                .font(.system(size: 15))
                .foregroundStyle(Theme.info)
                .frame(width: 36, height: 36)
                .background(Theme.infoTile, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Ещё \(model.unmarkedJunkSize.byteText) мусора не отмечено")
                    .font(.system(size: 14, weight: .semibold))
                Text("Помечено меткой «мусор»: \(titles.joined(separator: ", ")). Само не отмечается — проверьте и отметьте нужное вручную: рантаймы, симуляторы и пакеты Homebrew удаляются сразу, без Корзины.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.infoBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.infoLine, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var notScanned: some View {
        ContentUnavailableView {
            Label("Ещё не сканировали", systemImage: "magnifyingglass")
        } actions: {
            Button("Сканировать") {
                Task { await model.scan() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

/// «Что занимает диск»: группы, остальные данные и свободное место на одной полосе.
private struct DiskComposition: View {
    let model: CleanupViewModel
    let disk: DiskSpace
    let groups: [CategoryGroup]

    private var other: Int64 { max(0, disk.used - model.foundSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Что занимает диск")
                    .font(Theme.display(17, weight: .medium))
                Text("мусор — \(model.foundSize.byteText) из \(disk.used.byteText) занятого места")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            SegmentBar(segments: segments, height: 40, spacing: 3)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.lineStrong))
            legend
        }
    }

    private var segments: [BarSegment] {
        let groupSegments = groups.enumerated().map { index, group in
            BarSegment(id: group.id, value: Double(model.totalSize(of: group)), fill: shade(index))
        }
        return groupSegments + [
            BarSegment(id: "other", value: Double(other), fill: Theme.line),
            BarSegment(id: "free", value: Double(disk.available), fill: nil),
        ]
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                legendItem(group.title, model.totalSize(of: group), swatch: shade(index))
            }
            legendItem("Остальные данные", other, swatch: Theme.line)
            legendItem("Свободно", disk.available, swatch: nil)
        }
    }

    private func legendItem(_ title: String, _ size: Int64, swatch: Color?) -> some View {
        HStack(spacing: 7) {
            Group {
                if let swatch {
                    RoundedRectangle(cornerRadius: 3).fill(swatch)
                } else {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.barIdle)
                }
            }
            .frame(width: 10, height: 10)
            Text(title)
                .font(.system(size: 12))
            Text(size.byteText)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
        }
        .fixedSize()
    }

    private func shade(_ index: Int) -> Color {
        Theme.accentShades[min(index, Theme.accentShades.count - 1)]
    }
}

/// Карточка группы на «Обзоре»: найдено, отмечено, крупнейшие разделы.
private struct GroupCard: View {
    let model: CleanupViewModel
    let group: CategoryGroup

    private var total: Int64 { model.totalSize(of: group) }
    private var selected: Int64 { model.selectedSize(in: group) }

    private var categories: [CleanupCategory] {
        model.visibleCategories(in: group).sorted { (model.result(for: $0)?.totalSize ?? 0) > (model.result(for: $1)?.totalSize ?? 0) }
    }

    /// Систему открывает её первая категория, группы — свой экран.
    private var destination: SidebarItem {
        group == .system ? .category(.userCaches) : .group(group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: group.systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(group.title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    model.selectedItem = destination
                } label: {
                    Label("Открыть", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(QuietButtonStyle())
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(total.byteText)
                    .font(Theme.display(30, weight: .medium))
                Text("найдено")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                Text(selected == total && total > 0 ? "отмечено всё" : "отмечено \(selected.byteText)")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.accent)
            }

            SizeBar(fraction: total > 0 ? Double(selected) / Double(total) : 0, color: Theme.accent)

            VStack(spacing: 0) {
                ForEach(categories.prefix(3)) { category in
                    row(category)
                }
                if categories.count > 3 {
                    Text("и ещё \(categories.count - 3) \((categories.count - 3).plural("раздел", "раздела", "разделов"))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
        .padding(20)
        .card()
    }

    private func row(_ category: CleanupCategory) -> some View {
        let result = model.result(for: category)
        return HStack(spacing: 10) {
            Text(category.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            if !category.isDeletable {
                Badge(title: "только поиск")
            }
            Group {
                if let result, result.isAccessDenied, result.items.isEmpty {
                    Label("нет доступа", systemImage: "lock.fill")
                        .font(.system(size: 12))
                } else if let result, result.items.isEmpty, result.unavailableReason != nil {
                    Text("нет данных").font(.system(size: 12))
                } else {
                    Text((result?.totalSize ?? 0).byteText).font(Theme.mono(12))
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

}

/// Ход сканирования: сколько разделов готово, что уже найдено, состояние каждого раздела.
private struct ScanProgress: View {
    let model: CleanupViewModel

    private var total: Int { CleanupCategory.allCases.count }
    private var done: Int { model.results.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(title: "Сканирование")
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(done)")
                            .font(Theme.display(80))
                        Text("из \(total) разделов")
                            .font(Theme.display(26, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Уже найдено")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                    Text(model.foundSize.byteText)
                        .font(Theme.mono(32, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }

            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index < done ? Theme.accent : Theme.accentDim)
                        .frame(height: 36)
                }
            }
            .accessibilityHidden(true)

            HStack(spacing: 20) {
                Text("готово — \(done)")
                Text("ищем — \(total - done)")
                Spacer()
                Text("Диск только читается, ничего не удаляется.")
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                // Крупные группы первыми — так сетка панелей ровнее.
                ForEach(CategoryGroup.allCases.sorted { $0.categories.count > $1.categories.count }) { group in
                    panel(group)
                }
            }
        }
    }

    private func panel(_ group: CategoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(group.title)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(group.categories.filter { model.result(for: $0) != nil }.count) из \(group.categories.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            VStack(spacing: 0) {
                ForEach(group.categories) { category in
                    progressRow(category)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .card()
    }

    private func progressRow(_ category: CleanupCategory) -> some View {
        let result = model.result(for: category)
        return HStack(spacing: 12) {
            if result == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
            }
            Text(category.title)
                .font(.system(size: 13))
                .foregroundStyle(result == nil ? Theme.textSecondary : Theme.text)
            Spacer()
            Group {
                if let result {
                    if result.isAccessDenied && result.items.isEmpty {
                        Text("нет доступа")
                    } else if result.items.isEmpty {
                        Text(result.unavailableReason == nil ? "здесь чисто" : "нет данных")
                    } else {
                        Text(result.totalSize.byteText).font(Theme.mono(12))
                    }
                } else {
                    Text("ищем…").foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Иконка справа от текста: «Открыть →».
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}
