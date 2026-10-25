import AppKit
import SwiftUI
import CoreImage
import ImageIO
import NBAGlassCore

/// Team and league logos from ESPN's public CDN, downloaded on demand and cached in
/// ~/Library/Application Support/NBAGlass/Logos. Nothing is bundled with the app; when an image
/// can't be fetched, callers fall back to the team abbreviation.
///
/// Each logo is decoded once, off the main thread, into two small bitmaps: a crisp foreground
/// size and a pre-blurred watermark — so drawing never resamples the 500px source or runs a
/// blur filter. Loads that finish together are published as a single update.
@MainActor
final class LogoStore: ObservableObject {
    static let shared = LogoStore()

    struct Logo {
        let icon: NSImage
        let watermark: NSImage
    }

    @Published private(set) var logos: [String: Logo] = [:]
    private var pending: [String: Logo] = [:]
    private var inFlight = Set<String>()
    private var failedAt: [String: Date] = [:]
    private let directory: URL

    private init() {
        directory = SharedStorage.directory().appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let leagueKey = "league-nba"
    /// Pixel sizes: icons are drawn at ≤34pt and watermarks at 86pt on 2x displays.
    nonisolated private static let iconPixels = 72, watermarkPixels = 176

    /// Returns the cached logo, starting a load if it isn't available yet.
    func logo(_ key: String, url: URL) -> Logo? {
        if let l = logos[key] { return l }
        load(key, url: url)
        return nil
    }

    func team(_ abbreviation: String) -> Logo? {
        logo(abbreviation.lowercased(), url: TeamLogos.url(for: abbreviation))
    }

    func prefetchAll() {
        _ = logo(Self.leagueKey, url: TeamLogos.league)
        for team in NBATeams.all { _ = self.team(team.abbr) }
    }

    private func load(_ key: String, url: URL) {
        guard !inFlight.contains(key) else { return }
        if let t = failedAt[key], Date().timeIntervalSince(t) < 300 { return }   // retry failures after 5 min
        inFlight.insert(key)
        let file = directory.appendingPathComponent("\(key).png")
        Task {
            defer { inFlight.remove(key) }
            var data = try? Data(contentsOf: file)
            if data == nil, let (d, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                try? d.write(to: file, options: .atomic)
                data = d
            }
            guard let data, let images = await Self.decode(data) else { failedAt[key] = Date(); return }
            publish(key, Logo(icon: NSImage(cgImage: images.icon, size: .zero),
                              watermark: NSImage(cgImage: images.watermark, size: .zero)))
        }
    }

    private func publish(_ key: String, _ logo: Logo) {
        let first = pending.isEmpty
        pending[key] = logo
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logos.merge(self.pending) { _, new in new }
            self.pending = [:]
        }
    }

    private struct Decoded: @unchecked Sendable { let icon: CGImage; let watermark: CGImage }
    nonisolated(unsafe) private static let ciContext = CIContext(options: [.cacheIntermediates: false])   // CIContext is thread-safe

    /// Downsamples once and pre-blurs the watermark copy, off the main actor.
    private nonisolated static func decode(_ data: Data) async -> Decoded? {
        await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let icon = thumbnail(src, iconPixels),
                  let large = thumbnail(src, watermarkPixels) else { return nil }
            let input = CIImage(cgImage: large)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 2.0).cropped(to: input.extent)
            let watermark = ciContext.createCGImage(blurred, from: input.extent) ?? large
            return Decoded(icon: icon, watermark: watermark)
        }.value
    }

    private nonisolated static func thumbnail(_ src: CGImageSource, _ pixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

/// A team logo at a given size, or a quiet abbreviation chip when no image is available.
struct TeamLogo: View {
    @EnvironmentObject var logos: LogoStore
    let abbreviation: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let img = logos.team(abbreviation)?.icon {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Text(abbreviation.prefix(3))
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(abbreviation)
    }
}

struct LeagueLogo: View {
    @EnvironmentObject var logos: LogoStore
    var height: CGFloat = 22
    var body: some View {
        if let img = logos.logo(LogoStore.leagueKey, url: TeamLogos.league)?.icon {
            // The CDN image is a square canvas around the portrait mark; crop the side padding.
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: height, height: height).frame(width: height * 0.48).clipped()
                .accessibilityLabel("NBA")
        } else {
            Text("NBA").font(.system(size: 11, weight: .heavy)).tracking(0.5).foregroundStyle(Theme.textPrimary)
        }
    }
}
