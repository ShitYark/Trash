import SwiftUI

/// Боковая панель: знак, «Обзор», категории «Системы», группы одним пунктом и виджет диска.
struct SidebarView: View {
    let model: CleanupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 10)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarRow(model: model, item: .overview, title: "Обзор", systemImage: "gauge.with.dots.needle.33percent") {
                        EmptyView()
                    }

                    section("Система") {
                        ForEach(CategoryGroup.system.categories) { category in
                            SidebarRow(model: model, item: .category(category), title: category.title, systemImage: category.systemImage) {
                                categoryTrailing(category)
                            }
                        }
                    }

                    section("Группы") {
                        ForEach(SidebarItem.groups) { group in
                            SidebarRow(model: model, item: .group(group), title: group.title, systemImage: group.systemImage) {
                                groupTrailing(group)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            if let disk = model.disk {
                DiskWidget(disk: disk, junk: model.foundSize)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark()
            Text("Trash")
                .font(Theme.display(17))
                .foregroundStyle(Theme.text)
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(title: title)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            rows()
        }
    }

    @ViewBuilder
    private func categoryTrailing(_ category: CleanupCategory) -> some View {
        let result = model.result(for: category)
        if let result, result.isAccessDenied, result.items.isEmpty {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .help("Нет доступа — нужен полный доступ к диску")
        } else if let result {
            SizeLabel(size: result.totalSize)
        } else if model.phase == .scanning {
            ScanningLabel()
        }
    }

    @ViewBuilder
    private func groupTrailing(_ group: CategoryGroup) -> some View {
        if model.isScanned(group) {
            SizeLabel(size: model.totalSize(of: group))
        } else if model.phase == .scanning {
            ScanningLabel()
        }
    }
}

/// Пункт боковой панели: иконка, название, справа размер или состояние.
private struct SidebarRow<Trailing: View>: View {
    let model: CleanupViewModel
    let item: SidebarItem
    let title: String
    let systemImage: String
    @ViewBuilder let trailing: () -> Trailing

    @State private var isHovered = false

    private var isSelected: Bool { model.selectedItem == item }

    var body: some View {
        Button {
            model.selectedItem = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                trailing()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return Theme.raised }
        return isHovered ? Theme.navHover : .clear
    }
}

private struct SizeLabel: View {
    let size: Int64

    var body: some View {
        Text(size.byteText)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textFaint)
    }
}

private struct ScanningLabel: View {
    var body: some View {
        Text("ищем…")
            .font(.system(size: 11))
            .foregroundStyle(Theme.accent)
    }
}

/// Том внизу панели: найденный мусор, остальные данные и свободное место.
private struct DiskWidget: View {
    let disk: DiskSpace
    let junk: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(disk.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(disk.total.byteText)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
            }
            SegmentBar(segments: [
                BarSegment(id: "junk", value: Double(min(junk, disk.used)), fill: Theme.accent),
                BarSegment(id: "data", value: Double(max(0, disk.used - junk)), fill: Theme.lineStrong),
                BarSegment(id: "free", value: Double(disk.available), fill: nil),
            ], height: 6)
            Text(junk > 0 ? "свободно \(disk.available.byteText), мусор — \(junk.byteText)" : "свободно \(disk.available.byteText)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
