import Foundation

private enum MapFixtureFailure: Error { case failed(String) }

@main
struct ROBOpenStreetMapServiceFixtureTests {
    static func main() throws {
        let decoded = ROBOpenStreetMapService.decodePolyline6("??AA")
        try expect(decoded.count == 2, "Polyline point count changed")
        try expect(decoded[0] == ROBGeographicCoordinate(latitude: 0, longitude: 0), "Polyline origin changed")
        try expect(decoded[1] == ROBGeographicCoordinate(latitude: 0.000001, longitude: 0.000001), "Polyline precision changed")
        try expect(ROBOpenStreetMapService.decodePolyline6("invalid").isEmpty, "Malformed polyline was accepted")

        let oneDegreeAtEquator = ROBNavigationRuntime.distanceMeters(
            from: ROBGeographicCoordinate(latitude: 0, longitude: 0),
            to: ROBGeographicCoordinate(latitude: 0, longitude: 1)
        )
        try expect(abs(oneDegreeAtEquator - 111_195) < 100, "Haversine distance changed")
        print("ROB OpenStreetMap fixtures passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MapFixtureFailure.failed(message) }
    }
}
