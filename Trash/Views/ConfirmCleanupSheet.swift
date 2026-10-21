import SwiftUI

/// Подтверждение очистки: что уйдёт по группам и выбор — в Корзину или навсегда.
/// У кнопок удаления нет клавиатурного шортката: Return не должен удалять файлы. «Отмена» — по Esc.
struct ConfirmCleanupSheet: View {
    let model: CleanupViewModel
    let onConfirm: (_ permanently: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    /// То, что уйдёт в очистку, по группам — прямо из `cleanupItems`: дубли там уже убраны, а категория элемента —
    /// та, что видна на текущем экране. Строки сходятся с итогом.
    private var breakdown: [BreakdownRow] {
        let items = model.cleanupItems
        return CategoryGroup.allCases.compactMap { group in
            let inGroup = items.filter { $0.category.group == group }
            guard !inGroup.isEmpty else { return nil }
            let titles = group.categories
                .filter { category in inGroup.contains { $0.category == category } }
                .map(\.title)
                .joined(separator: ", ")
            return BreakdownRow(group: group, titles: titles, size: inGroup.reduce(0) { $0 + $1.size })
        }
    }

    var body: some View {
        let count = model.cleanupItems.count
        let breakdown = breakdown
        let notes = CleanupNotes(items: model.cleanupItems)
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "trash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 48, height: 48)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Очистить \(count) \(count.plural("объект", "объекта", "объектов")) — \(model.cleanupSize.byteText)?")
                        .font(Theme.display(22, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(notes.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !breakdown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(breakdown) { row in
                        breakdownRow(row, isFirst: row.id == breakdown.first?.id)
                    }
                }
                .card(Theme.sheet, radius: 14)
            }

            if !notes.lines.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.info)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notes.lines, id: \.text) { line in
                            Text(line.text)
                                .fontWeight(line.isIrreversible ? .semibold : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.noteText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.noteBackground, in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                if notes.isAlwaysPermanent {
                    // Режим этим элементам не важен; «в Корзину» — на случай, если сюда всё же попадёт обычный файл.
                    ChoiceButton(
                        title: "Удалить",
                        caption: "Сразу, без Корзины. Вернуть будет нельзя.",
                        isPrimary: false
                    ) {
                        onConfirm(false)
                    }
                } else {
                    ChoiceButton(
                        title: "Переместить в Корзину",
                        caption: notes.trashCaption,
                        isPrimary: true
                    ) {
                        onConfirm(false)
                    }
                    ChoiceButton(
                        title: "Удалить навсегда",
                        caption: notes.permanentCaption,
                        isPrimary: false
                    ) {
                        onConfirm(true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 620)
        .foregroundStyle(Theme.text)
        .background(Theme.sheet)
    }

    private func breakdownRow(_ row: BreakdownRow, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.group.title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 96, alignment: .leading)
            Text(row.titles)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.size.byteText)
                .font(Theme.mono(13))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

private struct BreakdownRow: Identifiable {
    let group: CategoryGroup
    let titles: String
    let size: Int64

    var id: CategoryGroup { group }
}

/// Тексты окна подтверждения по составу очистки — только про то, что отмечено: что перед удалением не тронем,
/// куда уйдёт то, что уходит не по выбранному режиму, и что обещают кнопки. Считаются из `cleanupItems` —
/// того же списка, что уходит в `Cleaner`.
struct CleanupNotes {
    struct Line {
        let text: String
        /// Уйдёт мимо Корзины: менеджеры и сама Корзина — выделяется.
        let isIrreversible: Bool
    }

    /// «Перед удалением всё проверяется ещё раз: не тронем …».
    let subtitle: String
    /// Строки плашки; пусто — плашки нет.
    let lines: [Line]
    /// Всё отмеченное удаляется навсегда при любом режиме — менеджерами или как содержимое Корзины:
    /// выбора нет, кнопка одна.
    let isAlwaysPermanent: Bool
    /// Подписи кнопок «Переместить в Корзину» и «Удалить навсегда» с исключениями из отмеченного.
    let trashCaption: String
    let permanentCaption: String

    /// - Parameter needsAdministrator: то же правило, что у `Cleaner`, — системная папка, куда нельзя писать.
    init(items: [ScanItem], needsAdministrator: (ScanItem) -> Bool = { AdministratorScript.isNeeded(for: $0, system: SystemLocations()) }) {
        let viaAdministrator = items.filter(needsAdministrator)
        let viaFiles = items.filter { $0.removal == nil }
        let viaManagers = items.filter { $0.removal != nil }
        let filesHave = { (category: CleanupCategory) in viaFiles.contains { $0.category == category } }
        let managersHave = { (category: CleanupCategory) in viaManagers.contains { $0.category == category } }
        let hasPrograms = viaFiles.contains { $0.category.isApplicationBundle }
        let hasTrash = viaFiles.contains { $0.category.alwaysDeletesPermanently }
        let isAlwaysPermanent = !items.isEmpty
            && items.allSatisfy { $0.removal != nil || $0.category.alwaysDeletesPermanently || needsAdministrator($0) }

        // Что защищает каждый вид: страж — файлы, `Cleaner` — запущенные программы и активные версии,
        // `ManagerRemover` — свежее состояние перед командой.
        var kept: [String] = []
        if !viaFiles.isEmpty { kept.append("системные папки и файлы вне разрешённых") }
        if hasPrograms { kept.append("запущенные программы") }
        if filesHave(.terminalPrograms) { kept.append("ссылки, которые снова ведут на программу") }
        if filesHave(.backgroundServices) { kept.append("службы, чья программа снова на месте") }
        if filesHave(.applicationSupportCaches) { kept.append("кэши запущенных программ") }
        if managersHave(.simulatorDyldCaches) { kept.append("кэши рантаймов с запущенным симулятором") }
        if filesHave(.languageVersions) { kept.append("активные версии языков") }
        if viaFiles.contains(where: { $0.category == .androidSDK && $0.url.pathExtension == "avd" }) { kept.append("запущенные эмуляторы Android") }
        if viaFiles.contains(where: { $0.category == .androidSDK && $0.url.pathComponents.contains("system-images") }) {
            kept.append("нужные эмуляторам образы Android")
        }
        if managersHave(.simulatorRuntimes) { kept.append("нужные симуляторам рантаймы") }
        if managersHave(.simulators) { kept.append("включённые симуляторы") }
        if managersHave(.homebrew) { kept.append("нужные другим пакеты Homebrew") }
        if viaManagers.contains(where: { if case .condaRemoveEnvironment = $0.removal { true } else { false } }) {
            kept.append("base conda")
        }
        subtitle = kept.isEmpty
            ? "Перед удалением всё проверяется ещё раз."
            : "Перед удалением всё проверяется ещё раз: не тронем \(kept.joined(separator: ", "))."

        var lines: [Line] = []
        let simctl = [(CleanupCategory.simulatorRuntimes, "рантаймы симуляторов"), (.simulators, "симуляторы"),
                      (.simulatorDyldCaches, "кэши симуляторов")]
            .filter { managersHave($0.0) }
            .map(\.1)
        if !simctl.isEmpty {
            lines.append(Line(text: "\(Self.listed(simctl, last: " и ").capitalizedFirst) удалит simctl — сразу, без Корзины.", isIrreversible: true))
        }
        if managersHave(.homebrew) {
            lines.append(Line(text: "Пакеты Homebrew удалит brew — сразу, без Корзины.", isIrreversible: true))
        }
        if managersHave(.docker) {
            lines.append(Line(text: "Данные Docker удалит docker — сразу, без Корзины.", isIrreversible: true))
        }
        let conda = [("окружения", { (removal: ManagerRemoval) in if case .condaRemoveEnvironment = removal { true } else { false } }),
                     ("кэш пакетов", { (removal: ManagerRemoval) in if case .condaClean = removal { true } else { false } })]
            .filter { _, matches in viaManagers.contains { $0.removal.map(matches) == true } }
            .map(\.0)
        if !conda.isEmpty {
            lines.append(Line(text: "\(conda.joined(separator: " и ").capitalizedFirst) conda удалит сама conda — сразу, без Корзины.", isIrreversible: true))
        }
        let administrator = [(CleanupCategory.terminalPrograms, "битые ссылки"), (.backgroundServices, "службы в /Library"), (.macPorts, "порты MacPorts")]
            .filter { category, _ in viaAdministrator.contains { $0.category == category } }
            .map(\.1)
        if !administrator.isEmpty {
            lines.append(Line(text: "\(Self.listed(administrator, last: " и ").capitalizedFirst) — с паролем администратора, сразу и без Корзины.",
                              isIrreversible: true))
        }
        if managersHave(.ollama) {
            lines.append(Line(text: "Модели удалит Ollama — сразу, без Корзины.", isIrreversible: true))
        }
        if filesHave(.simulators) {
            lines.append(Line(text: "Папки без симулятора удаляются как файлы — по выбранному режиму.", isIrreversible: false))
        }
        if hasTrash {
            let text = isAlwaysPermanent
                ? "Содержимое Корзины удаляется навсегда."
                : "Содержимое Корзины удаляется навсегда, даже при «Переместить в Корзину»."
            lines.append(Line(text: text, isIrreversible: true))
        }
        if hasPrograms {
            lines.append(Line(text: "Программы уходят только в Корзину, даже при «Удалить навсегда».", isIrreversible: false))
        }
        self.lines = lines
        self.isAlwaysPermanent = isAlwaysPermanent

        // Инструменты — в постоянном порядке, только те, что удалят отмеченное.
        let tools: [String] = ["simctl", "brew", "docker", "conda", "Ollama", "port"].filter { tool in viaManagers.contains { $0.removal?.tool == tool } }
        let unrecoverable = [(!tools.isEmpty, "удалённого через \(Self.listed(tools, last: " или "))"),
                             (!viaAdministrator.isEmpty, "удалённого с паролем администратора"), (hasTrash, "содержимого Корзины")]
            .filter(\.0)
            .map(\.1)
        trashCaption = unrecoverable.isEmpty
            ? "Можно вернуть. Место освободится, когда очистите Корзину."
            : "Можно вернуть, кроме \(unrecoverable.joined(separator: " и ")). Остальное место — после очистки Корзины."
        permanentCaption = hasPrograms
            ? "Вернуть будет нельзя — кроме программ: они уйдут в Корзину."
            : "Место освободится сразу. Вернуть будет нельзя."
    }
}

extension CleanupNotes {
    /// «a, b и c» — перечисление для текста.
    fileprivate static func listed(_ items: [String], last: String) -> String {
        items.dropLast().joined(separator: ", ") + (items.count > 1 ? last : "") + (items.last ?? "")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Очистка идёт: окно подтверждения остаётся открытым и после неё показывает отчёт.
struct CleaningProgressView: View {
    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Очистка…")
                .font(Theme.display(20, weight: .medium))
        }
        .padding(28)
        .frame(width: 620, height: 160)
        .foregroundStyle(Theme.text)
        .background(Theme.sheet)
    }
}

/// Большая кнопка выбора с подписью: что будет после нажатия.
private struct ChoiceButton: View {
    let title: String
    let caption: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if !isPrimary {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(isPrimary ? Theme.onAccentMuted : Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isPrimary ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(isPrimary ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if !isPrimary {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.barIdle)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
