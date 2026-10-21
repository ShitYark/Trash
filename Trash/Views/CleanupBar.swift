import SwiftUI

/// Нижняя панель: сколько отмечено на текущем экране и кнопка «Очистить». Клавиатурного шортката у неё нет намеренно.
struct CleanupBar: View {
    let model: CleanupViewModel
    let onClean: () -> Void

    private var scopeHint: String {
        model.cleanupScope == .overview ? "во всех разделах" : "на этом экране"
    }

    var body: some View {
        HStack(spacing: 14) {
            if model.phase == .cleaning {
                ProgressView()
                    .controlSize(.small)
                Text("Очистка…")
                    .font(.system(size: 13))
            } else {
                Text("Отмечено к удалению")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                Text(model.cleanupSize.byteText)
                    .font(Theme.mono(16, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(scopeHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            }

            Spacer()

            Button(action: onClean) {
                Label("Очистить", systemImage: "trash")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.phase != .idle || model.cleanupItems.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.sunken)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
