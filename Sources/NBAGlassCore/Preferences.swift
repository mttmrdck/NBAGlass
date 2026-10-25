import Foundation
import Combine

public enum DefaultDay: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", yesterday = "Yesterday", tomorrow = "Tomorrow"
    public var id: String { rawValue }
    public var offset: Int { self == .today ? 0 : (self == .yesterday ? -1 : 1) }
}

public enum Density: String, CaseIterable, Identifiable, Sendable {
    case compact = "Compact", detailed = "Detailed"
    public var id: String { rawValue }
}

/// Window layer for the desktop panel. Both sit below every normal app window.
public enum PanelLayer: String, CaseIterable, Identifiable, Sendable {
    case aboveIcons = "Above desktop icons", belowIcons = "Behind desktop icons"
    public var id: String { rawValue }
}

public final class Preferences: ObservableObject {
    private let d: UserDefaults

    @Published public var refreshInterval: Double { didSet { d.set(refreshInterval, forKey: "refreshInterval") } }
    @Published public var favourites: Set<String> { didSet { d.set(Array(favourites), forKey: "favourites") } }
    @Published public var defaultFilter: GameFilter { didSet { d.set(defaultFilter.rawValue, forKey: "defaultFilter") } }
    @Published public var defaultDay: DefaultDay { didSet { d.set(defaultDay.rawValue, forKey: "defaultDay") } }
    @Published public var density: Density { didSet { d.set(density.rawValue, forKey: "density") } }
    @Published public var showFinal: Bool { didSet { d.set(showFinal, forKey: "showFinal") } }
    @Published public var useDemoData: Bool { didSet { d.set(useDemoData, forKey: "useDemoData") } }
    @Published public var panelVisible: Bool { didSet { d.set(panelVisible, forKey: "panelVisible") } }
    @Published public var panelLayer: PanelLayer { didSet { d.set(panelLayer.rawValue, forKey: "panelLayer") } }

    public init(defaults: UserDefaults = .standard) {
        d = defaults
        let r = defaults.double(forKey: "refreshInterval")
        refreshInterval = r >= 15 ? r : 45
        favourites = Set(defaults.stringArray(forKey: "favourites") ?? [])
        defaultFilter = GameFilter(rawValue: defaults.string(forKey: "defaultFilter") ?? "") ?? .all
        defaultDay = DefaultDay(rawValue: defaults.string(forKey: "defaultDay") ?? "") ?? .today
        density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .detailed
        showFinal = defaults.object(forKey: "showFinal") as? Bool ?? true
        useDemoData = defaults.bool(forKey: "useDemoData")
        panelVisible = defaults.object(forKey: "panelVisible") as? Bool ?? true
        panelLayer = PanelLayer(rawValue: defaults.string(forKey: "panelLayer") ?? "") ?? .aboveIcons
    }

    /// Horizontal position after the user drags the panel; nil = docked to the right edge.
    /// (The panel always spans the screen's usable height, so only x is remembered.)
    public var panelX: Double? {
        get { d.object(forKey: "panelX") as? Double }
        set { d.set(newValue, forKey: "panelX") }
    }
}
