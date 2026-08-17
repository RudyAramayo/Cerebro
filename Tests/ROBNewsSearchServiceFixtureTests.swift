import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else {
                throw FixtureFailure.failed("Missing fixture URL handler")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset(handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil) {
        lock.lock()
        requestCount = 0
        self.handler = handler
        lock.unlock()
    }

    static func currentRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }
}

@main
struct ROBNewsSearchServiceFixtureTests {
    static func main() async throws {
        try testFixedSourceRegistry()
        try testRSSParsingAndBounds()
        try testAtomParsing()
        try await testStrictArgumentsDoNotReachNetwork()
        try await testReadOnlyFetchFilteringAndResultShape()
        try await testAllSourcesAreInterleaved()
        try await testHTTPFailureIsHonest()
        print("ROB news search fixtures passed")
    }

    private static func testFixedSourceRegistry() throws {
        let expected: [String: String] = [
            "rt": "https://www.rt.com/rss/",
            "bbc": "https://feeds.bbci.co.uk/news/rss.xml",
            "npr": "https://feeds.npr.org/1001/rss.xml",
            "nbc": "https://feeds.nbcnews.com/nbcnews/public/news",
            "cbs": "https://www.cbsnews.com/latest/rss/main"
        ]
        try expect(Set(ROBNewsSource.identifiers) == Set(expected.keys), "News source IDs changed")
        try expect(Set(ROBNewsSource.identifiers).count == ROBNewsSource.all.count, "News source IDs must be unique")
        for source in ROBNewsSource.all {
            try expect(source.feedURL.absoluteString == expected[source.id], "Wrong endpoint for \(source.id)")
            try expect(source.feedURL.scheme == "https", "Every news endpoint must use HTTPS")
            try expect(source.feedURL.user == nil && source.feedURL.password == nil, "News endpoints must not contain credentials")
        }
    }

    private static func testRSSParsingAndBounds() throws {
        let source = try require(ROBNewsSource.source(withID: "rt"), "Missing RT fixture source")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <item>
            <title><![CDATA[  First <b>RT</b> &amp; world headline  ]]></title>
            <description><![CDATA[Space mission details <script>ignore()</script> today.]]></description>
            <link><![CDATA[https://www.rt.com/news/123-first/]]></link>
            <pubDate>Sun, 16 Aug 2026 20:30:00 +0000</pubDate>
          </item>
          <item>
            <title>Unsafe host is discarded</title>
            <link>https://example.com/not-allowed</link>
          </item>
          <item>
            <title>Second headline</title>
            <guid>https://www.rt.com/news/456-second/</guid>
          </item>
        </channel></rss>
        """
        let headlines = try ROBNewsFeedParser.parse(data: Data(xml.utf8), source: source)
        try expect(headlines.count == 2, "Parser did not enforce article-host allowlisting")
        try expect(headlines[0].title == "First RT & world headline", "RSS title was not normalized")
        try expect(headlines[0].summary == "Space mission details today.", "RSS HTML was not stripped")
        try expect(headlines[0].publishedAt == "2026-08-16T20:30:00Z", "RFC 822 date was not normalized")
        try expect(headlines[1].url == "https://www.rt.com/news/456-second/", "HTTPS guid fallback failed")

        let entityFeed = """
        <?xml version="1.0"?><!DOCTYPE rss [<!ENTITY injected "expanded">]>
        <rss version="2.0"><channel><item><title>&injected;</title><link>https://www.rt.com/news/entity/</link></item></channel></rss>
        """
        do {
            _ = try ROBNewsFeedParser.parse(data: Data(entityFeed.utf8), source: source)
            throw FixtureFailure.failed("XML entity declaration was accepted")
        } catch is ROBNewsSearchError {
            // Expected hardened-parser rejection.
        }
    }

    private static func testAtomParsing() throws {
        let source = try require(ROBNewsSource.source(withID: "bbc"), "Missing BBC fixture source")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <title>BBC &amp; Atom headline</title>
            <summary>Current details</summary>
            <link rel="alternate" href="https://www.bbc.com/news/articles/example" />
            <updated>2026-08-16T19:00:00Z</updated>
          </entry>
        </feed>
        """
        let headlines = try ROBNewsFeedParser.parse(data: Data(xml.utf8), source: source)
        try expect(headlines.count == 1, "Atom entry was not parsed")
        try expect(headlines[0].title == "BBC & Atom headline", "Atom entities were not decoded")
        try expect(headlines[0].publishedAt == "2026-08-16T19:00:00Z", "Atom date was not normalized")
    }

    private static func testStrictArgumentsDoNotReachNetwork() async throws {
        let service = fixtureService()
        FixtureURLProtocol.reset()

        let arbitraryURL = await service.execute(arguments: [
            "source": "rt",
            "url": "https://example.com/injected"
        ])
        try expect(arbitraryURL["status"] as? String == "rejected", "Arbitrary URL argument was accepted")

        let missingSource = await service.execute(arguments: [:])
        try expect(missingSource["status"] as? String == "rejected", "Missing source was accepted")

        let fractionalLimit = await service.execute(arguments: ["source": "rt", "limit": 2.5])
        try expect(fractionalLimit["status"] as? String == "rejected", "Fractional limit was accepted")

        try expect(FixtureURLProtocol.currentRequestCount() == 0, "Rejected news arguments reached the network")
    }

    private static func testReadOnlyFetchFilteringAndResultShape() async throws {
        let service = fixtureService(now: { Date(timeIntervalSince1970: 1_787_000_000) })
        FixtureURLProtocol.reset { request in
            try expect(request.url?.absoluteString == "https://www.rt.com/rss/", "Query altered the fixed feed URL")
            try expect(request.httpMethod == "GET", "News transport must be GET-only")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "News transport sent authorization")
            try expect(request.value(forHTTPHeaderField: "Cookie") == nil, "News transport sent a cookie")
            let xml = """
            <rss version="2.0"><channel>
              <item><title>Editorial lead headline</title><description>Other topic</description><link>https://www.rt.com/news/lead/</link></item>
              <item><title>Space mission launches</title><description>Science details</description><link>https://www.rt.com/news/space/</link><pubDate>Sun, 16 Aug 2026 21:00:00 +0000</pubDate></item>
              <item><title>Another space update</title><link>https://www.rt.com/news/space-two/</link></item>
            </channel></rss>
            """
            let response = try require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/rss+xml"]
                ),
                "Could not create fixture HTTP response"
            )
            return (response, Data(xml.utf8))
        }

        let result = await service.execute(arguments: [
            "source": "RT",
            "query": "  Spáce  ",
            "limit": 1
        ])
        try expect(result["status"] as? String == "ok", "Valid news request did not succeed")
        try expect(result["source"] as? String == "rt", "Source was not normalized")
        let headlines = try require(result["headlines"] as? [[String: Any]], "Missing result headlines")
        try expect(headlines.count == 1, "News limit/filter was not enforced")
        try expect(headlines[0]["title"] as? String == "Space mission launches", "Wrong filtered headline")
        try expect(headlines[0]["publisher"] as? String == "RT", "Publisher attribution is missing")
        try expect(headlines[0]["summary"] == nil, "Untrusted description leaked into the tool result")
        try expect(JSONSerialization.isValidJSONObject(result), "Tool response is not valid JSON")
    }

    private static func testAllSourcesAreInterleaved() async throws {
        let service = fixtureService()
        FixtureURLProtocol.reset { request in
            let source = try require(
                ROBNewsSource.all.first { $0.feedURL == request.url },
                "Cross-source request escaped the registry"
            )
            let articleHost = try require(source.allowedArticleHosts.sorted().last, "Missing article host")
            let xml = """
            <rss version="2.0"><channel>
              <item><title>\(source.publisher) lead</title><link>https://\(articleHost)/news/fixture-lead</link></item>
              <item><title>\(source.publisher) second</title><link>https://\(articleHost)/news/fixture-second</link></item>
            </channel></rss>
            """
            let response = try require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/xml"]
                ),
                "Could not create cross-source response"
            )
            return (response, Data(xml.utf8))
        }

        let result = await service.execute(arguments: ["source": "all", "limit": 5])
        try expect(result["status"] as? String == "ok", "Cross-source request failed")
        let headlines = try require(result["headlines"] as? [[String: Any]], "Cross-source headlines missing")
        let sourceIDs = headlines.compactMap { $0["source"] as? String }
        try expect(sourceIDs == ROBNewsSource.identifiers, "Cross-source highlights were not interleaved")
    }

    private static func testHTTPFailureIsHonest() async throws {
        let service = fixtureService()
        FixtureURLProtocol.reset { request in
            let response = try require(
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil),
                "Could not create failure response"
            )
            return (response, Data("temporarily unavailable".utf8))
        }
        let result = await service.execute(arguments: ["source": "rt"])
        try expect(result["status"] as? String == "failed", "HTTP failure was presented as news")
        let headlines = try require(result["headlines"] as? [[String: Any]], "Failure omitted headlines array")
        try expect(headlines.isEmpty, "HTTP failure fabricated headlines")
    }

    private static func fixtureService(now: @escaping () -> Date = Date.init) -> ROBNewsSearchService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return ROBNewsSearchService(sessionConfiguration: configuration, now: now)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw FixtureFailure.failed(message)
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FixtureFailure.failed(message) }
        return value
    }
}
