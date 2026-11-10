import CoreFoundation
import Foundation

public struct MarketData: Sendable {
    private static let chartHost = "proxy.finance.qq.com"
    private static let chartPath = "/ifzqgtimg/appstock/app/"

    public init() {}

    public func search(_ query: String) async throws -> [Instrument] {
        let lookup = SearchQuery(query)
        guard !lookup.text.isEmpty else { return [] }
        let suggestions = Instrument.suggested.filter(lookup.matchesSuggestion)
        var results: [Instrument]
        do {
            let data = try await request("smartbox.gtimg.cn", "/s3/", [
                URLQueryItem(name: "q", value: lookup.text),
                URLQueryItem(name: "t", value: "all"),
                URLQueryItem(name: "c", value: "24"),
            ])
            results = try searchMatches(in: data)
            if lookup.isBeijingCode, !results.contains(where: { $0.exchange == .beijing }) {
                if let instrument = try await findBeijingInstrument(code: lookup.text) {
                    results.insert(instrument, at: 0)
                }
            }
        } catch {
            guard !suggestions.isEmpty else { throw error }
            results = []
        }
        try Task.checkCancellation()
        var seen = Set<Instrument.ID>()
        return (suggestions + results).filter { instrument in
            (lookup.exchange == nil || lookup.exchange == instrument.exchange)
                && seen.insert(instrument.id).inserted
        }
    }

    public func quotes(for instruments: [Instrument]) async throws -> [Instrument.ID: Quote] {
        async let stockResult = try? stockQuotes(for: instruments.filter { $0.exchange != .shanghaiGold })
        async let goldResult = try? goldQuotes(for: instruments.filter { $0.exchange == .shanghaiGold })
        let (stocks, gold) = await (stockResult, goldResult)
        try Task.checkCancellation()
        let quotes = (stocks ?? [:]).merging(gold ?? [:]) { _, newer in newer }
        if quotes.isEmpty, !instruments.isEmpty { throw DataError.unavailable }
        return quotes
    }

    public func history(for instrument: Instrument, range: HistoryRange) async throws -> [PricePoint] {
        let points: [PricePoint]
        if instrument.exchange == .shanghaiGold {
            points = try await goldHistory(for: instrument, range: range)
        } else if range == .day {
            points = try await intraday(for: instrument)
        } else {
            points = try await daily(for: instrument, count: range.tradingDays)
        }
        guard points.count >= 2 else { throw DataError.unavailable }
        return points
    }

    private func stockQuotes(for instruments: [Instrument]) async throws -> [Instrument.ID: Quote] {
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
        return quotes
    }

    private func goldQuotes(for instruments: [Instrument]) async throws -> [Instrument.ID: Quote] {
        var quotes: [Instrument.ID: Quote] = [:]
        for instrument in instruments {
            let data = try await request("hq.sinajs.cn", "/list=gds_" + instrument.sourceCode,
                                         referer: "https://finance.sina.com.cn/")
            let text = try decodeQuoteText(data)
            guard let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last else {
                throw DataError.invalidResponse
            }
            let fields = text[text.index(after: first)..<last].split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 12, let price = Double(fields[0]), price.isFinite, price > 0,
                  let previousClose = Double(fields[7]), previousClose.isFinite, previousClose > 0,
                  let time = dateFormatter("yyyy-MM-dd HH:mm:ss", exchange: instrument.exchange)
                    .date(from: fields[12] + " " + fields[6]) else { throw DataError.invalidResponse }
            let change = price - previousClose
            quotes[instrument.id] = Quote(
                price: price,
                previousClose: previousClose,
                open: Double(fields[8]),
                high: Double(fields[4]),
                low: Double(fields[5]),
                change: change,
                changePercent: change / previousClose * 100,
                time: time
            )
        }
        return quotes
    }

    private func goldHistory(for instrument: Instrument, range: HistoryRange) async throws -> [PricePoint] {
        let items = [URLQueryItem(name: "instid", value: instrument.symbol)]
        let dailyData = try await request("www.sge.com.cn", "/graph/Dailyhq", items, referer: "https://www.sge.com.cn/")
        let daily = try JSONDecoder().decode(GoldDailyPayload.self, from: dailyData)
        let formatter = dateFormatter("yyyy-MM-dd", exchange: instrument.exchange)
        let history = daily.time.compactMap { point -> PricePoint? in
            guard let date = formatter.date(from: point.date), point.close.isFinite, point.close > 0 else { return nil }
            return PricePoint(date: date, price: point.close)
        }
        if range != .day { return Array(history.suffix(range.tradingDays)) }

        let minuteData = try await request("www.sge.com.cn", "/graph/quotations", items, referer: "https://www.sge.com.cn/")
        let minute = try JSONDecoder().decode(GoldMinutePayload.self, from: minuteData)
        guard let cutoff = dateFormatter("yyyy年M月d日 HH:mm:ss", exchange: instrument.exchange)
            .date(from: minute.delaystr) else { throw DataError.invalidResponse }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = instrument.exchange.timeZone
        let today = calendar.startOfDay(for: cutoff)
        let isEvening = calendar.component(.hour, from: cutoff) >= 20
        let evening: Date
        if isEvening {
            evening = today
        } else {
            guard let previousTradingDay = history.last(where: { $0.date < today })?.date else {
                throw DataError.unavailable
            }
            evening = previousTradingDay
        }
        let overnight = calendar.date(byAdding: .day, value: 1, to: evening)!
        let daytime = isEvening ? overnight : today
        let timeFormatter = dateFormatter("yyyy-MM-dd HH:mm", exchange: instrument.exchange)
        return zip(minute.times, minute.data).compactMap { clock, value in
            guard let value, let price = Double(value), price.isFinite, price > 0 else { return nil }
            var date = daytime
            if clock >= "20:00" {
                date = evening
            } else if clock < "06:00" {
                date = overnight
            }
            guard let time = timeFormatter.date(from: formatter.string(from: date) + " " + clock),
                  time <= cutoff else { return nil }
            return PricePoint(date: time, price: price)
        }
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

    private func request(_ host: String, _ path: String, _ items: [URLQueryItem] = [],
                         referer: String = "https://finance.qq.com/") async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !items.isEmpty { components.queryItems = items }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(referer, forHTTPHeaderField: "Referer")
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

private extension MarketData {
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
            var terms = [instrument.symbol, instrument.sourceCode, instrument.name]
            if instrument.exchange == .shanghaiGold {
                terms += ["黄金", "上海黄金交易所", "上金所", "沪金"]
            }
            return terms.contains { $0.filter { !$0.isWhitespace }.localizedCaseInsensitiveContains(search) }
        }
    }

    struct GoldMinutePayload: Decodable {
        let times: [String]
        let data: [String?]
        let delaystr: String
    }

    struct GoldDailyPayload: Decodable {
        let time: [GoldDailyPoint]
    }

    struct GoldDailyPoint: Decodable {
        let date: String
        let close: Double

        init(from decoder: Decoder) throws {
            var fields = try decoder.unkeyedContainer()
            date = try fields.decode(String.self)
            _ = try fields.decode(Double.self)
            close = try fields.decode(Double.self)
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
