import SwiftUI

/// Подпись секции капителью: «Система», «Можно освободить сейчас».
struct Eyebrow: View {
    let title: String

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.textFaint)
    }
}

/// Метка: «мусор» и «только поиск» в заголовке раздела — синим; нейтральная — серым, например «только поиск» в строке элемента.
struct Badge: View {
    enum Kind {
        case info
        case neutral
    }

    let title: String
    var kind: Kind = .info

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(kind == .info ? Theme.info : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(kind == .info ? Theme.infoLine : Theme.lineStrong))
            .fixedSize()
    }
}

/// Полоса размера в строке: доля от самого большого элемента списка.
struct SizeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(color)
                .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
        }
        .frame(height: 6)
        .background(Theme.barTrack, in: Capsule())
        .accessibilityHidden(true)
    }
}

/// Сегмент полосы из нескольких частей. `fill == nil` — пустой сегмент с рамкой, например свободное место.
struct BarSegment: Identifiable {
    let id: String
    let value: Double
    let fill: Color?
}

/// Полоса из сегментов пропорционально значениям: диск, состав группы.
struct SegmentBar: View {
    let segments: [BarSegment]
    var height: CGFloat = 14
    var spacing: CGFloat = 2

    private var visible: [BarSegment] { segments.filter { $0.value > 0 } }

    var body: some View {
        GeometryReader { proxy in
            let total = visible.reduce(0) { $0 + $1.value }
            let width = proxy.size.width - spacing * CGFloat(max(0, visible.count - 1))
            HStack(spacing: spacing) {
                ForEach(visible) { segment in
                    piece(segment)
                        .frame(width: total > 0 ? max(3, width * segment.value / total) : 0)
                }
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func piece(_ segment: BarSegment) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(height / 2, 5))
        if let fill = segment.fill {
            shape.fill(fill)
        } else {
            shape.strokeBorder(Theme.lineStrong)
        }
    }
}

/// Главное действие: оранжевая кнопка.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            .background(
                Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Второстепенная кнопка с рамкой.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Theme.text : Theme.textFaint)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lineStrong))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Кнопка-иконка в строке, например «Показать в Finder».
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// Карточка: фон, скругление и тонкая рамка.
    func card(_ background: Color = Theme.surface, radius: CGFloat = 16) -> some View {
        self
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line))
    }
}
