import AppKit
import SwiftUI

/// 单一语义主题:颜色随有效外观(浅色/深色)动态解析,界面不再使用静态浅色值。
enum TingjianTheme {
    static let paper = dynamic(light: "#FFFFFF", dark: "#1C1D1F")
    static let windowSurface = dynamic(light: "#F3F4F6", dark: "#17181A")
    static let controlSurface = dynamic(light: "#FFFFFF", dark: "#242528")
    static let ink = dynamic(light: "#202124", dark: "#ECEDEF")
    static let secondaryInk = dynamic(light: "#5F6368", dark: "#B9BBC0")
    static let tertiaryInk = dynamic(light: "#73777D", dark: "#96999F")
    static let accent = dynamic(light: "#3567B7", dark: "#8AB4F8")
    static let accentSoft = dynamic(light: "#E8F0FE", dark: "#293A55")
    static let hairline = dynamic(light: "#DADCE0", dark: "#3B3D42")
    static let record = dynamic(light: "#BE3434", dark: "#F08B85")
    static let warning = dynamic(light: "#925C12", dark: "#E9BD75")
    static let paperTop = paper
    static let paperBottom = paper

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return NSColor(tingjianHex: match == .darkAqua ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(tingjianHex hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

enum TingjianTone {
    case neutral, accent, warning, error, recording

    var color: Color {
        switch self {
        case .neutral: TingjianTheme.tertiaryInk
        case .accent: TingjianTheme.accent
        case .warning: TingjianTheme.warning
        case .error, .recording: TingjianTheme.record
        }
    }
}

struct TingjianPaperBackground: View {
    var body: some View {
        TingjianTheme.paper
        .ignoresSafeArea()
    }
}
