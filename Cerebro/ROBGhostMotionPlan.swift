import Foundation
import CryptoKit
import simd

enum ROBGhostMotionError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let text) = self { return text }; return nil }
}

/// The bundled canonical URDF drives every displayed joint, including axes
/// that have no commissioned hardware mapping. This type has no motor IO.
final class ROBGhostRobotModel {
    struct Joint {
        let name: String, parent: String, child: String, kind: String
        let origin: simd_double4x4
        let axis: SIMD3<Double>
        let lower: Double, upper: Double
    }
    let directory: URL
    let modelID: String
    let referenceID: String
    let geometryID: String
    let joints: [Joint]
    let reference: [String: Double]
    let hulls: [String: String]
    private let hullBoxes: [String: [SIMD3<Double>]]
    static let uprightPrior = [0.0, 2.080432, 0, -0.687254, 0, 0.027043, 0]
    static let mappingID = hash(Data("upright-prior-2026-09-22:\(uprightPrior);driver-directions:1,1,1,1,1,1,1".utf8))

    init(directory: URL) throws {
        self.directory = directory
        let data = try Data(contentsOf: directory.appendingPathComponent("model.urdf"))
        modelID = Self.hash(data)
        let referenceData = try Data(contentsOf: directory.appendingPathComponent("reference.json"))
        guard let metadata = try JSONSerialization.jsonObject(with: referenceData) as? [String: Any],
              metadata["modelID"] as? String == modelID,
              metadata["simulationOnly"] as? Bool == true,
              let positions = metadata["positions"] as? [String: Double],
              let referenceID = metadata["referenceID"] as? String else {
            throw ROBGhostMotionError.blocked("Bundled URDF and reference do not match.")
        }
        self.referenceID = referenceID; reference = positions
        let xml = try XMLDocument(data: data)
        func attr(_ element: XMLElement, _ name: String) -> String { element.attribute(forName: name)?.stringValue ?? "" }
        func vector(_ text: String, fallback: [Double]) -> [Double] {
            let value = text.split(separator: " ").compactMap { Double($0) }
            return value.count == 3 && value.allSatisfy(\.isFinite) ? value : fallback
        }
        var definitions: [Joint] = []
        for element in try xml.nodes(forXPath: "/robot/joint").compactMap({ $0 as? XMLElement }) {
            guard let parent = element.elements(forName: "parent").first,
                  let child = element.elements(forName: "child").first else { continue }
            let origin = element.elements(forName: "origin").first
            let xyz = vector(origin.map { attr($0, "xyz") } ?? "", fallback: [0, 0, 0])
            let rpy = vector(origin.map { attr($0, "rpy") } ?? "", fallback: [0, 0, 0])
            var transform = simd_double4x4(simd_quatd(angle: rpy[2], axis: [0, 0, 1])
                * simd_quatd(angle: rpy[1], axis: [0, 1, 0]) * simd_quatd(angle: rpy[0], axis: [1, 0, 0]))
            transform.columns.3 = SIMD4(xyz[0], xyz[1], xyz[2], 1)
            let axis = vector(element.elements(forName: "axis").first.map { attr($0, "xyz") } ?? "", fallback: [0, 0, 1])
            let limit = element.elements(forName: "limit").first
            definitions.append(Joint(name: attr(element, "name"), parent: attr(parent, "link"), child: attr(child, "link"),
                kind: attr(element, "type"), origin: transform, axis: simd_normalize(SIMD3(axis[0], axis[1], axis[2])),
                lower: limit.flatMap { Double(attr($0, "lower")) } ?? 0,
                upper: limit.flatMap { Double(attr($0, "upper")) } ?? 0))
        }
        guard !definitions.isEmpty, Set(definitions.map(\.name)).count == definitions.count else {
            throw ROBGhostMotionError.blocked("Invalid URDF joint catalog.")
        }
        joints = definitions
        let surfacesData = try Data(contentsOf: directory.appendingPathComponent("surfaces.json"))
        geometryID = Self.hash(surfacesData)
        guard Self.hash(surfacesData) == metadata["surfacesSHA256"] as? String,
              let surfaces = try JSONSerialization.jsonObject(with: surfacesData) as? [String: Any],
              surfaces["modelID"] as? String == modelID,
              let entries = surfaces["surfaces"] as? [[String: Any]] else {
            throw ROBGhostMotionError.blocked("Robot surfaces do not match the URDF.")
        }
        var paths: [String: String] = [:]
        for entry in entries {
            guard let link = entry["link"] as? String, let path = entry["hull"] as? String,
                  !path.contains(".."), !path.hasPrefix("/"),
                  let expected = entry["hullSHA256"] as? String,
                  Self.hash(try Data(contentsOf: directory.appendingPathComponent(path))) == expected else {
                throw ROBGhostMotionError.blocked("Robot surface hash mismatch.")
            }
            paths[link] = path
        }
        hulls = paths
        var boxes: [String: [SIMD3<Double>]] = [:]
        for (link, path) in paths {
            let text = try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
            let points = text.split(separator: "\n").compactMap { line -> SIMD3<Double>? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.first == "v", parts.count >= 4, let x = Double(parts[1]),
                      let y = Double(parts[2]), let z = Double(parts[3]), [x, y, z].allSatisfy(\.isFinite) else { return nil }
                return SIMD3(x, y, z)
            }
            guard let first = points.first else { throw ROBGhostMotionError.blocked("Empty collision hull.") }
            let low = points.reduce(first) { simd_min($0, $1) }, high = points.reduce(first) { simd_max($0, $1) }
            boxes[link] = [low.x, high.x].flatMap { x in [low.y, high.y].flatMap { y in [low.z, high.z].map { SIMD3(x, y, $0) } } }
        }
        hullBoxes = boxes
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func frames(_ positions: [String: Double]) -> [String: simd_double4x4] {
        var result = ["base_link": matrix_identity_double4x4]
        for _ in 0..<joints.count {
            for joint in joints where result[joint.child] == nil {
                guard let parent = result[joint.parent] else { continue }
                let value = positions[joint.name] ?? reference[joint.name] ?? 0
                var motion = matrix_identity_double4x4
                if joint.kind == "revolute" || joint.kind == "continuous" {
                    motion = simd_double4x4(simd_quatd(angle: value, axis: joint.axis))
                } else if joint.kind == "prismatic" { motion.columns.3 = SIMD4(joint.axis * value, 1) }
                result[joint.child] = parent * joint.origin * motion
            }
        }
        return result
    }
    func positions(vendorLeft: [Double]) -> [String: Double] {
        var result = reference
        guard vendorLeft.count == 7 else { return result }
        for index in 0..<7 { result["left_joint\(index + 1)"] = vendorLeft[index] - Self.uprightPrior[index] }
        return result
    }
    func vendorLeft(_ positions: [String: Double]) -> [Double] {
        (0..<7).map { (positions["left_joint\($0 + 1)"] ?? reference["left_joint\($0 + 1)"] ?? 0) + Self.uprightPrior[$0] }
    }
    func toolPosition(_ positions: [String: Double]) -> SIMD3<Double>? {
        guard let frame = frames(positions)["left_tool"] else { return nil }
        return SIMD3(frame.columns.3.x, frame.columns.3.y, frame.columns.3.z)
    }
    /// Conservative rigid-model AABB separation. This does not account for
    /// unmeasured cables, mounting errors, payloads or people.
    func treadSeparation(vendorLeft: [Double]) -> Double {
        let transforms = frames(positions(vendorLeft: vendorLeft))
        var bounds: [String: (SIMD3<Double>, SIMD3<Double>)] = [:]
        for (link, corners) in hullBoxes {
            guard let frame = transforms[link] else { continue }
            let points = corners.map { point -> SIMD3<Double> in
                let p = frame * SIMD4(point, 1); return SIMD3(p.x, p.y, p.z)
            }
            bounds[link] = (points.reduce(points[0]) { simd_min($0, $1) }, points.reduce(points[0]) { simd_max($0, $1) })
        }
        let arms = bounds.keys.filter { $0.hasPrefix("left_") && ($0.hasSuffix("_Link") || $0 == "left_tool") }
        let treads = bounds.keys.filter { $0.contains("track") || $0.contains("flipper") || $0.contains("sprocket") }
        var minimum = Double.infinity
        for arm in arms {
            for tread in treads {
                let a = bounds[arm]!, b = bounds[tread]!
                minimum = min(minimum, simd_length(simd_max(.zero, simd_max(a.0 - b.1, b.0 - a.1))))
            }
        }
        return minimum
    }
    /// Bounded position-only numerical IK for preview. No motor command is
    /// generated here; the separate proposal compiler enforces execution scope.
    func solveLeft(target: SIMD3<Double>, from initial: [String: Double], frontWorkspace: Bool = false) -> [String: Double]? {
        guard target.x.isFinite, target.y.isFinite, target.z.isFinite else { return nil }
        var q = initial
        let chain = joints.filter { $0.name.hasPrefix("left_joint") && $0.name != "left_joint7" }
        for _ in 0..<250 {
            guard let tip = toolPosition(q) else { return nil }
            let error = target - tip
            if simd_length(error) < 0.004 { return q }
            var columns: [SIMD3<Double>] = []
            for joint in chain {
                let value = q[joint.name] ?? 0
                var shifted = q; shifted[joint.name] = value + 0.0001
                guard let moved = toolPosition(shifted) else { return nil }
                columns.append((moved - tip) / 0.0001)
            }
            var normal = simd_double3x3(diagonal: SIMD3(repeating: 0.0004))
            for column in columns {
                normal.columns.0 += column * column.x
                normal.columns.1 += column * column.y
                normal.columns.2 += column * column.z
            }
            let correction = simd_inverse(normal) * error
            let changes = columns.map { simd_dot($0, correction) }
            let scale = min(1, 0.06 / max(0.000001, changes.map(abs).max() ?? 0))
            for (joint, change) in zip(chain, changes) {
                let index = Int(joint.name.dropFirst("left_joint".count))! - 1
                let bound = ROBLeftGestureCompiler.frontBounds[index]
                let low = frontWorkspace ? max(joint.lower, bound.lowerBound - Self.uprightPrior[index]) : joint.lower
                let high = frontWorkspace ? min(joint.upper, bound.upperBound - Self.uprightPrior[index]) : joint.upper
                q[joint.name] = max(low, min(high, (q[joint.name] ?? 0) + change * scale))
            }
        }
        return toolPosition(q).map { simd_distance($0, target) < 0.012 } == true ? q : nil
    }
}

struct ROBGhostGesture: Codable, Equatable {
    var name: String
    var poses: [[String: Double]]
    var modelID: String
    var referenceID: String
    var geometryID: String
    var kind: String = "custom"
}

/// Immutable, session-bound execution artifact reviewed in the input scene.
/// The model mapping is explicitly a prior for this supervised trial, not a
/// replacement for the queued camera/URDF calibration.
struct ROBLeftGestureProposal: Codable, Equatable {
    struct Step: Codable, Equatable { let positions: [Double]; let seconds: Double }
    let id: UUID
    let name: String
    let kind: String
    let modelID: String
    let referenceID: String
    let geometryID: String
    let mappingID: String
    let sessionGeneration: UInt64
    let baseline: [Double]
    let poses: [[String: Double]]
    let steps: [Step]
    var seconds: Double { steps.reduce(0) { $0 + $1.seconds } }
    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
    var fingerprint: String { (try? encoded()).map(ROBGhostRobotModel.hash) ?? "invalid" }
}

enum ROBLeftGestureCompiler {
    static let maximumScheduledSeconds = 135.0
    static let frontBounds: [ClosedRange<Double>] = [(-1.20)...(-0.75), 0.60...1.20, (-0.65)...(-0.30),
        (-0.60)...0, (-0.65)...(-0.30), (-0.60)...0, (-0.001)...0.001]

    static func compile(kind: String, name: String, poses: [[String: Double]] = [], model: ROBGhostRobotModel,
                        baseline: [Double], generation: UInt64, id: UUID = UUID()) throws -> ROBLeftGestureProposal {
        guard baseline.count == 7, baseline.allSatisfy(\.isFinite), generation > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              ["center", "wave", "custom", "lower"].contains(kind), poses.count <= 12 else {
            throw ROBGhostMotionError.blocked("Invalid gesture or missing live gateway session.")
        }
        guard let route = ROBLeftArmInteractionPlan.route(from: baseline, hanging: kind == "lower", waving: kind == "wave") else {
            throw ROBGhostMotionError.blocked("Start from the known arm route. A stopped custom gesture must be recovered first.")
        }
        var targets = route.compactMap { ROBLeftArmInteractionPlan.target(index: $0) }
        if kind == "wave" {
            targets += [ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex,
                        ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex]
                .compactMap { ROBLeftArmInteractionPlan.target(index: $0) }
        }
        if kind == "custom" {
            guard !poses.isEmpty else { throw ROBGhostMotionError.blocked("Add a ghost pose before executing.") }
            let center = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!
            let original = model.positions(vendorLeft: center)
            var previous = center
            var outgoing: [[Double]] = []
            for pose in poses {
                guard pose.allSatisfy({ key, value in value.isFinite && model.joints.contains(where: { $0.name == key }) }) else {
                    throw ROBGhostMotionError.blocked("Gesture contains an unknown or non-finite joint.")
                }
                for joint in model.joints where !joint.name.hasPrefix("left_joint") {
                    guard abs((pose[joint.name] ?? original[joint.name] ?? 0) - (original[joint.name] ?? 0)) < 0.000001 else {
                        throw ROBGhostMotionError.blocked("\(joint.name) is preview-only until its hardware mapping is calibrated. Physical execution currently supports the left arm.")
                    }
                }
                let target = model.vendorLeft(pose)
                guard zip(target, frontBounds).allSatisfy({ $1.contains($0) }) else {
                    throw ROBGhostMotionError.blocked("Keep custom poses inside the supervised front workspace: J1 −1.20…−0.75, J2 0.60…1.20, J3/J5 −0.65…−0.30, J4/J6 −0.60…0; J7 unchanged. Other poses can be previewed and saved.")
                }
                let delta = zip(previous, target).map { abs($0 - $1) }.max() ?? 0
                // Bound unsampled point travel by 5 mm using a conservative
                // 1.5 m lever per changing arm joint. Require 25+5 mm in the
                // provisional rigid model; physical supervision still applies.
                let travel = 1.5 * zip(previous, target).reduce(0.0) { $0 + abs($1.0 - $1.1) }
                let checks = max(1, Int(ceil(travel / 0.01)))
                for check in 0...checks {
                    let t = Double(check) / Double(checks)
                    let q = zip(previous, target).map { $0 + ($1 - $0) * t }
                    guard model.treadSeparation(vendorLeft: q) >= 0.030 else {
                        throw ROBGhostMotionError.blocked("Custom ghost path enters the model's tread clearance margin. Adjust the target before review.")
                    }
                }
                let count = max(1, Int(ceil(delta / 0.1)))
                for index in 1...count {
                    let fraction = Double(index) / Double(count)
                    outgoing.append(zip(previous, target).map { $0 + ($1 - $0) * fraction })
                }
                previous = target
            }
            // A successful custom rendition always returns through its own
            // approved points to the known center pose before ending.
            targets += outgoing
            targets += outgoing.dropLast().reversed()
            targets.append(center)
        }
        var previous = baseline
        var steps: [ROBLeftGestureProposal.Step] = []
        for target in targets {
            // Preserve the existing speed/jerk timing with extra allowance
            // for the measured endpoint tolerance. No speed increase here.
            let delta = zip(previous, target).map { abs($0 - $1) }.max() ?? 0
            let padded = delta + ROBArmRoutinePlan.tolerance
            let seconds = max(0.8, padded / ROBArmRoutinePlan.maximumAverageSpeed, 4 * pow(padded / 0.3, 1.0 / 3.0))
            guard seconds <= 5 else { throw ROBGhostMotionError.blocked("A gesture segment exceeds the bounded timing window.") }
            steps.append(.init(positions: target, seconds: seconds)); previous = target
        }
        guard !steps.isEmpty, steps.count <= 80, steps.reduce(0, { $0 + $1.seconds }) <= maximumScheduledSeconds else {
            throw ROBGhostMotionError.blocked("Gesture is too long for one supervised operation. Center the hand first or use fewer poses.")
        }
        return ROBLeftGestureProposal(id: id, name: name, kind: kind, modelID: model.modelID, referenceID: model.referenceID,
            geometryID: model.geometryID, mappingID: ROBGhostRobotModel.mappingID,
            sessionGeneration: generation, baseline: baseline, poses: poses, steps: steps)
    }

    static func validate(_ proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel) throws {
        guard proposal.modelID == model.modelID, proposal.referenceID == model.referenceID,
              proposal.geometryID == model.geometryID, proposal.mappingID == ROBGhostRobotModel.mappingID else {
            throw ROBGhostMotionError.blocked("The robot model changed; rebuild and review this proposal.")
        }
        let expected = try compile(kind: proposal.kind, name: proposal.name, poses: proposal.poses, model: model,
            baseline: proposal.baseline, generation: proposal.sessionGeneration, id: proposal.id)
        guard proposal == expected else { throw ROBGhostMotionError.blocked("The reviewed path or timing changed; review a new proposal.") }
    }
}

struct ROBGhostRecordingSample {
    let time: Double, positions: [Double], currents: [Double], deltas: [Double]
    let step: Int
    static func load(_ url: URL) throws -> [Self] {
        let data = try Data(contentsOf: url)
        guard data.count <= 30_000_000, let text = String(data: data, encoding: .utf8) else {
            throw ROBGhostMotionError.blocked("Recording is too large or unreadable.")
        }
        let lines = text.split(separator: "\n")
        guard lines.first?.hasPrefix("elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,") == true else {
            throw ROBGhostMotionError.blocked("Choose a Cerebro left-arm current CSV.")
        }
        var result: [Self] = []; var rows: [[String]] = []; var lastSequence: UInt64 = 0
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10 else { throw ROBGhostMotionError.blocked("Recording contains a malformed row; replay was stopped.") }
            rows.append(fields)
            if rows.count == 7 {
                defer { rows = [] }
                guard let time = Double(rows[0][0]), time.isFinite, time >= 0, time >= (result.last?.time ?? 0),
                      let sequence = UInt64(rows[0][1]), sequence > lastSequence,
                      rows.allSatisfy({ $0[1] == rows[0][1] && $0[2] == "left" && $0[3] == "right" }),
                      rows.enumerated().allSatisfy({ Int($0.element[4]) == $0.offset + 1 }) else {
                    throw ROBGhostMotionError.blocked("Recording has missing, reordered or invalid joint samples.")
                }
                let q = rows.compactMap { Double($0[5]) }, currents = rows.compactMap { Double($0[6]) }
                let deltas = rows.compactMap { Double($0[7]) }
                guard q.count == 7, currents.count == 7, deltas.count == 7, (q + currents + deltas).allSatisfy(\.isFinite) else {
                    throw ROBGhostMotionError.blocked("Recording contains non-finite current or position values.")
                }
                let phase = rows[0][9]; let step = phase.hasPrefix("gesture step ") ? Int(phase.dropFirst(13)) ?? -1 : -1
                result.append(Self(time: time, positions: q, currents: currents, deltas: deltas, step: step))
                lastSequence = sequence
            }
        }
        guard !result.isEmpty, rows.isEmpty else { throw ROBGhostMotionError.blocked("Recording has no complete samples or ends with an incomplete joint sample.") }
        return result
    }
}
