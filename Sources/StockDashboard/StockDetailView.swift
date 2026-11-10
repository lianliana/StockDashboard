import Charts
import MarketCore
import SwiftUI

@MainActor
struct StockDetailView: View {
    let instrument: Instrument
    let quote: Quote?
    let market: MarketData

    @State private var request = HistoryRequest()
    @State private var chart = ChartState.loading
    @State private var selectedDate: Date?

    private var range: HistoryRange { request.range }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                quoteHeader
                Divider()
                chartSection
                Divider()
                quoteStatistics
                Text("报价来源 \(instrument.quoteSource) · 报价可能有延迟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if instrument.exchange == .shanghaiGold {
                    Text("走势来源 上海黄金交易所 · 每 60 秒刷新报价，休市时显示最近成交价")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(26)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: request) { await loadHistory(request.range) }
        .onChange(of: quote?.time) {
            if range == .day { request.revision += 1 }
        }
    }

    private var quoteHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(instrument.symbol)
                    .font(.system(size: 27, weight: .bold))
                Text(instrument.name)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text(instrument.category)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(quote?.priceText ?? "—")
                    .font(.system(size: 43, weight: .semibold))
                Text(instrument.unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let quote {
                    Text("\(quote.changeText) (\(quote.percentText))")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(instrument.changeColor(quote.changePercent))
                }
            }
            .monospacedDigit()
            if let quote {
                Text("报价于 \(quote.time.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("走势").font(.headline)
                if range == .day {
                    Text(instrument.exchange == .unitedStates ? "美东时间" : "北京时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("走势图周期", selection: $request.range) {
                    ForEach(HistoryRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 238)
            }
            Group {
                switch chart {
                case .loading:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .points(let points):
                    priceChart(points)
                case .failed:
                    ContentUnavailableView {
                        Label("走势暂不可用", systemImage: "chart.xyaxis.line")
                    } actions: {
                        Button("重试") { request.revision += 1 }
                            .controlSize(.small)
                    }
                }
            }
            .frame(height: 228)
        }
    }

    private func priceChart(_ points: [PricePoint]) -> some View {
        let prices = points.map(\.price)
        let low = prices.min()!
        let high = prices.max()!
        let inset = max((high - low) * 0.08, high * 0.001)
        let baseline = low - inset
        let periodChange = prices.last! - prices.first!
        let color = instrument.changeColor(range == .day ? quote?.change ?? periodChange : periodChange)
        let selected = selectedDate.flatMap { date in
            points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        let format = chartDateFormat

        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("时间", point.date),
                         yStart: .value("基准", baseline),
                         yEnd: .value("价格", point.price))
                    .foregroundStyle(.linearGradient(colors: [color.opacity(0.24), color.opacity(0.015)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", point.date), y: .value("价格", point.price))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.7))
            }
            if let selected {
                RuleMark(x: .value("时间", selected.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(Quote.formatPrice(selected.price))
                            .font(.caption.monospacedDigit())
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                PointMark(x: .value("时间", selected.date), y: .value("价格", selected.price))
                    .foregroundStyle(color)
            }
        }
        .chartYScale(domain: baseline...(high + inset))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisValueLabel(format: format)
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("\(instrument.name)走势")
    }

    private var chartDateFormat: Date.FormatStyle {
        var format = range == .day ? Date.FormatStyle().hour().minute() : .dateTime.month().day()
        format.timeZone = instrument.exchange.timeZone
        return format
    }

    private var quoteStatistics: some View {
        Grid(horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                statistic("今开", quote?.open)
                statistic("昨收", quote?.previousClose)
                statistic("最高", quote?.high)
                statistic("最低", quote?.low)
            }
        }
    }

    private func statistic(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Quote.formatPrice(value)).font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadHistory(_ requestedRange: HistoryRange) async {
        chart = .loading
        selectedDate = nil
        do {
            let points = try await market.history(for: instrument, range: requestedRange)
            try Task.checkCancellation()
            if range == requestedRange { chart = .points(points) }
        } catch {
            if !Task.isCancelled, range == requestedRange { chart = .failed }
        }
    }

    private enum ChartState {
        case loading
        case points([PricePoint])
        case failed
    }

    private struct HistoryRequest: Equatable {
        var range = HistoryRange.day
        var revision = 0
    }
}
