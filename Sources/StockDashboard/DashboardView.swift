import MarketCore
import SwiftUI

@MainActor
struct DashboardView: View {
    let model: DashboardModel

    var body: some View {
        NavigationSplitView {
            WatchlistSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 245, ideal: 270, max: 350)
        } detail: {
            if let instrument = model.selectedInstrument {
                StockDetailView(
                    instrument: instrument,
                    quote: model.snapshot.quotes[instrument.id],
                    market: model.market
                )
                .id(instrument.id)
            } else {
                ContentUnavailableView("选择一个标的", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("从左侧自选列表选择，或搜索名称和代码。"))
            }
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }
}

@MainActor
private struct WatchlistSidebar: View {
    let model: DashboardModel

    @State private var query = ""
    @State private var search: SearchState = .idle
    @FocusState private var searchFocused: Bool

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            if searchText.isEmpty {
                watchlist
            } else {
                searchResults
            }
            Divider()
            footer
        }
        .task(id: searchText) { await findInstruments(searchText) }
    }

    private var header: some View {
        HStack {
            Text("自选")
                .font(.system(size: 25, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                searchFocused = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 17))
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .help("添加自选（⌘F）")
            .accessibilityLabel("添加自选")
            Menu {
                if let instrument = model.selectedInstrument {
                    editMenu(for: instrument)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .imageScale(.large)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .disabled(model.selectedInstrument == nil)
            .help("调整当前选中的自选标的")
            .accessibilityLabel("调整自选")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索名称或代码", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    private var watchlist: some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            ForEach(model.snapshot.instruments) { instrument in
                WatchlistRow(instrument: instrument, quote: model.snapshot.quotes[instrument.id])
                    .tag(instrument.id)
                    .contextMenu { editMenu(for: instrument) }
            }
            .onMove { offsets, destination in
                model.move(from: offsets, to: destination)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.snapshot.instruments.isEmpty {
                ContentUnavailableView("自选列表为空", systemImage: "star",
                                       description: Text("搜索名称或代码来添加。"))
            }
        }
    }

    private func editMenu(for instrument: Instrument) -> some View {
        Group {
            Button("上移") { model.move(instrument, by: -1) }
                .disabled(model.snapshot.instruments.first == instrument)
            Button("下移") { model.move(instrument, by: 1) }
                .disabled(model.snapshot.instruments.last == instrument)
            Divider()
            Button("移除自选", role: .destructive) { model.remove(instrument) }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch search {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results(let instruments):
            if instruments.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                List(instruments) { instrument in
                    Button {
                        model.add(instrument)
                        if !model.storageError {
                            query = ""
                            searchFocused = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(instrument.symbol).fontWeight(.semibold)
                                Text(instrument.name + " · " + instrument.category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: model.snapshot.instruments.contains { $0.id == instrument.id }
                                  ? "checkmark.circle" : "plus.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("添加 \(instrument.name) 到自选")
                }
                .listStyle(.sidebar)
            }
        case .failed:
            ContentUnavailableView("搜索失败", systemImage: "wifi.exclamationmark",
                                   description: Text("检查网络后重新搜索。"))
                .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.storageError {
                Label("自选存储不可用", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if model.quoteError {
                Label("部分行情暂不可用", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.snapshot.instruments.count) 个标的")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新行情")
            .accessibilityLabel("刷新行情")
        }
        .font(.caption)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    private func findInstruments(_ text: String) async {
        guard !text.isEmpty else {
            search = .idle
            return
        }
        search = .loading
        do {
            try await Task.sleep(for: .milliseconds(250))
            let matches = try await model.market.search(text)
            try Task.checkCancellation()
            search = .results(matches)
        } catch {
            if !Task.isCancelled { search = .failed }
        }
    }

    private enum SearchState {
        case idle
        case loading
        case results([Instrument])
        case failed
    }
}

private struct WatchlistRow: View {
    let instrument: Instrument
    let quote: Quote?

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(instrument.symbol)
                    .fontWeight(.semibold)
                Text(instrument.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(quote?.priceText ?? "—")
                    .fontWeight(.medium)
                if let quote {
                    let color = instrument.changeColor(quote.changePercent)
                    Text(quote.percentText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
