import MarketCore
import SwiftUI
import WidgetKit

@main
struct StockDashboardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchlistStore.widgetKind, provider: WatchlistProvider()) { entry in
            WatchlistWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("自选行情")
        .description("查看 StockDashboard 自选列表中的指数、股票和上海金。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct WatchlistEntry: TimelineEntry {
    let date = Date()
    let snapshot: WatchlistSnapshot?
}

private struct WatchlistProvider: TimelineProvider {
    private static let cacheKey = "lastQuotes"
    private let market = MarketData()

    func placeholder(in context: Context) -> WatchlistEntry {
        WatchlistEntry(snapshot: .initial)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchlistEntry) -> Void) {
        completion(WatchlistEntry(snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchlistEntry>) -> Void) {
        let instruments = (try? WatchlistStore.load())?.instruments.prefix(context.family.visibleRows) ?? []
        Task { @MainActor in
            let quotes = try? await market.quotes(for: Array(instruments))
            var snapshot = loadSnapshot()
            if let quotes {
                snapshot?.mergeQuotes(quotes)
            }
            if let snapshot, let cache = try? JSONEncoder().encode(snapshot.quotes) {
                UserDefaults.standard.set(cache, forKey: Self.cacheKey)
            }
            let nextRefresh = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [WatchlistEntry(snapshot: snapshot)], policy: .after(nextRefresh)))
        }
    }

    private func loadSnapshot() -> WatchlistSnapshot? {
        guard var snapshot = try? WatchlistStore.load() else { return nil }
        if let cache = UserDefaults.standard.data(forKey: Self.cacheKey),
           let quotes = try? JSONDecoder().decode([Instrument.ID: Quote].self, from: cache) {
            snapshot.mergeQuotes(quotes)
        }
        return snapshot
    }
}

private struct WatchlistWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchlistEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("自选行情", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let snapshot = entry.snapshot {
                if snapshot.instruments.isEmpty {
                    message("在 StockDashboard 中添加自选")
                } else {
                    watchlist(snapshot)
                }
            } else {
                message("暂时无法读取自选")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func watchlist(_ snapshot: WatchlistSnapshot) -> some View {
        let visible = snapshot.instruments.prefix(family.visibleRows)
        let latest = visible.compactMap { snapshot.quotes[$0.id]?.time }.max()
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 7 : 4) {
            ForEach(visible) { instrument in
                row(instrument, quote: snapshot.quotes[instrument.id])
            }
            Spacer(minLength: 0)
            if let latest {
                Text("报价 \(latest.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text("等待行情")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ instrument: Instrument, quote: Quote?) -> some View {
        HStack(spacing: 7) {
            if family == .systemSmall {
                Text(instrument.exchange == .unitedStates ? instrument.symbol : instrument.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 1)
            } else {
                Text(instrument.symbol)
                    .font(.callout.weight(.semibold))
                    .fixedSize()
                Text(instrument.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 1)
                Text((quote?.priceText ?? "—") + (instrument.exchange == .shanghaiGold ? " 元/克" : ""))
                    .font(.callout.monospacedDigit())
                    .fixedSize()
            }
            if let quote {
                let color = instrument.changeColor(quote.changePercent)
                Text(family == .systemSmall && instrument.exchange == .shanghaiGold
                     ? quote.priceText + " 元/克" : quote.percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .widgetAccentable()
            } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .help(quote.map { "\(instrument.name) · 报价于 \($0.time.formatted(date: .abbreviated, time: .standard))" }
              ?? instrument.name)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension WidgetFamily {
    var visibleRows: Int {
        switch self {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 10
        }
    }
}
