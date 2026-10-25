import SwiftUI
import NBAGlassCore

struct SettingsView: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var store: ScoreboardStore
    var onResetPosition: () -> Void = {}

    var body: some View {
        Form {
            Section("Panel") {
                Toggle("Show scoreboard on desktop", isOn: $prefs.panelVisible)
                Picker("Desktop layer", selection: $prefs.panelLayer) {
                    ForEach(PanelLayer.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(prefs.panelLayer == .aboveIcons
                     ? "Sits on the desktop behind all app windows, above desktop icons. Clickable."
                     : "Sits under desktop icons. Clicks may go to the desktop instead of the panel.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Position") { Button("Dock to Right Edge", action: onResetPosition) }
                Picker("Rows", selection: $prefs.density) {
                    ForEach(Density.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Show final games", isOn: $prefs.showFinal)
            }
            Section("Defaults") {
                Picker("Filter", selection: $prefs.defaultFilter) {
                    ForEach(GameFilter.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Date at launch", selection: $prefs.defaultDay) {
                    ForEach(DefaultDay.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Refresh") {
                Picker("Interval", selection: $prefs.refreshInterval) {
                    ForEach([20.0, 30, 45, 60, 120, 300], id: \.self) { s in
                        Text(s < 60 ? "\(Int(s)) seconds" : "\(Int(s / 60)) min").tag(s)
                    }
                }
                Text("Refreshes slow to every 3 minutes when nothing is live, and back off after failures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                Toggle("Use demo data (not live)", isOn: $prefs.useDemoData)
                LabeledContent("Source", value: prefs.useDemoData ? "Demo" : "ESPN public scoreboard (unofficial)")
                LabeledContent("Time zone", value: TimeZone.current.identifier)
                LabeledContent("Logos", value: "ESPN CDN, cached locally")
            }
            Section("Favourite teams") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(NBATeams.all, id: \.abbr) { team in
                        Toggle(team.name, isOn: Binding(
                            get: { prefs.favourites.contains(team.abbr) },
                            set: { on in if on { prefs.favourites.insert(team.abbr) } else { prefs.favourites.remove(team.abbr) } }))
                            .toggleStyle(.checkbox).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .preferredColorScheme(.dark)
    }
}
