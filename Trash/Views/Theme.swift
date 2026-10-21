import SwiftUI

/// Дизайн «Сортировочная»: графит, сигнальный оранжевый акцент и моноширинные размеры. Окно всегда тёмное.
enum Theme {
    static let background = Color(hex: 0x131416)
    static let sidebar = Color(hex: 0x1A1B1E)
    static let surface = Color(hex: 0x1A1B1E)
    static let sunken = Color(hex: 0x17181B)
    static let raised = Color(hex: 0x26292D)
    static let sheet = Color(hex: 0x1E2023)
    static let line = Color(hex: 0x2C2F34)
    static let lineStrong = Color(hex: 0x3A3E44)

    static let text = Color(hex: 0xEDEEF0)
    static let textSecondary = Color(hex: 0xC9CCD1)
    static let textMuted = Color(hex: 0xA9ADB4)
    static let textFaint = Color(hex: 0x8C9199)

    static let accent = Color(hex: 0xFF8A3D)
    static let onAccent = Color(hex: 0x17120B)
    /// Оттенки акцента по убыванию яркости — сегменты групп на полосе диска.
    static let accentShades = [accent, Color(hex: 0xB36430), Color(hex: 0x804A28), Color(hex: 0x5A3722)]
    /// Раздел ещё сканируется.
    static let accentDim = Color(hex: 0x6D4125)

    /// Подпись на оранжевой кнопке.
    static let onAccentMuted = Color(hex: 0x3A2410)

    /// «Только поиск» и подсказки.
    static let info = Color(hex: 0x79B4FF)
    static let infoLine = Color(hex: 0x35506F)
    static let infoBackground = Color(hex: 0x161A20)
    static let infoTile = Color(hex: 0x1D2733)
    static let noteBackground = Color(hex: 0x172029)
    static let noteText = Color(hex: 0xC9D6E6)

    static let navHover = Color(hex: 0x222428)
    static let barTrack = Color(hex: 0x26292D)
    static let barIdle = Color(hex: 0x4A4F57)

    /// Крупные цифры и заголовки экранов.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Размеры, пути и версии.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Int64 {
    /// Размер так, как его показывает Finder.
    var byteText: String { formatted(.byteCount(style: .file)) }
}

extension Int {
    /// Форма слова после числа: 1 объект, 2 объекта, 5 объектов.
    func plural(_ one: String, _ few: String, _ many: String) -> String {
        switch (self % 10, self % 100) {
        case (1, let tens) where tens != 11: one
        case (2...4, let tens) where !(12...14).contains(tens): few
        default: many
        }
    }
}

/// Знак Trash в боковой панели — бак из иконки приложения, тёмный на оранжевом.
struct BrandMark: View {
    var body: some View {
        TrashGlyph()
            .fill(Theme.onAccent, style: FillStyle(eoFill: true))
            .padding(6)
            .frame(width: 30, height: 30)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

/// Бак из иконки приложения: ручка, крышка, корпус и две прорези. Прорези — дырки при заливке even-odd.
struct TrashGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // Координаты — из сетки иконки 1024 × 1024.
        let bounds = CGRect(x: 284, y: 244, width: 456, height: 540)
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let offset = CGPoint(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * scale + offset.x, y: y * scale + offset.y)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(origin: point(x, y), size: CGSize(width: width * scale, height: height * scale))
        }
        func corner(_ radius: CGFloat) -> CGSize {
            CGSize(width: radius * scale, height: radius * scale)
        }

        var path = Path()
        path.addRoundedRect(in: box(448, 244, 128, 40), cornerSize: corner(16))
        path.addRoundedRect(in: box(284, 296, 456, 68), cornerSize: corner(34))
        path.move(to: point(318, 396))
        path.addLine(to: point(706, 396))
        path.addLine(to: point(672, 740))
        path.addQuadCurve(to: point(623, 784), control: point(667, 784))
        path.addLine(to: point(401, 784))
        path.addQuadCurve(to: point(352, 740), control: point(357, 784))
        path.closeSubpath()
        path.addRoundedRect(in: box(372, 466, 280, 60), cornerSize: corner(30))
        path.addRoundedRect(in: box(372, 584, 168, 60), cornerSize: corner(30))
        return path
    }
}
