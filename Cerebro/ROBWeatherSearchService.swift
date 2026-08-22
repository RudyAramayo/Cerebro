//
//  ROBWeatherSearchService.swift
//  Cerebro
//
//  Read-only current weather lookup over fixed Open-Meteo endpoints.
//

import Foundation

enum ROBWeatherSearchError: LocalizedError {
    case invalidArguments(String)
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case locationNotFound

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): return detail
        case .invalidResponse: return "The weather provider returned an invalid response."
        case .responseTooLarge: return "The weather response exceeded Cerebro's size limit."
        case .httpStatus(let status): return "The weather provider returned HTTP status \(status)."
        case .locationNotFound: return "The weather location could not be found."
        }
    }
}

final class ROBWeatherSearchService {
    static let toolName = "search_weather"
    static let maximumLocationCharacters = 100
    static let defaultForecastDays = 3
    static let maximumForecastDays = 7

    private static let geocodingBaseURL = URL(
        string: "https://geocoding-api.open-meteo.com/v1/search"
    )!
    private static let forecastBaseURL = URL(
        string: "https://api.open-meteo.com/v1/forecast"
    )!
    private static let maximumResponseBytes = 256 * 1_024

    private let transport: ROBWeatherBoundedTransport
    private let now: () -> Date

    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        self.init(sessionConfiguration: configuration)
    }

    init(
        sessionConfiguration: URLSessionConfiguration,
        now: @escaping () -> Date = Date.init
    ) {
        transport = ROBWeatherBoundedTransport(configuration: sessionConfiguration)
        self.now = now
    }

    deinit {
        transport.invalidateAndCancel()
    }

    func execute(arguments: [String: Any]) async -> [String: Any] {
        do {
            let request = try validatedRequest(arguments)
            let location = try await geocode(request.location)
            let forecast = try await fetchForecast(
                latitude: location.latitude,
                longitude: location.longitude,
                days: request.days
            )
            return try result(location: location, forecast: forecast)
        } catch {
            let status: String
            if let weatherError = error as? ROBWeatherSearchError,
               case .locationNotFound = weatherError {
                status = "no_results"
            } else {
                status = "rejected"
            }
            return [
                "status": status,
                "error": boundedErrorDescription(error),
                "provider": "Open-Meteo"
            ]
        }
    }

    private struct SearchRequest {
        let location: String
        let days: Int
    }

    private struct Location {
        let name: String
        let admin1: String?
        let country: String?
        let latitude: Double
        let longitude: Double
        let timezone: String

        var displayName: String {
            var parts = [name]
            if let admin1, !admin1.isEmpty, admin1.caseInsensitiveCompare(name) != .orderedSame {
                parts.append(admin1)
            }
            if let country, !country.isEmpty,
               !parts.contains(where: { $0.caseInsensitiveCompare(country) == .orderedSame }) {
                parts.append(country)
            }
            return parts.joined(separator: ", ")
        }
    }

    private func validatedRequest(_ arguments: [String: Any]) throws -> SearchRequest {
        let supportedKeys: Set<String> = ["location", "days"]
        let unexpectedKeys = Set(arguments.keys).subtracting(supportedKeys)
        guard unexpectedKeys.isEmpty else {
            throw ROBWeatherSearchError.invalidArguments(
                "search_weather does not accept arbitrary URLs or these arguments: \(unexpectedKeys.sorted().joined(separator: ", "))."
            )
        }
        guard let rawLocation = arguments["location"] as? String else {
            throw ROBWeatherSearchError.invalidArguments(
                "search_weather requires an explicit city, region, or postal code."
            )
        }
        let location = rawLocation
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard location.count >= 2, location.count <= Self.maximumLocationCharacters else {
            throw ROBWeatherSearchError.invalidArguments(
                "The weather location must contain 2 to \(Self.maximumLocationCharacters) characters."
            )
        }

        var days = Self.defaultForecastDays
        if let rawDays = arguments["days"] {
            guard let number = rawDays as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue else {
                throw ROBWeatherSearchError.invalidArguments(
                    "The weather forecast length must be an integer."
                )
            }
            days = number.intValue
            guard (1...Self.maximumForecastDays).contains(days) else {
                throw ROBWeatherSearchError.invalidArguments(
                    "The weather forecast length must be between 1 and \(Self.maximumForecastDays) days."
                )
            }
        }
        return SearchRequest(location: location, days: days)
    }

    private func geocode(_ location: String) async throws -> Location {
        guard var components = URLComponents(
            url: Self.geocodingBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ROBWeatherSearchError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "name", value: location),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { throw ROBWeatherSearchError.invalidResponse }
        let json = try await fetchJSON(url: url)
        guard let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let name = boundedString(first["name"], maximum: 120),
              let latitude = finiteDouble(first["latitude"]),
              let longitude = finiteDouble(first["longitude"]),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            throw ROBWeatherSearchError.locationNotFound
        }
        return Location(
            name: name,
            admin1: boundedString(first["admin1"], maximum: 120),
            country: boundedString(first["country"], maximum: 120),
            latitude: latitude,
            longitude: longitude,
            timezone: boundedString(first["timezone"], maximum: 80) ?? "auto"
        )
    }

    private func fetchForecast(
        latitude: Double,
        longitude: Double,
        days: Int
    ) async throws -> [String: Any] {
        guard var components = URLComponents(
            url: Self.forecastBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ROBWeatherSearchError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m"
            ),
            URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            ),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "precipitation_unit", value: "inch"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days))
        ]
        guard let url = components.url else { throw ROBWeatherSearchError.invalidResponse }
        return try await fetchJSON(url: url)
    }

    private func fetchJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Cerebro/1.0 read-only-weather", forHTTPHeaderField: "User-Agent")
        let response = await transport.data(
            for: request,
            expectedURL: url,
            maximumBytes: Self.maximumResponseBytes
        )
        if let error = response.error { throw error }
        guard let http = response.response as? HTTPURLResponse,
              http.url == url else {
            throw ROBWeatherSearchError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ROBWeatherSearchError.httpStatus(http.statusCode)
        }
        guard http.mimeType?.lowercased() == "application/json",
              let data = response.data,
              !data.isEmpty,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ROBWeatherSearchError.invalidResponse
        }
        return json
    }

    private func result(
        location: Location,
        forecast: [String: Any]
    ) throws -> [String: Any] {
        guard let current = forecast["current"] as? [String: Any],
              let temperature = finiteDouble(current["temperature_2m"]),
              let apparent = finiteDouble(current["apparent_temperature"]),
              let weatherCode = finiteInteger(current["weather_code"]),
              let windSpeed = finiteDouble(current["wind_speed_10m"]),
              let precipitation = finiteDouble(current["precipitation"]),
              let daily = forecast["daily"] as? [String: Any],
              let dates = daily["time"] as? [String],
              let codes = integerArray(daily["weather_code"]),
              let highs = doubleArray(daily["temperature_2m_max"]),
              let lows = doubleArray(daily["temperature_2m_min"]),
              let precipitationChances = integerArray(
                daily["precipitation_probability_max"]
              ) else {
            throw ROBWeatherSearchError.invalidResponse
        }
        let count = [
            dates.count, codes.count, highs.count, lows.count,
            precipitationChances.count, Self.maximumForecastDays
        ].min() ?? 0
        guard count > 0 else { throw ROBWeatherSearchError.invalidResponse }
        let dailyResults: [[String: Any]] = (0..<count).map { index in
            [
                "date": String(dates[index].prefix(10)),
                "condition": Self.condition(for: codes[index]),
                "temperature_high_f": rounded(highs[index]),
                "temperature_low_f": rounded(lows[index]),
                "precipitation_probability_percent": precipitationChances[index]
            ]
        }
        return [
            "status": "ok",
            "provider": "Open-Meteo",
            "retrieved_at": ROBNewsSearchService.internetDate(now()),
            "location": location.displayName,
            "timezone": boundedString(forecast["timezone"], maximum: 80) ?? location.timezone,
            "current": [
                "condition": Self.condition(for: weatherCode),
                "temperature_f": rounded(temperature),
                "apparent_temperature_f": rounded(apparent),
                "precipitation_in": rounded(precipitation, places: 2),
                "wind_speed_mph": rounded(windSpeed)
            ],
            "daily": dailyResults
        ]
    }

    private func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let value = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(maximum))
    }

    private func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func finiteInteger(_ value: Any?) -> Int? {
        guard let value = finiteDouble(value), value.rounded() == value else { return nil }
        return Int(value)
    }

    private func doubleArray(_ value: Any?) -> [Double]? {
        guard let values = value as? [Any] else { return nil }
        let parsed = values.compactMap(finiteDouble)
        return parsed.count == values.count ? parsed : nil
    }

    private func integerArray(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any] else { return nil }
        let parsed = values.compactMap(finiteInteger)
        return parsed.count == values.count ? parsed : nil
    }

    private func rounded(_ value: Double, places: Int = 1) -> Double {
        let factor = pow(10, Double(places))
        return (value * factor).rounded() / factor
    }

    private func boundedErrorDescription(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription
            ?? "The weather request failed."
        return String(detail.prefix(240))
    }

    static func condition(for code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 65, 66, 67: return "rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorms"
        default: return "unknown conditions"
        }
    }
}

private struct ROBWeatherTransportResult {
    let data: Data?
    let response: URLResponse?
    let error: Error?
}

/// GET-only, byte-bounded transport for the two immutable weather hosts.
/// Redirects are rejected so model/user text can never redirect the service.
private final class ROBWeatherBoundedTransport: NSObject, URLSessionDataDelegate {
    private final class Context {
        let expectedURL: URL
        let maximumBytes: Int
        let completion: (ROBWeatherTransportResult) -> Void
        var data = Data()
        var response: URLResponse?
        var forcedError: Error?

        init(
            expectedURL: URL,
            maximumBytes: Int,
            completion: @escaping (ROBWeatherTransportResult) -> Void
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
        queue.name = "com.orbitusrobotics.cerebro.weather-transport"
        queue.maxConcurrentOperationCount = 1
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func data(
        for request: URLRequest,
        expectedURL: URL,
        maximumBytes: Int
    ) async -> ROBWeatherTransportResult {
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
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let context = contexts[dataTask.taskIdentifier]
        lock.unlock()
        guard let context else {
            completionHandler(.cancel)
            return
        }
        guard response.url == context.expectedURL else {
            context.forcedError = ROBWeatherSearchError.invalidResponse
            completionHandler(.cancel)
            return
        }
        let expectedLength = response.expectedContentLength
        guard expectedLength < 0 || expectedLength <= Int64(context.maximumBytes) else {
            context.forcedError = ROBWeatherSearchError.responseTooLarge
            completionHandler(.cancel)
            return
        }
        context.response = response
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let context = contexts[dataTask.taskIdentifier]
        lock.unlock()
        guard let context else { return }
        guard context.data.count <= context.maximumBytes - data.count else {
            context.forcedError = ROBWeatherSearchError.responseTooLarge
            dataTask.cancel()
            return
        }
        context.data.append(data)
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
        context.completion(ROBWeatherTransportResult(
            data: context.forcedError == nil ? context.data : nil,
            response: context.response,
            error: context.forcedError ?? error
        ))
    }
}
