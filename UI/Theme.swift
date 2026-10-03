import SwiftUI

/// Design tokens for the single-window UI (spec §5). Dark-only in v1; keep every
/// color here so a light palette can be added later without touching views.
enum Theme {
    static let bg = Color(hex: 0x1F1F23)
    static let card = Color(hex: 0x2A2A2F)
    static let cardRaised = Color(hex: 0x3C3C43)   // secondary buttons
    static let chipSelected = Color(hex: 0x3A2419)
    static let chipSelectedBorder = Color(hex: 0x6B3A24)
    static let chipSelectedText = Color(hex: 0xF4C3A8)
    static let line = Color(hex: 0x36363C)
    static let field = Color(hex: 0x17171A)
    static let fieldBorder = Color(hex: 0x45454C)
    static let text = Color(hex: 0xF2F2F5)
    static let sub = Color(hex: 0xA3A3AC)
    static let faint = Color(hex: 0x6E6E76)
    static let accent = Color(hex: 0xD4460C)
    static let accentText = Color(hex: 0xF0A37F)
    static let green = Color(hex: 0x3FBF7F)
    static let greenTrack = Color(hex: 0x2F4A3C)
    static let track = Color(hex: 0x45454C)
    static let warning = Color(hex: 0xE0B07A)
    static let danger = Color(hex: 0xFF6B5E)
    static let idleDot = Color(hex: 0x6E6E76)

    static let windowWidth: CGFloat = 380
    static let windowMinHeight: CGFloat = 600
    static let headerHeight: CGFloat = 52       // matches the unified-toolbar titlebar so traffic lights center
    static let trafficLightInset: CGFloat = 78  // leading space reserved for the traffic lights
    static let inset: CGFloat = 14
    static let cardRadius: CGFloat = 12
    static let gap: CGFloat = 12

    static var bgNSColor: NSColor { NSColor(red: 0x1F/255.0, green: 0x1F/255.0, blue: 0x23/255.0, alpha: 1) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
