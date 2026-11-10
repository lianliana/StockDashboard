import MarketCore
import SwiftUI
import WidgetKit

@main
@MainActor
struct StockDashboardApp: App {
    @State private var model = DashboardModel()

    var body: some Scene {
        Window("StockDashboard", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 740, minHeight: 480)
        }
        .defaultSize(width: 940, height: 620)
    }
}

@MainActor
@Observable
final class DashboardModel {
    private(set) var snapshot = WatchlistSnapshot.initial
    private(set) var isRefreshing = false
    private(set) var quoteError = false
    private(set) var storageError = false
    var selection: Instrument.ID?

    let market = TencentMarketData()
    @ObservationIgnored private var quoteRequest: Task<Void, Never>?

    init() {
        do {
            snapshot = try WatchlistStore.load()
        } catch {
            storageError = true
        }
        selection = snapshot.instruments.first?.id
    }

    var selectedInstrument: Instrument? {
        snapshot.instruments.first { $0.id == selection }
    }

    func add(_ instrument: Instrument) {
        if snapshot.instruments.contains(where: { $0.id == instrument.id }) {
            selection = instrument.id
            return
        }
        var updated = snapshot
        updated.instruments.append(instrument)
        if save(updated, reloadWidget: true) {
            selection = instrument.id
            refresh()
        }
    }

    func remove(_ instrument: Instrument) {
        var updated = snapshot
        updated.instruments.removeAll { $0.id == instrument.id }
        updated.mergeQuotes([:])
        if save(updated, reloadWidget: true), selection == instrument.id {
            selection = snapshot.instruments.first?.id
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var updated = snapshot
        updated.instruments.move(fromOffsets: offsets, toOffset: destination)
        _ = save(updated, reloadWidget: true)
    }

    func move(_ instrument: Instrument, by offset: Int) {
        let index = snapshot.instruments.firstIndex(of: instrument)!
        var updated = snapshot
        updated.instruments.swapAt(index, index + offset)
        _ = save(updated, reloadWidget: true)
    }

    func refresh() {
        quoteRequest?.cancel()
        let instruments = snapshot.instruments
        isRefreshing = true
        quoteRequest = Task {
            do {
                let quotes = try await market.quotes(for: instruments)
                try Task.checkCancellation()
                var updated = snapshot
                updated.mergeQuotes(quotes)
                if updated.quotes != snapshot.quotes {
                    _ = save(updated, reloadWidget: false)
                }
                quoteError = !snapshot.instruments.allSatisfy { quotes[$0.id] != nil }
            } catch {
                if Task.isCancelled { return }
                quoteError = !snapshot.instruments.isEmpty
            }
            isRefreshing = false
        }
    }

    private func save(_ updated: WatchlistSnapshot, reloadWidget: Bool) -> Bool {
        do {
            try WatchlistStore.save(updated)
            snapshot = updated
            storageError = false
            if reloadWidget {
                WidgetCenter.shared.reloadTimelines(ofKind: WatchlistStore.widgetKind)
            }
            return true
        } catch {
            storageError = true
            return false
        }
    }
}
