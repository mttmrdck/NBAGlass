import SwiftUI
import AppKit
import NBAGlassCore

/// Native vibrancy (NSVisualEffectView). This SDK (macOS 15.5) has no `glassEffect`, so this is a
/// material-based fallback — not Apple's Liquid Glass.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    /// Below 1, the sharp desktop shows through the blur — softened wallpaper detail rather than fog.
    var alpha: CGFloat = 1
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.alphaValue = alpha
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.alphaValue = alpha }
}

/// Lets the user drag the window from this area (used behind the header).
struct WindowDragArea: NSViewRepresentable {
    final class V: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum Theme {
    static let charcoal = Color(red: 0.055, green: 0.065, blue: 0.090)
    static let navy = Color(red: 0.070, green: 0.095, blue: 0.165)
    static let accent = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let live = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let upcoming = Color(red: 0.38, green: 0.60, blue: 1.0)
    static let finished = Color.white.opacity(0.45)
    /// Fine blue-grey edge used on the panel and controls.
    static let edge = Color(red: 0.60, green: 0.68, blue: 0.84)

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.09)

    static let panelCorner: CGFloat = 14
    static let stripCorner: CGFloat = 9
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Team identity colours (from the provider) prepared for dark glass.
struct TeamPalette {
    /// Tint for the team's glass section.
    let tint: Color
    /// Narrow accents: separators, glows, celebration light.
    let accent: Color

    init(_ team: Team) {
        var primary = Self.rgb(team.colorHex) ?? (0.30, 0.36, 0.48)
        var alternate = Self.rgb(team.alternateColorHex)
        // A very bright primary (e.g. Warriors gold) makes a slab, not glass: tint with the darker
        // secondary and use the bright colour as the accent instead.
        if let a = alternate, Self.luminance(primary) > 0.5, Self.luminance(a) < 0.3 { (primary, alternate) = (a, primary) }
        // Near-black brands (Nets, Spurs…) become slate so the section still reads as glass.
        let tintRGB = Self.luminance(primary) < 0.06 ? (0.36, 0.39, 0.45) : primary
        tint = Color(red: tintRGB.0, green: tintRGB.1, blue: tintRGB.2)
        // Accent: the secondary colour if it is bright enough to glow on dark glass, else a lifted primary.
        if let a = alternate, Self.luminance(a) > 0.22 {
            accent = Color(red: a.0, green: a.1, blue: a.2)
        } else {
            let l = Self.lift(tintRGB, to: 0.45)
            accent = Color(red: l.0, green: l.1, blue: l.2)
        }
    }

    private typealias RGB = (Double, Double, Double)
    private static func rgb(_ hex: String?) -> RGB? {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    private static func luminance(_ c: RGB) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }
    private static func lift(_ c: RGB, to target: Double) -> RGB {
        let l = luminance(c)
        guard l < target else { return c }
        let t = (target - l) / (1 - l)
        return (c.0 + (1 - c.0) * t, c.1 + (1 - c.1) * t, c.2 + (1 - c.2) * t)
    }
}

/// Smoked glass panel. The window is non-opaque with a clear background, so the desktop is sampled
/// directly: a partly transparent behind-window blur lets softened wallpaper detail through, under a
/// light navy→charcoal smoke, a soft top reflection, inner edge shading and a fine blue-grey edge.
struct GlassBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
        ZStack {
            VisualEffectView(material: .hudWindow, alpha: 0.58)
            LinearGradient(colors: [Theme.navy.opacity(0.24), Theme.charcoal.opacity(0.40)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.09))
            // Inner shading toward the edges: stacked plain borders instead of a full-panel blur filter.
            shape.strokeBorder(Color.black.opacity(0.10), lineWidth: 9)
            shape.strokeBorder(Color.black.opacity(0.10), lineWidth: 4)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [Theme.edge.opacity(0.45), Theme.edge.opacity(0.12)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var radius: CGFloat = 6
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.09 : 0)))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}
extension View { func hoverHighlight(radius: CGFloat = 6) -> some View { modifier(HoverHighlight(radius: radius)) } }
