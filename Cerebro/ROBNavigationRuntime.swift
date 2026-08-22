//
//  ROBNavigationRuntime.swift
//  Cerebro
//
//  Converts an authenticated OpenStreetMap/Valhalla pedestrian route into a
//  local heading request. The first route segment is aligned with RPLidar yaw
//  when the session starts; the operator must point ROB down that segment.
//

import CoreLocation
import Foundation

enum ROBNavigationGuidance {
    case waiting(String)
    case ready(headingOffset: Double, distanceRemainingMeters: Double)
    case arrived
    case unavailable(String)
}

struct ROBNavigationSnapshot {
    let destinationName: String?
    let routeLengthMeters: Double?
    let locationAccuracyMeters: Double?
    let detail: String
}

final class ROBNavigationRuntime {
    static let shared = ROBNavigationRuntime()

    private struct LocalPose {
        let x: Double
        let y: Double
        let yaw: Double
        let receivedAtUptime: TimeInterval
    }

    private lazy var locationDelegate = ROBLocationDelegate(owner: self)
    private let locationManager = CLLocationManager()
    private var latestLocation: CLLocation?
    private var destination: ROBGeographicCoordinate?
    private var destinationName: String?
    private var authorizedRadiusMeters = 0.0
    private var route: ROBPedestrianRoute?
    private var localPose: LocalPose?
    private var localOrigin: LocalPose?
    private var geographicHeadingOffset: Double?
    private var routeGeneration: UInt64 = 0
    private var planning = false
    private var detail = "No destination navigation session is active"

    private init() {
        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 0.5
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func configure(
        destinationLatitude: Double,
        destinationLongitude: Double,
        destinationName: String?,
        authorizedRadiusMeters: Double
    ) {
        precondition(Thread.isMainThread)
        routeGeneration &+= 1
        destination = ROBGeographicCoordinate(
            latitude: destinationLatitude,
            longitude: destinationLongitude
        )
        self.destinationName = destinationName
        self.authorizedRadiusMeters = authorizedRadiusMeters
        route = nil
        localOrigin = localPose
        geographicHeadingOffset = nil
        planning = false
        detail = "Waiting for an accurate robot location"
        planRouteIfPossible(generation: routeGeneration)
    }

    func clear() {
        precondition(Thread.isMainThread)
        routeGeneration &+= 1
        destination = nil
        destinationName = nil
        route = nil
        localOrigin = nil
        geographicHeadingOffset = nil
        planning = false
        detail = "No destination navigation session is active"
    }

    func updateLocalPose(x: Double, y: Double, yaw: Double, receivedAtUptime: TimeInterval) {
        precondition(Thread.isMainThread)
        let pose = LocalPose(x: x, y: y, yaw: yaw, receivedAtUptime: receivedAtUptime)
        localPose = pose
        if localOrigin == nil, destination != nil { localOrigin = pose }
        establishHeadingAlignmentIfPossible()
    }

    func guidance(now: TimeInterval) -> ROBNavigationGuidance {
        precondition(Thread.isMainThread)
        guard let destination else { return .unavailable("No authenticated destination is active") }
        guard let pose = localPose, now - pose.receivedAtUptime <= 0.75 else {
            return .waiting("Destination navigation is waiting for a fresh RPLidar pose")
        }
        if let origin = localOrigin,
           hypot(pose.x - origin.x, pose.y - origin.y) >= authorizedRadiusMeters * 0.96 {
            return .unavailable("Stopped at the controller-authorized navigation boundary")
        }
        guard let location = usableLocation() else {
            return .waiting("Destination navigation needs robot GPS accuracy of 15 m or better")
        }
        guard let route else {
            if !planning { planRouteIfPossible(generation: routeGeneration) }
            return .waiting(detail)
        }
        guard let headingOffset = geographicHeadingOffset else {
            establishHeadingAlignmentIfPossible()
            return .waiting("Point ROB along the first route segment while heading alignment initializes")
        }

        let current = ROBGeographicCoordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let remaining = Self.distanceMeters(from: current, to: destination)
        let arrivalRadius = max(2.5, min(5.0, location.horizontalAccuracy * 0.5))
        if remaining <= arrivalRadius {
            detail = "Destination reached"
            return .arrived
        }

        let nearestIndex = route.coordinates.indices.min {
            Self.distanceMeters(from: current, to: route.coordinates[$0])
                < Self.distanceMeters(from: current, to: route.coordinates[$1])
        } ?? 0
        var targetIndex = nearestIndex
        while targetIndex + 1 < route.coordinates.count,
              Self.distanceMeters(from: current, to: route.coordinates[targetIndex]) < 3.0 {
            targetIndex += 1
        }
        let target = route.coordinates[min(targetIndex, route.coordinates.count - 1)]
        let desiredGeographicHeading = Self.bearingRadians(from: current, to: target)
        let currentGeographicHeading = Self.normalizedAngle(pose.yaw + headingOffset)
        let error = Self.normalizedAngle(desiredGeographicHeading - currentGeographicHeading)
        detail = String(format: "Navigating to %@ — %.1f m remaining", destinationName ?? "destination", remaining)
        return .ready(headingOffset: error, distanceRemainingMeters: remaining)
    }

    func snapshot() -> ROBNavigationSnapshot {
        ROBNavigationSnapshot(
            destinationName: destinationName,
            routeLengthMeters: route?.lengthMeters,
            locationAccuracyMeters: usableLocation()?.horizontalAccuracy,
            detail: detail
        )
    }

    fileprivate func didUpdateLocations(_ locations: [CLLocation]) {
        guard let candidate = locations.last,
              candidate.horizontalAccuracy >= 0,
              abs(candidate.timestamp.timeIntervalSinceNow) <= 10 else { return }
        latestLocation = candidate
        if Thread.isMainThread {
            planRouteIfPossible(generation: routeGeneration)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.planRouteIfPossible(generation: self.routeGeneration)
            }
        }
    }

    fileprivate func didFailWithLocationError(_ error: Error) {
        detail = "Robot location unavailable: \(error.localizedDescription)"
    }

    private func usableLocation() -> CLLocation? {
        guard let location = latestLocation,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 15,
              abs(location.timestamp.timeIntervalSinceNow) <= 5 else { return nil }
        return location
    }

    private func planRouteIfPossible(generation: UInt64) {
        guard !planning, route == nil,
              generation == routeGeneration,
              let location = usableLocation(),
              let destination else { return }
        planning = true
        detail = "Planning an OpenStreetMap pedestrian route"
        let origin = ROBGeographicCoordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        Task { @MainActor [weak self] in
            do {
                let planned = try await ROBOpenStreetMapService.shared.pedestrianRoute(
                    from: origin,
                    to: destination
                )
                guard let self, generation == self.routeGeneration else { return }
                self.planning = false
                guard planned.lengthMeters <= self.authorizedRadiusMeters else {
                    self.detail = String(
                        format: "Route is %.1f m, beyond the %.1f m authorized area",
                        planned.lengthMeters,
                        self.authorizedRadiusMeters
                    )
                    return
                }
                self.route = planned
                self.detail = String(format: "OpenStreetMap pedestrian route ready — %.1f m", planned.lengthMeters)
                self.establishHeadingAlignmentIfPossible()
            } catch {
                guard let self, generation == self.routeGeneration else { return }
                self.planning = false
                self.detail = error.localizedDescription
            }
        }
    }

    private func establishHeadingAlignmentIfPossible() {
        guard geographicHeadingOffset == nil,
              let pose = localPose,
              let route,
              route.coordinates.count >= 2 else { return }
        let routeHeading = Self.bearingRadians(from: route.coordinates[0], to: route.coordinates[1])
        geographicHeadingOffset = Self.normalizedAngle(routeHeading - pose.yaw)
    }

    static func distanceMeters(
        from first: ROBGeographicCoordinate,
        to second: ROBGeographicCoordinate
    ) -> Double {
        let radius = 6_371_000.0
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let latitude1 = first.latitude * .pi / 180
        let latitude2 = second.latitude * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func bearingRadians(
        from first: ROBGeographicCoordinate,
        to second: ROBGeographicCoordinate
    ) -> Double {
        let latitude1 = first.latitude * .pi / 180
        let latitude2 = second.latitude * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2)
            - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        return atan2(y, x)
    }

    private static func normalizedAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}

private final class ROBLocationDelegate: NSObject, CLLocationManagerDelegate {
    private weak var owner: ROBNavigationRuntime?

    init(owner: ROBNavigationRuntime) {
        self.owner = owner
        super.init()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        owner?.didUpdateLocations(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        owner?.didFailWithLocationError(error)
    }
}
