//
//  ROBNewsSearchService.swift
//  Cerebro
//
//  Read-only current-headline lookup over a fixed set of public RSS feeds.
//

import Foundation

struct ROBNewsSource: Equatable {
    let id: String
    let publisher: String
    let feedURL: URL
    let allowedArticleHosts: Set<String>

    static let all: [ROBNewsSource] = [
        ROBNewsSource(
            id: "rt",
            publisher: "RT",
            feedURL: URL(string: "https://www.rt.com/rss/")!,
            allowedArticleHosts: ["rt.com", "www.rt.com"]
        ),
        ROBNewsSource(
            id: "bbc",
            publisher: "BBC News",
            feedURL: URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!,
            allowedArticleHosts: ["bbc.com", "www.bbc.com", "bbc.co.uk", "www.bbc.co.uk"]
        ),
        ROBNewsSource(
            id: "npr",
            publisher: "NPR",
            feedURL: URL(string: "https://feeds.npr.org/1001/rss.xml")!,
            allowedArticleHosts: ["npr.org", "www.npr.org"]
        ),
        ROBNewsSource(
            id: "nbc",
            publisher: "NBC News",
            feedURL: URL(string: "https://feeds.nbcnews.com/nbcnews/public/news")!,
            allowedArticleHosts: ["nbcnews.com", "www.nbcnews.com"]
        ),
        ROBNewsSource(
            id: "cbs",
            publisher: "CBS News",
            feedURL: URL(string: "https://www.cbsnews.com/latest/rss/main")!,
            allowedArticleHosts: ["cbsnews.com", "www.cbsnews.com"]
        )
    ]

    static let identifiers = all.map(\.id)

    static func source(withID rawID: String) -> ROBNewsSource? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == id }
    }
}

struct ROBNewsHeadline: Equatable {
    let sourceID: String
    let publisher: String
    let title: String
    let summary: String
    let url: String
    let publishedAt: String?

    var toolResult: [String: Any] {
        var result: [String: Any] = [
            "source": sourceID,
            "publisher": publisher,
            "title": title,
            "url": url
        ]
        if let publishedAt {
            result["published_at"] = publishedAt
        }
        return result
    }
}

enum ROBNewsSearchError: LocalizedError {
    case invalidArguments(String)
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case malformedFeed

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): return detail
        case .invalidResponse: return "The publisher returned an invalid feed response."
        case .responseTooLarge: return "The publisher feed exceeded Cerebro's size limit."
        case .httpStatus(let status): return "The publisher feed returned HTTP status \(status)."
        case .malformedFeed: return "The publisher returned an unreadable RSS feed."
        }
    }
}

final class ROBNewsSearchService {
    static let toolName = "search_news"
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumQueryCharacters = 100
    static let defaultLimit = 3
    static let maximumLimit = 5

    private let transport: ROBNewsBoundedTransport
    private let now: () -> Date

    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        self.init(sessionConfiguration: configuration)
    }

    init(
        sessionConfiguration: URLSessionConfiguration,
        now: @escaping () -> Date = Date.init
    ) {
        transport = ROBNewsBoundedTransport(configuration: sessionConfiguration)
        self.now = now
    }

    deinit {
        transport.invalidateAndCancel()
    }

    func execute(arguments: [String: Any]) async -> [String: Any] {
        do {
            let request = try validatedRequest(arguments)
            let sources = request.sourceID == "all"
                ? ROBNewsSource.all
                : [try requiredSource(request.sourceID)]
            let outcomes = await fetchAll(sources)
            let failures = outcomes.compactMap { outcome -> [String: Any]? in
                guard let error = outcome.error else { return nil }
                return [
                    "source": outcome.source.id,
                    "publisher": outcome.source.publisher,
                    "error": boundedErrorDescription(error)
                ]
            }
            let selected = selectedHeadlines(
                from: outcomes,
                query: request.query,
                limit: request.limit,
                interleaveSources: request.sourceID == "all"
            )
            var result: [String: Any] = [
                "status": failures.isEmpty ? (selected.isEmpty ? "no_results" : "ok") : (selected.isEmpty ? "failed" : "partial"),
                "source": request.sourceID,
                "retrieved_at": Self.internetDate(now()),
                "headlines": selected.map(\.toolResult)
            ]
            if !failures.isEmpty {
                result["feed_errors"] = failures
            }
            if selected.isEmpty && failures.isEmpty {
                result["detail"] = request.query == nil
                    ? "The current feeds contained no usable headlines."
                    : "No recent feed headlines matched the requested topic."
            }
            return result
        } catch {
            return [
                "status": "rejected",
                "error": boundedErrorDescription(error),
                "allowed_sources": ROBNewsSource.identifiers + ["all"]
            ]
        }
    }

    private struct SearchRequest {
        let sourceID: String
        let query: String?
        let limit: Int
    }

    private struct FetchOutcome {
        let source: ROBNewsSource
        let headlines: [ROBNewsHeadline]
        let error: Error?
    }

    private func validatedRequest(_ arguments: [String: Any]) throws -> SearchRequest {
        let supportedKeys: Set<String> = ["source", "query", "limit"]
        let unexpectedKeys = Set(arguments.keys).subtracting(supportedKeys)
        guard unexpectedKeys.isEmpty else {
            throw ROBNewsSearchError.invalidArguments(
                "search_news does not accept arbitrary URLs or these arguments: \(unexpectedKeys.sorted().joined(separator: ", "))."
            )
        }
        guard let rawSource = arguments["source"] as? String else {
            throw ROBNewsSearchError.invalidArguments("search_news requires a source.")
        }
        let sourceID = rawSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard sourceID == "all" || ROBNewsSource.source(withID: sourceID) != nil else {
            throw ROBNewsSearchError.invalidArguments("Unknown news source '\(String(sourceID.prefix(40)))'.")
        }

        var query: String?
        if let rawQuery = arguments["query"] {
            guard let value = rawQuery as? String else {
                throw ROBNewsSearchError.invalidArguments("The news query must be text.")
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= Self.maximumQueryCharacters else {
                throw ROBNewsSearchError.invalidArguments("The news query is too long.")
            }
            query = trimmed.isEmpty ? nil : trimmed
        }

        var limit = Self.defaultLimit
        if let rawLimit = arguments["limit"] {
            guard let number = rawLimit as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue else {
                throw ROBNewsSearchError.invalidArguments("The headline limit must be an integer.")
            }
            limit = number.intValue
            guard (1...Self.maximumLimit).contains(limit) else {
                throw ROBNewsSearchError.invalidArguments("The headline limit must be between 1 and \(Self.maximumLimit).")
            }
        }
        return SearchRequest(sourceID: sourceID, query: query, limit: limit)
    }

    private func requiredSource(_ sourceID: String) throws -> ROBNewsSource {
        guard let source = ROBNewsSource.source(withID: sourceID) else {
            throw ROBNewsSearchError.invalidArguments("Unknown news source.")
        }
        return source
    }

    private func fetchAll(_ sources: [ROBNewsSource]) async -> [FetchOutcome] {
        await withTaskGroup(of: FetchOutcome.self) { group in
            for source in sources {
                group.addTask { [self] in
                    do {
                        return FetchOutcome(
                            source: source,
                            headlines: try await fetch(source),
                            error: nil
                        )
                    } catch {
                        return FetchOutcome(source: source, headlines: [], error: error)
                    }
                }
            }
            var byID: [String: FetchOutcome] = [:]
            for await outcome in group {
                byID[outcome.source.id] = outcome
            }
            // Publisher ordering is meaningful for highlights. Restore source
            // registry order after concurrent downloads, then preserve each
            // publisher's own feed order.
            return sources.compactMap { byID[$0.id] }
        }
    }

    private func fetch(_ source: ROBNewsSource) async throws -> [ROBNewsHeadline] {
        var request = URLRequest(url: source.feedURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue(
            "application/rss+xml, application/xml, text/xml;q=0.9",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Cerebro/1.0 read-only-news-feed", forHTTPHeaderField: "User-Agent")

        let transportResult = await transport.data(
            for: request,
            expectedURL: source.feedURL,
            maximumBytes: Self.maximumResponseBytes
        )
        if let error = transportResult.error {
            throw error
        }
        guard let response = transportResult.response as? HTTPURLResponse,
              response.url == source.feedURL else {
            throw ROBNewsSearchError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw ROBNewsSearchError.httpStatus(response.statusCode)
        }
        let allowedMIMETypes: Set<String> = [
            "application/rss+xml", "application/atom+xml", "application/xml", "text/xml"
        ]
        guard let mimeType = response.mimeType?.lowercased(),
              allowedMIMETypes.contains(mimeType) else {
            throw ROBNewsSearchError.invalidResponse
        }
        guard let data = transportResult.data, !data.isEmpty else {
            throw ROBNewsSearchError.invalidResponse
        }
        return try ROBNewsFeedParser.parse(data: data, source: source)
    }

    private func matches(_ headline: ROBNewsHeadline, query: String?) -> Bool {
        guard let query else { return true }
        let comparisonLocale = Locale(identifier: "en_US_POSIX")
        let searchable = "\(headline.title) \(headline.summary)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: comparisonLocale)
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: comparisonLocale)
            .split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { searchable.contains(String($0)) }
    }

    private func selectedHeadlines(
        from outcomes: [FetchOutcome],
        query: String?,
        limit: Int,
        interleaveSources: Bool
    ) -> [ROBNewsHeadline] {
        let matchingGroups = outcomes.map { outcome in
            outcome.headlines.filter { matches($0, query: query) }
        }
        guard interleaveSources else {
            return Array((matchingGroups.first ?? []).prefix(limit))
        }

        var selected: [ROBNewsHeadline] = []
        var itemIndex = 0
        while selected.count < limit {
            var addedInRound = false
            for group in matchingGroups where itemIndex < group.count {
                selected.append(group[itemIndex])
                addedInRound = true
                if selected.count == limit { return selected }
            }
            if !addedInRound { break }
            itemIndex += 1
        }
        return selected
    }

    private func boundedErrorDescription(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? "The news feed request failed."
        return String(detail.prefix(240))
    }

    static func internetDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum ROBNewsFeedParser {
    static func parse(data: Data, source: ROBNewsSource) throws -> [ROBNewsHeadline] {
        // XMLParser does not resolve external entities below, but rejecting
        // declarations entirely also closes internal entity-expansion attacks.
        let declarationScan = String(decoding: data, as: UTF8.self).uppercased()
        guard !declarationScan.contains("<!DOCTYPE"),
              !declarationScan.contains("<!ENTITY") else {
            throw ROBNewsSearchError.malformedFeed
        }
        let delegate = ROBNewsXMLDelegate(source: source)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawFeedRoot else {
            throw ROBNewsSearchError.malformedFeed
        }
        return delegate.headlines
    }
}

private final class ROBNewsXMLDelegate: NSObject, XMLParserDelegate {
    private let source: ROBNewsSource
    private(set) var headlines: [ROBNewsHeadline] = []
    private(set) var sawFeedRoot = false
    private var isInsideItem = false
    private var currentField: String?
    private var currentText = ""
    private var title = ""
    private var summary = ""
    private var link = ""
    private var guid = ""
    private var published = ""

    init(source: ROBNewsSource) {
        self.source = source
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName)
        if name == "rss" || name == "feed" {
            sawFeedRoot = true
        }
        if name == "item" || name == "entry" {
            isInsideItem = true
            title = ""
            summary = ""
            link = ""
            guid = ""
            published = ""
            currentField = nil
            currentText = ""
            return
        }
        guard isInsideItem else { return }
        switch name {
        case "title", "description", "summary", "encoded", "link", "guid", "pubdate", "published", "updated", "date":
            currentField = name
            currentText = ""
            if name == "link", let href = attributeDict["href"], !href.isEmpty {
                link = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem, currentField != nil else { return }
        if currentText.count < 8_192 {
            currentText.append(String(string.prefix(8_192 - currentText.count)))
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName)
        if name == "item" || name == "entry" {
            appendCurrentHeadline()
            isInsideItem = false
            currentField = nil
            currentText = ""
            return
        }
        guard isInsideItem, currentField == name else { return }
        let value = normalizedText(currentText, maximumCharacters: name == "title" ? 300 : 1_000)
        switch name {
        case "title":
            if title.isEmpty { title = value }
        case "description", "summary", "encoded":
            if summary.isEmpty { summary = value }
        case "link":
            if link.isEmpty { link = value }
        case "guid":
            if guid.isEmpty { guid = value }
        case "pubdate", "published", "updated", "date":
            if published.isEmpty { published = value }
        default:
            break
        }
        currentField = nil
        currentText = ""
    }

    private func appendCurrentHeadline() {
        guard headlines.count < 200 else { return }
        let candidateURL = link.isEmpty ? guid : link
        guard !title.isEmpty,
              candidateURL.count <= 2_048,
              let articleURL = URL(string: candidateURL),
              articleURL.scheme?.lowercased() == "https",
              let host = articleURL.host?.lowercased(),
              source.allowedArticleHosts.contains(host) else {
            return
        }
        let publishedAt = parsedDate(published).map(ROBNewsSearchService.internetDate)
        let headline = ROBNewsHeadline(
            sourceID: source.id,
            publisher: source.publisher,
            title: title,
            summary: summary,
            url: articleURL.absoluteString,
            publishedAt: publishedAt
        )
        guard !headlines.contains(where: { $0.url == headline.url }) else { return }
        headlines.append(headline)
    }

    private func normalizedName(_ name: String) -> String {
        name.lowercased().split(separator: ":").last.map(String.init) ?? name.lowercased()
    }

    private func normalizedText(_ rawText: String, maximumCharacters: Int) -> String {
        var text = String(rawText.prefix(8_192))
        text = text.replacingOccurrences(of: "<script\\b[^>]*>[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<style\\b[^>]*>[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&#38;": "&",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(maximumCharacters))
    }

    private func parsedDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let internetFormatter = ISO8601DateFormatter()
        if let date = internetFormatter.date(from: trimmed) {
            return date
        }
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

private struct ROBNewsTransportResult {
    let data: Data?
    let response: URLResponse?
    let error: Error?
}

/// Bounds bytes while they arrive, rejects every redirect, and requires the
/// final response URL to exactly match the source registry entry.
private final class ROBNewsBoundedTransport: NSObject, URLSessionDataDelegate {
    private final class Context {
        let expectedURL: URL
        let maximumBytes: Int
        let completion: (ROBNewsTransportResult) -> Void
        var data = Data()
        var response: URLResponse?
        var forcedError: Error?

        init(
            expectedURL: URL,
            maximumBytes: Int,
            completion: @escaping (ROBNewsTransportResult) -> Void
        ) {
            self.expectedURL = expectedURL
            self.maximumBytes = maximumBytes
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        let queue = OperationQueue()
        queue.name = "com.orbitusrobotics.cerebro.news-transport"
        queue.maxConcurrentOperationCount = 1
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func data(
        for request: URLRequest,
        expectedURL: URL,
        maximumBytes: Int
    ) async -> ROBNewsTransportResult {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            let context = Context(
                expectedURL: expectedURL,
                maximumBytes: maximumBytes,
                completion: { continuation.resume(returning: $0) }
            )
            lock.lock()
            contexts[task.taskIdentifier] = context
            lock.unlock()
            task.resume()
        }
    }

    func invalidateAndCancel() {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var disposition = URLSession.ResponseDisposition.allow
        lock.lock()
        if let context = contexts[dataTask.taskIdentifier] {
            context.response = response
            if response.url != context.expectedURL {
                context.forcedError = ROBNewsSearchError.invalidResponse
                disposition = .cancel
            } else if response.expectedContentLength > Int64(context.maximumBytes) {
                context.forcedError = ROBNewsSearchError.responseTooLarge
                disposition = .cancel
            }
        } else {
            disposition = .cancel
        }
        lock.unlock()
        completionHandler(disposition)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        var shouldCancel = false
        lock.lock()
        if let context = contexts[dataTask.taskIdentifier], context.forcedError == nil {
            let remaining = context.maximumBytes - context.data.count
            if data.count > remaining {
                context.forcedError = ROBNewsSearchError.responseTooLarge
                shouldCancel = true
            } else {
                context.data.append(data)
            }
        }
        lock.unlock()
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        if let context = contexts[task.taskIdentifier] {
            context.response = response
            context.forcedError = ROBNewsSearchError.invalidResponse
        }
        lock.unlock()
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let context = contexts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let context else { return }
        context.completion(ROBNewsTransportResult(
            data: context.data,
            response: context.response,
            error: context.forcedError ?? error
        ))
    }
}
