//
//  ROBServoControlConfiguration.swift
//  Cerebro
//
//  Persistent, operator-editable neck positions, sequences, and gestures.
//

import Foundation

public extension Notification.Name {
    static let robServoControlConfigurationDidChange = Notification.Name(
        "ROBServoControlConfigurationDidChange"
    )
}

@objcMembers public final class ROBServoCameraPosition: NSObject {
    public var identifier: String
    public var name: String
    /// Zero preserves the current pan target; nonzero values request an exact pan pose.
    public var panTarget: Int
    public var lowerTarget: Int
    public var upperTarget: Int

    public init(
        identifier: String = UUID().uuidString,
        name: String,
        panTarget: Int = 0,
        lowerTarget: Int,
        upperTarget: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.panTarget = panTarget
        self.lowerTarget = lowerTarget
        self.upperTarget = upperTarget
        super.init()
    }

    public func copyValue() -> ROBServoCameraPosition {
        ROBServoCameraPosition(
            identifier: identifier,
            name: name,
            panTarget: panTarget,
            lowerTarget: lowerTarget,
            upperTarget: upperTarget
        )
    }
}

@objcMembers public final class ROBServoSequencePhase: NSObject {
    public var identifier: String
    public var sequenceName: String
    public var phaseIndex: Int
    public var phaseName: String
    public var cameraPositionName: String
    public var panTarget: Int
    public var lowerTarget: Int
    public var upperTarget: Int
    public var holdSeconds: Double

    public init(
        identifier: String = UUID().uuidString,
        sequenceName: String,
        phaseIndex: Int,
        phaseName: String,
        cameraPositionName: String,
        panTarget: Int,
        lowerTarget: Int,
        upperTarget: Int,
        holdSeconds: Double
    ) {
        self.identifier = identifier
        self.sequenceName = sequenceName
        self.phaseIndex = phaseIndex
        self.phaseName = phaseName
        self.cameraPositionName = cameraPositionName
        self.panTarget = panTarget
        self.lowerTarget = lowerTarget
        self.upperTarget = upperTarget
        self.holdSeconds = holdSeconds
        super.init()
    }

    public func copyValue() -> ROBServoSequencePhase {
        ROBServoSequencePhase(
            identifier: identifier,
            sequenceName: sequenceName,
            phaseIndex: phaseIndex,
            phaseName: phaseName,
            cameraPositionName: cameraPositionName,
            panTarget: panTarget,
            lowerTarget: lowerTarget,
            upperTarget: upperTarget,
            holdSeconds: holdSeconds
        )
    }
}

@objcMembers public final class ROBServoRelativeGesture: NSObject {
    public var identifier: String
    public var name: String
    /// One of "pan", "lower", or "upper".
    public var servo: String
    public var delta: Int
    public var repetitions: Int
    public var intervalSeconds: Double

    public init(
        identifier: String = UUID().uuidString,
        name: String,
        servo: String,
        delta: Int,
        repetitions: Int,
        intervalSeconds: Double
    ) {
        self.identifier = identifier
        self.name = name
        self.servo = servo
        self.delta = delta
        self.repetitions = repetitions
        self.intervalSeconds = intervalSeconds
        super.init()
    }

    public func copyValue() -> ROBServoRelativeGesture {
        ROBServoRelativeGesture(
            identifier: identifier,
            name: name,
            servo: servo,
            delta: delta,
            repetitions: repetitions,
            intervalSeconds: intervalSeconds
        )
    }
}

public enum ROBServoControlConfigurationError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

@objcMembers public final class ROBServoControlStore: NSObject {
    public static let shared = ROBServoControlStore()

    private static let defaultsKey = "ROBServoControlConfigurationV1"
    private static let schemaVersion = 3
    private static let uprightLowerTarget = 6011
    private static let legacyUprightUpperTarget = 6073
    // Compensates for the front camera's approximately -25 degree mounting.
    private static let uprightUpperTarget = 6906
    private let lock = NSRecursiveLock()
    private var positionsStorage: [ROBServoCameraPosition] = []
    private var phasesStorage: [ROBServoSequencePhase] = []
    private var gesturesStorage: [ROBServoRelativeGesture] = []

    private override init() {
        super.init()
        if !loadPersistedConfiguration() {
            installDefaults(persist: true)
        }
    }

    public func cameraPositionsSnapshot() -> [ROBServoCameraPosition] {
        lock.lock()
        defer { lock.unlock() }
        return positionsStorage.map { $0.copyValue() }
    }

    @objc(cameraPositionNamed:)
    public func cameraPosition(named name: String) -> ROBServoCameraPosition? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return positionsStorage.first {
            $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        }?.copyValue()
    }

    public func sequencePhasesSnapshot() -> [ROBServoSequencePhase] {
        lock.lock()
        defer { lock.unlock() }
        return phasesStorage
            .sorted(by: Self.phaseSort)
            .map { $0.copyValue() }
    }

    public func gesturesSnapshot() -> [ROBServoRelativeGesture] {
        lock.lock()
        defer { lock.unlock() }
        return gesturesStorage.map { $0.copyValue() }
    }

    @objc(startupPhaseAtIndex:)
    public func startupPhase(at index: Int) -> ROBServoSequencePhase? {
        lock.lock()
        defer { lock.unlock() }
        let startup = phasesStorage
            .filter { $0.sequenceName.caseInsensitiveCompare("startup") == .orderedSame }
            .sorted(by: Self.phaseSort)
        guard startup.indices.contains(index) else { return nil }
        return startup[index].copyValue()
    }

    @nonobjc public func replaceConfiguration(
        cameraPositions: [ROBServoCameraPosition],
        sequencePhases: [ROBServoSequencePhase],
        gestures: [ROBServoRelativeGesture]
    ) throws {
        try Self.validate(
            cameraPositions: cameraPositions,
            sequencePhases: sequencePhases,
            gestures: gestures
        )
        lock.lock()
        positionsStorage = cameraPositions.map { $0.copyValue() }
        phasesStorage = sequencePhases.sorted(by: Self.phaseSort).map { $0.copyValue() }
        gesturesStorage = gestures.map { $0.copyValue() }
        persistLocked()
        lock.unlock()
        NotificationCenter.default.post(
            name: .robServoControlConfigurationDidChange,
            object: self
        )
    }

    public func restoreDefaults() {
        installDefaults(persist: true)
        NotificationCenter.default.post(
            name: .robServoControlConfigurationDidChange,
            object: self
        )
    }

    @nonobjc public static func validate(
        cameraPositions: [ROBServoCameraPosition],
        sequencePhases: [ROBServoSequencePhase],
        gestures: [ROBServoRelativeGesture]
    ) throws {
        guard !cameraPositions.isEmpty else {
            throw ROBServoControlConfigurationError.invalid(
                "At least one camera position is required."
            )
        }
        var positionNames = Set<String>()
        for position in cameraPositions {
            let normalized = position.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, positionNames.insert(normalized).inserted else {
                throw ROBServoControlConfigurationError.invalid(
                    "Camera position names must be nonempty and unique."
                )
            }
            try validateTargetAllowingOff(position.panTarget, label: "Camera pan target")
            try validateActiveTarget(position.lowerTarget, label: "Lower target")
            try validateActiveTarget(position.upperTarget, label: "Upper target")
        }

        guard !sequencePhases.isEmpty else {
            throw ROBServoControlConfigurationError.invalid(
                "At least one servo sequence phase is required."
            )
        }
        var phaseKeys = Set<String>()
        for phase in sequencePhases {
            let sequence = phase.sequenceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = phase.phaseName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sequence.isEmpty, !name.isEmpty, phase.phaseIndex >= 1 else {
                throw ROBServoControlConfigurationError.invalid(
                    "Every sequence phase needs a sequence name, phase name, and index of at least 1."
                )
            }
            let key = "\(sequence.lowercased())#\(phase.phaseIndex)"
            guard phaseKeys.insert(key).inserted else {
                throw ROBServoControlConfigurationError.invalid(
                    "Sequence phase indexes must be unique within each sequence."
                )
            }
            try validateTargetAllowingOff(phase.panTarget, label: "Pan target")
            try validateActiveTarget(phase.lowerTarget, label: "Lower target")
            try validateActiveTarget(phase.upperTarget, label: "Upper target")
            guard phase.holdSeconds.isFinite,
                  (0.0 ... 10.0).contains(phase.holdSeconds) else {
                throw ROBServoControlConfigurationError.invalid(
                    "Phase hold must be between 0 and 10 seconds."
                )
            }
            let cameraPosition = phase.cameraPositionName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard cameraPosition.isEmpty || positionNames.contains(cameraPosition) else {
                throw ROBServoControlConfigurationError.invalid(
                    "Sequence camera positions must refer to a named camera position."
                )
            }
        }

        let startup = sequencePhases
            .filter { $0.sequenceName.caseInsensitiveCompare("startup") == .orderedSame }
            .sorted(by: phaseSort)
        guard startup.count == 3,
              startup.map(\.phaseIndex) == [1, 2, 3] else {
            throw ROBServoControlConfigurationError.invalid(
                "The startup sequence must contain exactly phases 1, 2, and 3."
            )
        }
        guard startup[0].panTarget == 0 else {
            throw ROBServoControlConfigurationError.invalid(
                "Startup phase 1 must keep pan OFF."
            )
        }
        guard (5000 ... 6495).contains(startup[0].lowerTarget) else {
            throw ROBServoControlConfigurationError.invalid(
                "Startup phase 1 lower must remain in the 5000–6495 full-clearance band."
            )
        }
        guard startup[1].panTarget != 0,
              startup[1].lowerTarget == startup[0].lowerTarget,
              startup[1].upperTarget == startup[0].upperTarget else {
            throw ROBServoControlConfigurationError.invalid(
                "Startup phase 2 must hold the phase-1 lower/upper targets while energizing pan."
            )
        }
        guard startup[2].panTarget == startup[1].panTarget else {
            throw ROBServoControlConfigurationError.invalid(
                "Startup phase 3 must retain the centered phase-2 pan target."
            )
        }

        var gestureNames = Set<String>()
        for gesture in gestures {
            let name = gesture.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  gestureNames.insert(name.lowercased()).inserted else {
                throw ROBServoControlConfigurationError.invalid(
                    "Gesture names must be nonempty and unique."
                )
            }
            guard ["pan", "lower", "upper"].contains(gesture.servo.lowercased()) else {
                throw ROBServoControlConfigurationError.invalid(
                    "Gesture servo must be pan, lower, or upper."
                )
            }
            guard gesture.delta != 0,
                  (-4000 ... 4000).contains(gesture.delta) else {
                throw ROBServoControlConfigurationError.invalid(
                    "Gesture delta must be nonzero and no larger than 4000 target units."
                )
            }
            guard (1 ... 5).contains(gesture.repetitions),
                  gesture.intervalSeconds.isFinite,
                  (0.1 ... 3.0).contains(gesture.intervalSeconds) else {
                throw ROBServoControlConfigurationError.invalid(
                    "Gesture repetitions must be 1–5 and interval must be 0.1–3.0 seconds."
                )
            }
        }
    }

    private static func validateTargetAllowingOff(_ target: Int, label: String) throws {
        guard (0 ... 16_383).contains(target) else {
            throw ROBServoControlConfigurationError.invalid(
                "\(label) must be between 0 and 16383."
            )
        }
    }

    private static func validateActiveTarget(_ target: Int, label: String) throws {
        guard (1 ... 16_383).contains(target) else {
            throw ROBServoControlConfigurationError.invalid(
                "\(label) must be between 1 and 16383."
            )
        }
    }

    private static func phaseSort(
        _ lhs: ROBServoSequencePhase,
        _ rhs: ROBServoSequencePhase
    ) -> Bool {
        let sequenceOrder = lhs.sequenceName.localizedCaseInsensitiveCompare(rhs.sequenceName)
        if sequenceOrder != .orderedSame { return sequenceOrder == .orderedAscending }
        if lhs.phaseIndex != rhs.phaseIndex { return lhs.phaseIndex < rhs.phaseIndex }
        return lhs.phaseName.localizedCaseInsensitiveCompare(rhs.phaseName) == .orderedAscending
    }

    private func installDefaults(persist: Bool) {
        lock.lock()
        positionsStorage = Self.defaultPositions()
        phasesStorage = Self.defaultPhases()
        gesturesStorage = Self.defaultGestures()
        if persist { persistLocked() }
        lock.unlock()
    }

    private static func defaultPositions() -> [ROBServoCameraPosition] {
        [
            ROBServoCameraPosition(
                name: "lean_forward", panTarget: 0,
                lowerTarget: 7014, upperTarget: 7698
            ),
            ROBServoCameraPosition(
                name: "upright", panTarget: 0,
                lowerTarget: 6011, upperTarget: 6906
            ),
            ROBServoCameraPosition(
                name: "lean_back", panTarget: 0,
                lowerTarget: 4747, upperTarget: 5214
            ),
            ROBServoCameraPosition(
                name: "fully_upright_right", panTarget: 4000,
                lowerTarget: 6011, upperTarget: 6906
            ),
            ROBServoCameraPosition(
                name: "fully_upright_left", panTarget: 7652,
                lowerTarget: 6011, upperTarget: 6906
            ),
        ]
    }

    private static func appendMissingUprightPanEndpointPositions(
        to positions: inout [ROBServoCameraPosition]
    ) {
        for endpoint in [
            (canonical: "fully_upright_right", legacy: "fully_right", pan: 4000),
            (canonical: "fully_upright_left", legacy: "fully_left", pan: 7652),
        ] {
            let hasCanonical = positions.contains {
                $0.name.caseInsensitiveCompare(endpoint.canonical) == .orderedSame
            }
            if hasCanonical { continue }
            if let legacy = positions.first(where: {
                $0.name.caseInsensitiveCompare(endpoint.legacy) == .orderedSame
            }) {
                positions.append(ROBServoCameraPosition(
                    name: endpoint.canonical,
                    panTarget: legacy.panTarget,
                    lowerTarget: legacy.lowerTarget,
                    upperTarget: legacy.upperTarget
                ))
            } else {
                positions.append(ROBServoCameraPosition(
                    name: endpoint.canonical, panTarget: endpoint.pan,
                    lowerTarget: 6011, upperTarget: 6906
                ))
            }
        }
    }

    private static func defaultPhases() -> [ROBServoSequencePhase] {
        [
            ROBServoSequencePhase(
                sequenceName: "startup", phaseIndex: 1,
                phaseName: "Lift to upright clearance", cameraPositionName: "upright",
                panTarget: 0, lowerTarget: 6011, upperTarget: 6906, holdSeconds: 0
            ),
            ROBServoSequencePhase(
                sequenceName: "startup", phaseIndex: 2,
                phaseName: "Center pan", cameraPositionName: "upright",
                panTarget: 5799, lowerTarget: 6011, upperTarget: 6906, holdSeconds: 0
            ),
            ROBServoSequencePhase(
                sequenceName: "startup", phaseIndex: 3,
                phaseName: "Lean forward", cameraPositionName: "lean_forward",
                panTarget: 5799, lowerTarget: 7014, upperTarget: 7698, holdSeconds: 0
            ),
        ]
    }

    private static func defaultGestures() -> [ROBServoRelativeGesture] {
        [
            ROBServoRelativeGesture(
                name: "YES", servo: "upper", delta: 160,
                repetitions: 2, intervalSeconds: 0.20
            ),
            ROBServoRelativeGesture(
                name: "NO", servo: "pan", delta: 120,
                repetitions: 2, intervalSeconds: 0.20
            ),
        ]
    }

    private struct Payload: Codable {
        var version: Int
        var cameraPositions: [PositionPayload]
        var sequencePhases: [PhasePayload]
        var gestures: [GesturePayload]
    }

    private struct PositionPayload: Codable {
        var identifier: String
        var name: String
        /// Optional so version-1 position records migrate without losing operator edits.
        var panTarget: Int?
        var lowerTarget: Int
        var upperTarget: Int
    }

    private struct PhasePayload: Codable {
        var identifier: String
        var sequenceName: String
        var phaseIndex: Int
        var phaseName: String
        var cameraPositionName: String
        var panTarget: Int
        var lowerTarget: Int
        var upperTarget: Int
        var holdSeconds: Double
    }

    private struct GesturePayload: Codable {
        var identifier: String
        var name: String
        var servo: String
        var delta: Int
        var repetitions: Int
        var intervalSeconds: Double
    }

    /// Migrates only the exact upright tuples shipped before the front-camera
    /// mount correction. A version-2 value of 6073 is an operator calibration
    /// and is therefore left alone on subsequent launches.
    private static func migrateLegacyUprightCameraMountOffset(
        positions: [ROBServoCameraPosition],
        phases: [ROBServoSequencePhase]
    ) -> Bool {
        let uprightPositionNames: Set<String> = [
            "upright",
            "fully_upright_right",
            "fully_upright_left",
            "fully_upright_center",
            "fully_right",
            "fully_left",
        ]
        var changed = false
        for position in positions
        where uprightPositionNames.contains(position.name.lowercased())
            && position.lowerTarget == uprightLowerTarget
            && position.upperTarget == legacyUprightUpperTarget {
            position.upperTarget = uprightUpperTarget
            changed = true
        }
        for phase in phases
        where phase.sequenceName.caseInsensitiveCompare("startup") == .orderedSame
            && (phase.phaseIndex == 1 || phase.phaseIndex == 2)
            && phase.cameraPositionName.caseInsensitiveCompare("upright") == .orderedSame
            && phase.lowerTarget == uprightLowerTarget
            && phase.upperTarget == legacyUprightUpperTarget {
            phase.upperTarget = uprightUpperTarget
            changed = true
        }
        return changed
    }

    /// Speeds up only the exact YES/NO definitions shipped through version 2.
    /// Operator-edited gesture amplitudes, axes, repetitions, or intervals stay
    /// authoritative when the configuration is loaded by a newer build.
    private static func migrateLegacyGestureCadence(
        gestures: [ROBServoRelativeGesture]
    ) -> Bool {
        var changed = false
        for gesture in gestures {
            let isLegacyYes = gesture.name.caseInsensitiveCompare("YES") == .orderedSame
                && gesture.servo.caseInsensitiveCompare("upper") == .orderedSame
                && gesture.delta == 160
            let isLegacyNo = gesture.name.caseInsensitiveCompare("NO") == .orderedSame
                && gesture.servo.caseInsensitiveCompare("pan") == .orderedSame
                && gesture.delta == 120
            guard (isLegacyYes || isLegacyNo),
                  gesture.repetitions == 2,
                  gesture.intervalSeconds == 0.35 else {
                continue
            }
            gesture.intervalSeconds = 0.20
            changed = true
        }
        return changed
    }

    private func persistLocked() {
        let payload = Payload(
            version: Self.schemaVersion,
            cameraPositions: positionsStorage.map {
                PositionPayload(
                    identifier: $0.identifier, name: $0.name,
                    panTarget: $0.panTarget,
                    lowerTarget: $0.lowerTarget, upperTarget: $0.upperTarget
                )
            },
            sequencePhases: phasesStorage.map {
                PhasePayload(
                    identifier: $0.identifier, sequenceName: $0.sequenceName,
                    phaseIndex: $0.phaseIndex, phaseName: $0.phaseName,
                    cameraPositionName: $0.cameraPositionName,
                    panTarget: $0.panTarget, lowerTarget: $0.lowerTarget,
                    upperTarget: $0.upperTarget, holdSeconds: $0.holdSeconds
                )
            },
            gestures: gesturesStorage.map {
                GesturePayload(
                    identifier: $0.identifier, name: $0.name, servo: $0.servo,
                    delta: $0.delta, repetitions: $0.repetitions,
                    intervalSeconds: $0.intervalSeconds
                )
            }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func loadPersistedConfiguration() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (1 ... Self.schemaVersion).contains(payload.version) else {
            return false
        }
        let positionsNeedPanMigration = payload.cameraPositions.contains {
            $0.panTarget == nil
        }
        var positions = payload.cameraPositions.map {
            ROBServoCameraPosition(
                identifier: $0.identifier, name: $0.name,
                panTarget: $0.panTarget ?? 0,
                lowerTarget: $0.lowerTarget, upperTarget: $0.upperTarget
            )
        }
        let persistedPositionCount = positions.count
        Self.appendMissingUprightPanEndpointPositions(to: &positions)
        let phases = payload.sequencePhases.map {
            ROBServoSequencePhase(
                identifier: $0.identifier, sequenceName: $0.sequenceName,
                phaseIndex: $0.phaseIndex, phaseName: $0.phaseName,
                cameraPositionName: $0.cameraPositionName,
                panTarget: $0.panTarget, lowerTarget: $0.lowerTarget,
                upperTarget: $0.upperTarget, holdSeconds: $0.holdSeconds
            )
        }
        let migratedUprightCameraMountOffset = payload.version < 2
            && Self.migrateLegacyUprightCameraMountOffset(
                positions: positions,
                phases: phases
            )
        let gestures = payload.gestures.map {
            ROBServoRelativeGesture(
                identifier: $0.identifier, name: $0.name, servo: $0.servo,
                delta: $0.delta, repetitions: $0.repetitions,
                intervalSeconds: $0.intervalSeconds
            )
        }
        let migratedGestureCadence = payload.version < 3
            && Self.migrateLegacyGestureCadence(gestures: gestures)
        guard (try? Self.validate(
            cameraPositions: positions,
            sequencePhases: phases,
            gestures: gestures
        )) != nil else {
            return false
        }
        positionsStorage = positions
        phasesStorage = phases.sorted(by: Self.phaseSort)
        gesturesStorage = gestures
        if payload.version != Self.schemaVersion
            || positionsNeedPanMigration
            || positions.count != persistedPositionCount
            || migratedUprightCameraMountOffset
            || migratedGestureCadence {
            persistLocked()
        }
        return true
    }
}
