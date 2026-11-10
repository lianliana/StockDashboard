import Foundation

public struct WatchlistSnapshot: Codable, Sendable {
    public var instruments: [Instrument]
    public private(set) var quotes: [Instrument.ID: Quote]

    public static let initial = Self(instruments: Array(Instrument.suggested.prefix(6)), quotes: [:])

    public mutating func mergeQuotes(_ newQuotes: [Instrument.ID: Quote]) {
        quotes = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            let id = instrument.id
            let latest = [newQuotes[id], quotes[id]].compactMap { $0 }.max { $0.time < $1.time }
            return latest.map { (id, $0) }
        })
    }
}

public enum WatchlistStore {
    public static let widgetKind = "StockDashboardWatchlist"
    private static let group = "group.com.lianliana.stockdashboard"

    public static func load() throws -> WatchlistSnapshot {
        let file = try snapshotFile()
        do {
            return try JSONDecoder().decode(WatchlistSnapshot.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return .initial
        }
    }

    public static func save(_ snapshot: WatchlistSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: snapshotFile(), options: .atomic)
    }

    private static func snapshotFile() throws -> URL {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return folder.appendingPathComponent("watchlist.json")
    }
}
