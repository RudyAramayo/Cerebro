import Foundation

private enum CurrentInformationFixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class CurrentInformationURLProtocol: URLProtocol {
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
                throw CurrentInformationFixtureFailure.failed("Missing URL fixture handler")
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

    static func reset(
        handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) {
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
struct ROBMessagesCurrentInformationFixtureTests {
    static func main() async throws {
        try testDeterministicIntentRouting()
        try await testCNNRetrievalAndBoundedFallback()
        try await testWeatherRetrievalAndExplicitLocationRequirement()
        print("ROB Messages current-information fixtures passed")
    }

    private static func testDeterministicIntentRouting() throws {
        let cnn = ROBMessagesCurrentInformationService.requests(
            for: "Please send me the top 3 CNN articles from the RSS feed."
        )
        try expect(
            cnn == [.news(source: "cnn", query: nil, limit: 3)],
            "CNN RSS request did not route to the bounded CNN source"
        )

        let weather = ROBMessagesCurrentInformationService.requests(
            for: "What is the weather in Pasadena, CA tomorrow?"
        )
        try expect(
            weather == [.weather(location: "pasadena, ca", days: 2)],
            "Weather request did not preserve its explicit location"
        )

        let missingLocation = ROBMessagesCurrentInformationService.requests(
            for: "What is the weather today?"
        )
        try expect(
            missingLocation == [.weather(location: nil, days: 2)],
            "Location-free weather must remain an explicit unresolved request"
        )

        try expect(
            ROBMessagesCurrentInformationService.requests(
                for: "Tell me why this compiler warning appears."
            ).isEmpty,
            "An ordinary question incorrectly triggered network retrieval"
        )
        try expect(
            ROBMessagesCurrentInformationService.requests(
                for: "Help me revise this article and its conditional statements."
            ).isEmpty,
            "Generic article/condition wording incorrectly triggered network retrieval"
        )
    }

    private static func testCNNRetrievalAndBoundedFallback() async throws {
        let service = fixtureService()
        CurrentInformationURLProtocol.reset { request in
            try expect(
                request.url?.absoluteString == "https://www.cnn.com/sitemap/news.xml",
                "CNN request escaped the fixed source registry"
            )
            let xml = """
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
                    xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">
              <url><loc>https://www.cnn.com/2026/08/21/world/one</loc><news:news><news:title>First current CNN headline</news:title></news:news></url>
              <url><loc>https://www.cnn.com/2026/08/21/us/two</loc><news:news><news:title>Second current CNN headline</news:title></news:news></url>
              <url><loc>https://www.cnn.com/2026/08/21/politics/three</loc><news:news><news:title>Third current CNN headline</news:title></news:news></url>
              <url><loc>https://www.cnn.com/2026/08/21/tech/four</loc><news:news><news:title>Fourth current CNN headline</news:title></news:news></url>
            </urlset>
            """
            return try response(
                for: request,
                contentType: "application/xml",
                data: Data(xml.utf8)
            )
        }

        let context = try require(
            await service.context(
                for: "Please send me the top 3 CNN articles from the RSS feed."
            ),
            "CNN retrieval returned no context"
        )
        try expect(!context.shouldReturnDirectly, "Successful CNN retrieval bypassed models")
        try expect(
            context.modelContext.contains("untrusted publisher data")
                && context.modelContext.contains("not an editorial ranking"),
            "CNN result was not marked as untrusted, non-editorial model context"
        )
        try expect(
            context.fallbackReply.contains("First current CNN headline")
                && context.fallbackReply.contains("Third current CNN headline"),
            "CNN fallback omitted a requested headline"
        )
        try expect(
            !context.fallbackReply.contains("Fourth current CNN headline"),
            "CNN fallback exceeded the requested limit"
        )
    }

    private static func testWeatherRetrievalAndExplicitLocationRequirement() async throws {
        let service = fixtureService()
        CurrentInformationURLProtocol.reset { request in
            let host = request.url?.host
            if host == "geocoding-api.open-meteo.com" {
                try expect(request.httpMethod == "GET", "Weather geocoding was not GET-only")
                let data = try JSONSerialization.data(withJSONObject: [
                    "results": [[
                        "name": "Pasadena",
                        "admin1": "California",
                        "country": "United States",
                        "latitude": 34.1478,
                        "longitude": -118.1445,
                        "timezone": "America/Los_Angeles"
                    ]]
                ])
                return try response(for: request, contentType: "application/json", data: data)
            }
            try expect(host == "api.open-meteo.com", "Weather request escaped fixed hosts")
            let data = try JSONSerialization.data(withJSONObject: [
                "timezone": "America/Los_Angeles",
                "current": [
                    "temperature_2m": 78.5,
                    "apparent_temperature": 79.1,
                    "precipitation": 0.0,
                    "weather_code": 1,
                    "wind_speed_10m": 6.2
                ],
                "daily": [
                    "time": ["2026-08-21", "2026-08-22"],
                    "weather_code": [1, 2],
                    "temperature_2m_max": [86.0, 84.0],
                    "temperature_2m_min": [64.0, 63.0],
                    "precipitation_probability_max": [0, 5]
                ]
            ])
            return try response(for: request, contentType: "application/json", data: data)
        }

        let context = try require(
            await service.context(for: "What is the weather in Pasadena, CA tomorrow?"),
            "Weather retrieval returned no context"
        )
        try expect(!context.shouldReturnDirectly, "Successful weather retrieval bypassed models")
        try expect(
            context.fallbackReply.contains("Pasadena, California, United States")
                && context.fallbackReply.contains("78.5°F")
                && context.fallbackReply.contains("2026-08-22"),
            "Weather fallback omitted current or forecast data"
        )

        CurrentInformationURLProtocol.reset()
        let unresolved = try require(
            await service.context(for: "What is the weather today?"),
            "Location-free weather did not produce a clarification"
        )
        try expect(unresolved.shouldReturnDirectly, "Missing weather location reached a model")
        try expect(
            unresolved.fallbackReply.contains("What city, region, or postal code"),
            "Missing weather location did not request clarification"
        )
        try expect(
            CurrentInformationURLProtocol.currentRequestCount() == 0,
            "Location-free weather reached the network"
        )
    }

    private static func fixtureService() -> ROBMessagesCurrentInformationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CurrentInformationURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return ROBMessagesCurrentInformationService(
            newsService: ROBNewsSearchService(sessionConfiguration: configuration),
            weatherService: ROBWeatherSearchService(sessionConfiguration: configuration)
        )
    }

    private static func response(
        for request: URLRequest,
        contentType: String,
        data: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            ),
            "Could not create fixture HTTP response"
        )
        return (response, data)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() { throw CurrentInformationFixtureFailure.failed(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CurrentInformationFixtureFailure.failed(message) }
        return value
    }
}
