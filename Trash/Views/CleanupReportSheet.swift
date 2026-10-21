import SwiftUI

/// Отчёт после очистки: сколько освобождено и почему что-то не удалилось — до трёх причин.
struct CleanupReportSheet: View {
    let report: CleanupReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                    .accessibilityHidden(true)
                Text("Очистка завершена")
                    .font(Theme.display(24, weight: .medium))
            }

            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Освобождено")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                    Text(report.freedBytes.byteText)
                        .font(Theme.display(48))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(Self.summary(of: report))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(Theme.sunken, radius: 14)

            if !report.failures.isEmpty {
                failures
            }

            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 620)
        .foregroundStyle(Theme.text)
        .background(Theme.sheet)
    }

    /// Итог по тому, куда ушло удалённое. Одно направление — без чисел, несколько — по строке на каждое.
    /// `nonisolated`: вью неявно на главном акторе, а чистый текст нужен и тестам вне него.
    nonisolated static func summary(of report: CleanupReport) -> String {
        if report.removed.isEmpty {
            return "Ничего не удалено — причины ниже."
        }
        let destinations = [
            (report.movedToTrash, "Перемещено в Корзину: место освободится, когда очистите её.", "В Корзину"),
            (report.deletedPermanently, "Удалено навсегда.", "Навсегда"),
            (report.removedByManagers, "Удалено сразу, без Корзины.", "Сразу, без Корзины"),
        ].filter { $0.0 > 0 }
        if destinations.count == 1, let only = destinations.first {
            return only.1
        }
        return destinations.map { "\($0.2): \($0.0)" }.joined(separator: "\n")
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Не удалось удалить: \(report.failures.count)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                // Причины видны сразу: «программа запущена», «снова установлена», текст ошибки macOS.
                ForEach(Array(report.failures.prefix(3).enumerated()), id: \.offset) { index, failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.title ?? failure.url.lastPathComponent)
                            .font(Theme.mono(12))
                        Text(failure.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                }
                if report.failures.count > 3 {
                    Text("…и ещё \(report.failures.count - 3)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
            .card(Theme.sheet, radius: 12)
        }
    }
}
