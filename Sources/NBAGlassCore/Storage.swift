import Foundation

public enum SharedStorage {
    /// Directory used for the score cache. If `NBAGlassAppGroup` is present in Info.plist
    /// (see README) the App Group container is used so the widget can read it; otherwise
    /// ~/Library/Application Support/NBAGlass.
    public static func directory(appGroup: String? = Bundle.main.object(forInfoDictionaryKey: "NBAGlassAppGroup") as? String) -> URL {
        let fm = FileManager.default
        if let group = appGroup, !group.isEmpty,
           let url = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return url
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NBAGlass", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Persists the most recent successful slates (one per day, newest 10 kept).
/// The file is read once and then served from memory; writes happen on a background queue.
/// Not thread-safe: use one instance from one actor (the app uses it on the main actor).
public final class ScoreCache {
    private let url: URL
    private let limit = 10
    private var memory: [String: Slate]?
    private static let writeQueue = DispatchQueue(label: "com.nbaglass.cache-write", qos: .utility)

    /// v2: slates are keyed by the local calendar day (v1 used the US game day).
    public init(directory: URL = SharedStorage.directory(), fileName: String = "scores-cache-v2.json") {
        url = directory.appendingPathComponent(fileName)
    }

    public func load() -> [String: Slate] {
        if let memory { return memory }
        var all: [String: Slate] = [:]
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            all = (try? dec.decode([String: Slate].self, from: data)) ?? [:]
        }
        memory = all
        return all
    }

    public func slate(for key: String) -> Slate? { load()[key] }

    public func save(_ slate: Slate) {
        var all = load()
        all[slate.dayKey] = slate
        if all.count > limit {
            let keep = all.values.sorted { $0.fetchedAt > $1.fetchedAt }.prefix(limit).map(\.dayKey)
            all = all.filter { keep.contains($0.key) }
        }
        memory = all
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(all) else { return }
        let url = self.url
        Self.writeQueue.async { try? data.write(to: url, options: .atomic) }
    }
}
