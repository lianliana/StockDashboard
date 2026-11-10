import Foundation
import SwiftUI

public enum Exchange: String, Codable, Sendable {
    case shanghai = "sh"
    case shenzhen = "sz"
    case beijing = "bj"
    case unitedStates = "us"
    case shanghaiGold = "sge"

    public var name: String {
        switch self {
        case .shanghai: "上海"
        case .shenzhen: "深圳"
        case .beijing: "北京"
        case .unitedStates: "美国"
        case .shanghaiGold: "上海黄金交易所"
        }
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: self == .unitedStates ? "America/New_York" : "Asia/Shanghai")!
    }
}

public struct Instrument: Codable, Hashable, Identifiable, Sendable {
    public let exchange: Exchange
    public let sourceCode: String
    public let name: String
    public let isIndex: Bool

    init(exchange: Exchange, sourceCode: String, name: String, isIndex: Bool = false) {
        self.exchange = exchange
        self.sourceCode = sourceCode.uppercased()
        self.name = name
        self.isIndex = isIndex
    }

    public var id: String { quoteKey }

    public var symbol: String {
        if exchange == .shanghaiGold { return "Au99.99" }
        guard exchange == .unitedStates else { return sourceCode }
        if isIndex { return String(sourceCode.dropFirst()) }
        return String(sourceCode[..<sourceCode.lastIndex(of: ".")!])
    }

    var quoteKey: String {
        exchange.rawValue + (exchange == .unitedStates && !isIndex ? symbol : sourceCode)
    }

    var historyKey: String { exchange.rawValue + sourceCode }

    public var unit: String {
        if exchange == .shanghaiGold { return "元/克" }
        if isIndex { return "点" }
        return exchange == .unitedStates ? "USD" : "CNY"
    }

    public var category: String {
        if exchange == .shanghaiGold { return "上海黄金交易所现货" }
        if isIndex { return "\(exchange.name)指数" }
        return exchange == .unitedStates ? "美股" : "\(exchange.name) A 股"
    }

    public var quoteSource: String {
        exchange == .shanghaiGold ? "新浪财经" : "腾讯行情"
    }

    public func changeColor(_ change: Double) -> Color {
        if change == 0 { return .secondary }
        return (exchange == .unitedStates ? change > 0 : change < 0) ? .green : .red
    }

    public static let suggested: [Self] = [
        .init(exchange: .unitedStates, sourceCode: ".IXIC", name: "纳斯达克综合", isIndex: true),
        .init(exchange: .unitedStates, sourceCode: ".NDX", name: "纳斯达克 100", isIndex: true),
        .init(exchange: .shanghai, sourceCode: "000001", name: "上证指数", isIndex: true),
        .init(exchange: .shanghai, sourceCode: "600519", name: "贵州茅台"),
        .init(exchange: .unitedStates, sourceCode: "AAPL.OQ", name: "苹果"),
        .init(exchange: .unitedStates, sourceCode: "NVDA.OQ", name: "英伟达"),
        .init(exchange: .shenzhen, sourceCode: "399001", name: "深证成指", isIndex: true),
        .init(exchange: .shenzhen, sourceCode: "399006", name: "创业板指", isIndex: true),
        .init(exchange: .shanghai, sourceCode: "000300", name: "沪深 300", isIndex: true),
        .init(exchange: .shanghaiGold, sourceCode: "AU9999", name: "上海金"),
    ]
}

public struct Quote: Codable, Equatable, Sendable {
    public let price: Double
    public let previousClose: Double?
    public let open: Double?
    public let high: Double?
    public let low: Double?
    public let change: Double
    public let changePercent: Double
    public let time: Date

    public var priceText: String { Self.formatPrice(price) }
    public var changeText: String { Self.signed(change) }
    public var percentText: String { Self.signed(changePercent) + "%" }

    public static func formatPrice(_ price: Double?) -> String {
        price?.formatted(.number.precision(.fractionLength(2))) ?? "—"
    }

    private static func signed(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
    }
}

public enum HistoryRange: String, CaseIterable, Sendable {
    case day = "1 日"
    case week = "1 周"
    case month = "1 月"
    case quarter = "3 月"
    case year = "1 年"

    var tradingDays: Int {
        switch self {
        case .day: 1
        case .week: 5
        case .month: 22
        case .quarter: 66
        case .year: 252
        }
    }
}

public struct PricePoint: Identifiable, Sendable {
    public let date: Date
    public let price: Double
    public var id: Date { date }
}
