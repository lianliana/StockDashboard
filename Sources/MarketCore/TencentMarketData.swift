import CoreFoundation
import Foundation

public struct TencentMarketData: Sendable {
    private static let chartHost = "proxy.finance.qq.com"
    private static let chartPath = "/ifzqgtimg/appstock/app/"

    public init() {}

    public func search(_ query: String) async throws -> [Instrument] {
        let lookup = SearchQuery(query)
        guard !lookup.text.isEmpty else { return [] }
        let data = try await request("smartbox.gtimg.cn", "/s3/", [
            URLQueryItem(name: "q", value: lookup.text),
            URLQueryItem(name: "t", value: "all"),
            URLQueryItem(name: "c", value: "24"),
        ])
        var results = try searchMatches(in: data)
        if lookup.isBeijingCode, !results.contains(where: { $0.exchange == .beijing }) {
            if let instrument = try await findBeijingInstrument(code: lookup.text) {
                results.insert(instrument, at: 0)
            }
        }
        let suggestions = Instrument.suggested.filter(lookup.matchesSuggestion)
        var seen = Set<Instrument.ID>()
        return (suggestions + results).filter { instrument in
            (lookup.exchange == nil || lookup.exchange == instrument.exchange)
                && seen.insert(instrument.id).inserted
        }
    }

    public func quotes(for instruments: [Instrument]) async throws -> [Instrument.ID: Quote] {
        var quotes: [Instrument.ID: Quote] = [:]
        for offset in stride(from: 0, to: instruments.count, by: 60) {
            let batch = instruments.dropFirst(offset).prefix(60)
            let rows = try await quoteRows(batch.map(\.quoteKey))
            for instrument in batch {
                if let row = rows[instrument.quoteKey], let quote = parseQuote(row, exchange: instrument.exchange) {
                    quotes[instrument.id] = quote
                }
            }
        }
        if quotes.isEmpty, !instruments.isEmpty { throw DataError.unavailable }
        return quotes
    }

    public func history(for instrument: Instrument, range: HistoryRange) async throws -> [PricePoint] {
        let points = if range == .day {
            try await intraday(for: instrument)
        } else {
            try await daily(for: instrument, count: range.tradingDays)
        }
        guard points.count >= 2 else { throw DataError.unavailable }
        return points
    }

    private func searchMatches(in data: Data) throws -> [Instrument] {
        let response = try decodeQuoteText(data)
        guard let start = response.firstIndex(of: "\""), let end = response.lastIndex(of: "\""), start < end else {
            throw DataError.invalidResponse
        }
        let payload = try JSONDecoder().decode(String.self, from: Data(response[start...end].utf8))
        return payload.split(separator: "^").compactMap { match in
            let fields = match.split(separator: "~", omittingEmptySubsequences: false)
            guard fields.count >= 5, let exchange = Exchange(rawValue: String(fields[0])),
                  !fields[1].isEmpty, !fields[2].isEmpty else { return nil }

            let code = String(fields[1])
            let isIndex = fields[4] == "ZS"
            let isStock = exchange == .unitedStates ? fields[4] == "GP" : fields[4] == "GP-A"
            guard isIndex || isStock else { return nil }
            if exchange == .unitedStates, isStock, !code.contains(".") { return nil }

            return Instrument(
                exchange: exchange,
                sourceCode: exchange == .unitedStates && isIndex ? "." + code : code,
                name: String(fields[2]),
                isIndex: isIndex
            )
        }
    }

    private func findBeijingInstrument(code: String) async throws -> Instrument? {
        let key = Exchange.beijing.rawValue + code
        let rows = try await quoteRows([key])
        guard let row = rows[key], row.count > 2, row[2] == code, !row[1].isEmpty else { return nil }
        return Instrument(exchange: .beijing, sourceCode: code, name: String(row[1]), isIndex: code.hasPrefix("899"))
    }

    private func quoteRows(_ keys: [String]) async throws -> [String: [Substring]] {
        let data = try await request("qt.gtimg.cn", "/q=" + keys.joined(separator: ","))
        let text = try decodeQuoteText(data)
        var rows: [String: [Substring]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("v_"), let separator = line.firstIndex(of: "="),
                  let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 2)..<separator])
            rows[key] = line[line.index(after: first)..<last].split(separator: "~", omittingEmptySubsequences: false)
        }
        return rows
    }

    private func parseQuote(_ fields: [Substring], exchange: Exchange) -> Quote? {
        guard fields.count > 34, let price = Double(fields[3]), price.isFinite, price > 0,
              let change = Double(fields[31]), change.isFinite,
              let percent = Double(fields[32]), percent.isFinite else { return nil }
        let format = exchange == .unitedStates ? "yyyy-MM-dd HH:mm:ss" : "yyyyMMddHHmmss"
        guard let time = dateFormatter(format, exchange: exchange).date(from: String(fields[30])) else { return nil }
        return Quote(
            price: price,
            previousClose: Double(fields[4]),
            open: Double(fields[5]),
            high: Double(fields[33]),
            low: Double(fields[34]),
            change: change,
            changePercent: percent,
            time: time
        )
    }

    private func intraday(for instrument: Instrument) async throws -> [PricePoint] {
        let endpoint = instrument.exchange == .unitedStates ? "usMinute" : "minute"
        let data = try await request(Self.chartHost, Self.chartPath + "\(endpoint)/query", [
            URLQueryItem(name: "code", value: instrument.historyKey),
        ])
        let response = try JSONDecoder().decode(ChartResponse<MinutePayload>.self, from: data)
        guard let session = response.data[instrument.historyKey]?.data else { throw DataError.unavailable }
        let formatter = dateFormatter("yyyyMMddHHmm", exchange: instrument.exchange)
        return session.data.compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let price = Double(fields[1]), price.isFinite, price > 0,
                  let time = formatter.date(from: session.date + fields[0]) else { return nil }
            return PricePoint(date: time, price: price)
        }
    }

    private func daily(for instrument: Instrument, count: Int) async throws -> [PricePoint] {
        let endpoint = instrument.exchange == .unitedStates ? "usfqkline" : "fqkline"
        let data = try await request(Self.chartHost, Self.chartPath + "\(endpoint)/get", [
            URLQueryItem(name: "param", value: "\(instrument.historyKey),day,,,\(count),qfq"),
        ])
        let response = try JSONDecoder().decode(ChartResponse<DailyPayload>.self, from: data)
        guard let series = response.data[instrument.historyKey],
              let prices = series.qfqday ?? series.day else { throw DataError.unavailable }
        let formatter = dateFormatter("yyyy-MM-dd", exchange: instrument.exchange)
        return prices.compactMap { point in
            guard let price = Double(point.close), price.isFinite, price > 0,
                  let date = formatter.date(from: point.date) else { return nil }
            return PricePoint(date: date, price: price)
        }
    }

    private func request(_ host: String, _ path: String, _ items: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !items.isEmpty { components.queryItems = items }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("https://finance.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw DataError.unavailable
        }
        return data
    }

    private func decodeQuoteText(_ data: Data) throws -> String {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else {
            throw DataError.invalidResponse
        }
        return text
    }

    private func dateFormatter(_ format: String, exchange: Exchange) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = exchange.timeZone
        formatter.dateFormat = format
        return formatter
    }
}

private extension TencentMarketData {
    enum DataError: Error {
        case unavailable
        case invalidResponse
    }

    struct SearchQuery {
        let text: String
        let exchange: Exchange?

        init(_ input: String) {
            let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = query.suffix(3).uppercased()
            let prefix = query.prefix(2).lowercased()
            let exchanges: [String: Exchange] = [".SH": .shanghai, ".SS": .shanghai, ".SZ": .shenzhen, ".BJ": .beijing]
            if let exchange = exchanges[suffix], query.dropLast(3).count == 6 {
                self.exchange = exchange
                text = String(query.dropLast(3))
            } else if let exchange = Exchange(rawValue: prefix), exchange != .unitedStates,
                      query.count == 8, query.dropFirst(2).allSatisfy(\.isASCII),
                      query.dropFirst(2).allSatisfy(\.isNumber) {
                self.exchange = exchange
                text = String(query.dropFirst(2))
            } else {
                exchange = nil
                text = query.hasPrefix("^") ? String(query.dropFirst()) : query
            }
        }

        var isBeijingCode: Bool {
            text.count == 6 && text.allSatisfy(\.isNumber) && (exchange == .beijing || text.hasPrefix("92") || text.hasPrefix("899"))
        }

        func matchesSuggestion(_ instrument: Instrument) -> Bool {
            let search = text.filter { !$0.isWhitespace }
            guard !search.isEmpty else { return false }
            return instrument.symbol.localizedCaseInsensitiveContains(search)
                || instrument.name.filter { !$0.isWhitespace }.localizedCaseInsensitiveContains(search)
        }
    }

    struct ChartResponse<Payload: Decodable>: Decodable {
        let data: [String: Payload]
    }

    struct MinutePayload: Decodable {
        struct Session: Decodable {
            let date: String
            let data: [String]
        }

        let data: Session
    }

    struct DailyPayload: Decodable {
        let day: [DailyPoint]?
        let qfqday: [DailyPoint]?
    }

    struct DailyPoint: Decodable {
        let date: String
        let close: String

        init(from decoder: Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            date = try fields.decode(String.self)
            _ = try fields.decode(String.self)
            close = try fields.decode(String.self)
        }
    }
}
