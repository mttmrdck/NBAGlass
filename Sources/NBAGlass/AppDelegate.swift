import AppKit
import SwiftUI
import Combine
import NBAGlassCore
import os

private let visibilityLog = Logger(subsystem: "com.nbaglass.app", category: "visibility")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences()
    private lazy var store = ScoreboardStore(prefs: prefs)
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let toggleItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(store: store, prefs: prefs) { [weak self] in self?.openSettings() }
        buildStatusItem()
        if prefs.panelVisible { panelController.show() }
        updatePolling()

        // Keeps the window in sync when visibility is toggled from Settings or the panel's menu.
        prefs.$panelVisible.dropFirst().removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            DispatchQueue.main.async {
                if visible, !self.panelController.isVisible { self.panelController.show() }
                if !visible, self.panelController.isVisible { self.panelController.hide() }
                self.updatePolling()
            }
        }.store(in: &cancellables)
        // While app windows fully cover the panel nothing is fetched or redrawn; it catches up
        // (only if its data is stale) as soon as any part of it is visible again.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: panelController.panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePolling() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPolling == true { self?.store.refresh(userInitiated: false) } }
        }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    private var isPolling = false

    /// Polls only while the panel is shown and at least partly visible on screen.
    private func updatePolling() {
        let onScreen = panelController.isVisible && panelController.panel.occlusionState.contains(.visible)
        guard onScreen != isPolling else { return }
        isPolling = onScreen
        visibilityLog.notice("panel \(onScreen ? "visible — polling" : "hidden/covered — paused", privacy: .public)")
        if onScreen { store.startPolling() } else { store.stopPolling() }
    }

    func applicationDidBecomeActive(_ notification: Notification) { if isPolling { store.refreshIfStale() } }
    // Closing the panel or settings never quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController.show(); return true
    }

    /// nbaglass://game/<id> shows the panel and expands that game; nbaglass://settings opens Settings.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        switch url.host {
        case "game":
            panelController.show()
            store.expandedGameID = url.lastPathComponent
        case "settings":
            openSettings()
        default: break
        }
    }

    // MARK: Menu bar
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "basketball", accessibilityDescription: "NBAGlass")
                ?? NSImage(systemSymbolName: "sportscourt", accessibilityDescription: "NBAGlass")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        toggleItem.action = #selector(togglePanel); toggleItem.target = self
        menu.addItem(toggleItem)
        let dock = NSMenuItem(title: "Dock to Right Edge", action: #selector(resetPosition), keyEquivalent: "")
        dock.target = self; menu.addItem(dock)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Scores", action: #selector(refreshScores), keyEquivalent: "r")
        refresh.target = self; menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NBAGlass", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = panelController.isVisible ? "Hide Scoreboard" : "Show Scoreboard"
    }

    @objc private func togglePanel() { panelController.toggle() }
    @objc private func resetPosition() { panelController.resetPosition() }
    @objc private func refreshScores() { store.refresh() }
    @objc private func settingsAction() { openSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView { [weak self] in self?.panelController.resetPosition() }.environmentObject(prefs).environmentObject(store))
            let w = NSWindow(contentViewController: host)
            w.title = "NBAGlass Settings"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
