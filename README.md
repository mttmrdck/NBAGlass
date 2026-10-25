# NBAGlass

A translucent NBA scoreboard that lives on the macOS desktop: one vertical glass panel on the right edge of the primary display, sitting behind your app windows like part of the wallpaper, with a menu-bar control and (optionally) a WidgetKit widget.

## Prerequisites
- macOS 14+ (developed on macOS 26.6, Apple Silicon)
- Swift 6.1 toolchain (Xcode **or** Command Line Tools) — the app, core library and tests need only the Command Line Tools
- Full Xcode — **only** for the optional widget extension

## Build & launch
```sh
./scripts/bundle.sh        # builds release, creates build/NBAGlass.app (ad-hoc signed)
open build/NBAGlass.app
swift test                 # Swift Testing unit tests
```
The app is a menu-bar agent (no Dock icon). Menu-bar basketball icon: Show/Hide Scoreboard, Dock to Right Edge, Refresh Scores, Settings…, Quit. The panel's own `…` menu offers Today, Dock to Right Edge, Hide Scoreboard and Quit.
Deep links: `open -g nbaglass://game/<espn-game-id>` selects/expands a game; `open nbaglass://settings` opens Settings.

## Project structure
```
Package.swift
Sources/NBAGlassCore/   models, provider protocol + ESPN/demo providers, cache, preferences, ScoreboardStore
Sources/NBAGlass/       AppKit shell (NSPanel, status item, settings window) + SwiftUI views
Tests/NBAGlassCoreTests parsing, status normalisation, cache, date keys
Widget/                 WidgetKit extension source (needs Xcode — see below)
scripts/bundle.sh       .app packaging
```

## Data provider
`ESPNProvider` uses ESPN's **unofficial, undocumented** public scoreboard JSON (`site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=YYYYMMDD`). No key is needed. It is isolated behind the `ScoreboardProvider` protocol, decodes leniently, and failures fall back to the cache with a visible "Cached/Offline" label. It may change or vanish at any time and is intended for personal use; keep the polling interval reasonable.
(`cdn.nba.com` was tested and returns 403 without browser credentials, so it is not used.)
Settings → "Use demo data" switches to a clearly labelled **DEMO** provider.
To add a keyed provider, implement `ScoreboardProvider` and read the key from the environment/Keychain — never from source.

Dates: the selected day is your Mac's local calendar day (e.g. Asia/Kuala_Lumpur). ESPN's `dates` parameter is the US/Eastern game day, so the provider fetches every US game day overlapping your local day (two for Malaysia) and keeps only games that tip off within it. Tip-off times are shown in local time.

## Desktop layer (window behaviour)
`DesktopPanel` is a borderless, non-activating `NSPanel` at window level **desktop-icon + 1** (`CGWindowLevelForKey(.desktopIconWindow) + 1`), with `[.canJoinAllSpaces, .stationary, .ignoresCycle]`:
- every normal app window (level 0) covers it; it is never raised above them and never takes focus;
- `.stationary` keeps it in place during Show Desktop / Mission Control; it is on every Space;
- it is above Finder's desktop-icon layer, so it stays clickable — and therefore covers any desktop icons under it.
Settings → *Desktop layer* → "Behind desktop icons" uses desktop level + 1 instead: icons draw over it, but Finder's desktop window is then expected to receive the clicks, making the panel display-only (not verified: click delivery was not tested on this machine).
Height follows the content (header + games + bottom strip), capped at the screen's usable height; it scrolls beyond that. Dragging the header moves it horizontally only.

## Design notes
- Liquid Glass: this machine has only the Command Line Tools with the macOS 15.5 SDK, which has no `glassEffect`. The panel is a **native-material fallback**, not Liquid Glass: `NSVisualEffectView` (`.hudWindow`, behind-window blur) under navy→charcoal tints, a top reflection and a fine blue-grey edge. Swap `GlassBackground` for `glassEffect` once built with the macOS 26 SDK (full Xcode 26).
- Matchup strips (`MatchupStrip.swift`): away region | smoked centre parallelogram | home region, split by angled separators lit in each team's accent colour; regions are tinted with the provider's team colours (`TeamPalette`), with oversized logo watermarks at 13% opacity.
- Logos: the NBA logo and all 30 team logos are fetched from ESPN's public CDN (`a.espncdn.com/i/teamlogos/nba/500-dark/<abbr>.png`, the dark-background set) on first run and cached in `~/Library/Application Support/NBAGlass/Logos`. They are trademarks of the NBA and its teams; they are **not** bundled into the repo or app. If a logo can't be fetched, a small abbreviation chip is shown instead.
- Score animation: `ScoreChangeTracker` (Core) compares consecutive **network** results for the same day by game ID + team ID. Only real increases produce `ScoringEvent`s; the first result for a day, cached data, date/filter changes, failures, decreases and missing scores never do. Each event bumps a per-team token in `ScoringPulses`; `AnimatedScore` (numeric digit roll + spring pulse) and `ScoringBurst` (team-coloured bloom + highlight sweep, ~0.75 s) play on token changes only, so view rebuilds never replay them. With Reduce Motion on, digits cross-fade and only the glow plays.

## Performance
NBAGlass is meant to sit idle. Nothing animates between real events (no repeating animations, display links or timers besides the poll), and:
- **Polling** runs only while the panel is shown *and* at least partly visible (`NSWindow.occlusionState`); fully covered by app windows it fetches and redraws nothing, then catches up on reveal only if its data is stale. Intervals: your setting (default 45 s) while games are live, 3 min today with nothing live, 15 min future days, 30 min past days; doubled per failure.
- **Updates**: background polls don't toggle the loading state, and published values change only when the data differs, so an unchanged poll publishes just the timestamp. Rows are `Equatable` and take plain values, so a score change re-renders only that game's row.
- **Cache**: read from disk once, served from memory, written on a background queue.
- **Logos**: decoded once off the main thread into a 72 px icon and a pre-blurred 176 px watermark; no per-draw resampling or blur filters.
- **Drawing**: no software shadows on large layers, no full-panel blur filter or scroll-view mask; the scoring bloom/sweep layers exist only during a celebration.
Diagnostics: `log stream --level debug --predicate 'subsystem == "com.nbaglass.app"'` shows visibility changes, refresh callers, fetches and scoring events.

## App Group & Widget (manual, needs Xcode + an Apple developer team)
The app/widget share `scores-cache-v2.json`. By default it lives in `~/Library/Application Support/NBAGlass`, which a sandboxed widget cannot read, so:
1. Open Xcode → File ▸ New ▸ Project ▸ macOS App named `NBAGlass`; delete the template sources, add `Sources/NBAGlass/*` and the local package `NBAGlassCore` (Add Package Dependencies ▸ Add Local… ▸ this folder).
2. File ▸ New ▸ Target ▸ Widget Extension `NBAGlassWidget` (uncheck Live Activity/Configuration Intent). Replace its generated Swift file with `Widget/NBAGlassWidget.swift` and link `NBAGlassCore`.
3. In *Signing & Capabilities* for **both** targets add **App Groups** with the same id, e.g. `group.<your-team-id>.nbaglass`.
4. Add the Info.plist key `NBAGlassAppGroup` = that id to the **app** and the **widget** (so `SharedStorage` uses the container).
5. Register URL scheme `nbaglass` in the app target (URL Types) for the deep link `nbaglass://game/<id>`.
6. Run the app once, then right-click the desktop ▸ Edit Widgets ▸ "NBA Scores".
`APP_GROUP=group.xxx ./scripts/bundle.sh` sets the key for the SwiftPM build too, but a group container needs a signed provisioning profile.

## Known limitations
- Widget not built or run here (no full Xcode); its source type-checks against the SDK only. Widgets refresh on WidgetKit's budget (minutes), not live.
- No Xcode project is checked in; SwiftPM + `bundle.sh` is the build path.
- Per-game stats beyond period scores, venue and broadcast are not shown (the provider's scoreboard feed lacks them).
- Show Desktop could not be triggered programmatically here (posted F11 and `Mission Control 1` had no effect), so "visible after Show Desktop" follows from the window level/`.stationary` design but was not observed directly.
- Stage Manager was not tested.
- Only the primary display is used.
