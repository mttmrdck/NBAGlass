import AppKit
import SwiftUI
import Combine
import NBAGlassCore

/// Borderless, non-activating panel that lives on the desktop layer: below every normal app
/// window, above the wallpaper. It never takes focus and stays put during Show Desktop / Mission Control.
final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel is never key and its app is usually inactive, so every click is a "first mouse"
/// click; accept it so controls respond to a single click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 372
    static let margin: CGFloat = 24
    private static let minHeight: CGFloat = 200

    let panel: DesktopPanel
    private let prefs: Preferences
    /// Height the SwiftUI content would like; the window is this tall, capped by the screen.
    private var contentHeight: CGFloat = 480
    private var isPlacing = false
    private var cancellables = Set<AnyCancellable>()

    init(store: ScoreboardStore, prefs: Preferences, onOpenSettings: @escaping () -> Void) {
        self.prefs = prefs
        panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        // On every Space, ignored by Show Desktop / Exposé (.stationary), not in the window cycle.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.delegate = self
        panel.title = "NBAGlass"

        let actions = PanelActions(openSettings: onOpenSettings,
                                   dockToRightEdge: { [weak self] in self?.resetPosition() })
        let root = PanelRootView(actions: actions) { [weak self] h in self?.contentHeightChanged(h) }
            .environmentObject(store).environmentObject(prefs)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []      // the controller, not SwiftUI, owns the window size
        panel.contentView = host

        applyLevel()
        place()

        prefs.$panelLayer.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyLevel() }
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()   // ordered front only within its own (desktop) level
        prefs.panelVisible = true
    }
    func hide() {
        panel.orderOut(nil)
        prefs.panelVisible = false
    }
    func toggle() { isVisible ? hide() : show() }

    func resetPosition() {
        prefs.panelX = nil
        place()
    }

    /// Desktop-icon level + 1 keeps the panel clickable (Finder's desktop window would otherwise take
    /// the clicks) while still below every normal window. Desktop level + 1 tucks it under the icons.
    private func applyLevel() {
        let base: CGWindowLevelKey = prefs.panelLayer == .aboveIcons ? .desktopIconWindow : .desktopWindow
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(base)) + 1)
    }

    // MARK: Geometry
    /// The primary display (the one with the menu bar).
    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func contentHeightChanged(_ h: CGFloat) {
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        place()
    }

    /// Docked to the top of the usable area, `margin` from the right edge (or the dragged-to x);
    /// as tall as the content wants, never taller than the screen allows.
    private func place() {
        let v = screen.visibleFrame
        let maxH = v.height - Self.margin * 2
        let h = min(max(contentHeight, Self.minHeight), maxH)
        let defaultX = v.maxX - Self.width - Self.margin
        let x = prefs.panelX.map { min(max(CGFloat($0), v.minX + 4), v.maxX - Self.width - 4) } ?? defaultX
        let frame = NSRect(x: x, y: v.maxY - Self.margin - h, width: Self.width, height: h)
        guard frame != panel.frame else { return }
        isPlacing = true
        panel.setFrame(frame, display: true)
        isPlacing = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPlacing else { return }
        // Dragging only moves the panel sideways; it stays docked to the top margin.
        prefs.panelX = Double(panel.frame.origin.x)
        place()
    }
}
