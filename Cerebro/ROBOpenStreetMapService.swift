//
//  ROBOpenStreetMapService.swift
//  Cerebro
//
//  Pedestrian routing over OpenStreetMap data. OpenStreetMap supplies the map
//  data; a configurable Valhalla instance supplies the route computation.
//

import Foundation

struct ROBGeographicCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90 ... 90).contains(latitude)
            && (-180 ... 180).contains(longitude)
    }
}

struct ROBPedestrianRoute: Sendable {
    let coordinates: [ROBGeographicCoordinate]
    let lengthMeters: Double
    let expectedTravelTime: TimeInterval
}

enum ROBOpenStreetMapError: LocalizedError {
    case invalidEndpoint
    case invalidCoordinate
    case routeUnavailable(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "The Valhalla routing endpoint is invalid."
        case .invalidCoordinate: return "The route contains an invalid coordinate."
        case .routeUnavailable(let detail): return "Pedestrian route unavailable: \(detail)"
        case .malformedResponse: return "The routing service returned a malformed route."
        }
    }
}

final class ROBOpenStreetMapService {
    static let shared = ROBOpenStreetMapService()
    static let endpointDefaultsKey = "ROBValhallaEndpoint"
    static let defaultEndpoint = "https://valhalla1.openstreetmap.de"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func pedestrianRoute(
        from origin: ROBGeographicCoordinate,
        to destination: ROBGeographicCoordinate
    ) async throws -> ROBPedestrianRoute {
        guard origin.isValid, destination.isValid else {
            throw ROBOpenStreetMapError.invalidCoordinate
        }
        let endpointString = UserDefaults.standard.string(forKey: Self.endpointDefaultsKey)
            ?? Self.defaultEndpoint
        guard var components = URLComponents(string: endpointString) else {
            throw ROBOpenStreetMapError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/route" : "/\(basePath)/route"
        guard let url = components.url else { throw ROBOpenStreetMapError.invalidEndpoint }

        let body: [String: Any] = [
            "locations": [
                ["lat": origin.latitude, "lon": origin.longitude, "type": "break"],
                ["lat": destination.latitude, "lon": destination.longitude, "type": "break"]
            ],
            "costing": "pedestrian",
            "directions_options": ["units": "kilometers"]
        ]
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Cerebro/2 (ROB navigation; https://orbitusrobotics.com)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard data.count <= 1_000_000,
              let http = response as? HTTPURLResponse else {
            throw ROBOpenStreetMapError.malformedResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ROBOpenStreetMapError.routeUnavailable(detail ?? "HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(ValhallaResponse.self, from: data)
        let coordinates = decoded.trip.legs.flatMap { Self.decodePolyline6($0.shape) }
        guard coordinates.count >= 2, coordinates.allSatisfy(\.isValid) else {
            throw ROBOpenStreetMapError.malformedResponse
        }
        return ROBPedestrianRoute(
            coordinates: coordinates,
            lengthMeters: decoded.trip.summary.length * 1_000,
            expectedTravelTime: decoded.trip.summary.time
        )
    }

    /// Valhalla's default route shape is an encoded polyline with precision 6.
    static func decodePolyline6(_ value: String) -> [ROBGeographicCoordinate] {
        let bytes = Array(value.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var result: [ROBGeographicCoordinate] = []

        func nextDelta() -> Int? {
            var shift = 0
            var encoded = 0
            while index < bytes.count, shift <= 30 {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard byte >= 0 else { return nil }
                encoded |= (byte & 0x1f) << shift
                shift += 5
                if byte < 0x20 {
                    return (encoded & 1) == 1 ? ~(encoded >> 1) : (encoded >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let latitudeDelta = nextDelta(), let longitudeDelta = nextDelta() else { return [] }
            latitude += latitudeDelta
            longitude += longitudeDelta
            result.append(ROBGeographicCoordinate(
                latitude: Double(latitude) / 1_000_000,
                longitude: Double(longitude) / 1_000_000
            ))
        }
        return result
    }

    private struct ValhallaResponse: Decodable {
        let trip: Trip
        struct Trip: Decodable {
            let legs: [Leg]
            let summary: Summary
        }
        struct Leg: Decodable { let shape: String }
        struct Summary: Decodable {
            let length: Double
            let time: TimeInterval
        }
    }
}
