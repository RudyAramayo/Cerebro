import Foundation
import CryptoKit
import simd

enum ROBGhostMotionError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let text) = self { return text }; return nil }
}

/// Accepted Maestro commands converted once for the model and its camera.
/// These are command-space mounting priors, not shaft feedback.
@objcMembers final class ROBHeadCameraPoseEstimator: NSObject {
    // Operator-observed vertical neck / forward OAK posture. The driver's
    // safety/clearance targets are separate and must not define visual zero.
    static let displayUprightLowerTarget = 6011
    static let displayLevelUpperTarget = 6906
    let panRadians: Double
    let lowerPitch: Double
    let upperPitch: Double
    let lowerTarget: Int
    let upperTarget: Int

    private init(panRadians: Double, lowerPitch: Double, upperPitch: Double,
                 lowerTarget: Int, upperTarget: Int) {
        self.panRadians = panRadians; self.lowerPitch = lowerPitch; self.upperPitch = upperPitch
        self.lowerTarget = lowerTarget; self.upperTarget = upperTarget
    }

    @objc(estimateDisplayPanRadians:lowerTarget:upperTarget:known:)
    static func estimateDisplay(panRadians: Double, lowerTarget: Int, upperTarget: Int,
                                known: Bool) -> ROBHeadCameraPoseEstimator? {
        estimate(panRadians: panRadians, lowerTarget: lowerTarget, upperTarget: upperTarget,
                 uprightLowerTarget: displayUprightLowerTarget,
                 levelUpperTarget: displayLevelUpperTarget, known: known)
    }

    @objc(estimatePanRadians:lowerTarget:upperTarget:uprightLowerTarget:levelUpperTarget:known:)
    static func estimate(panRadians: Double, lowerTarget: Int, upperTarget: Int,
                         uprightLowerTarget: Int, levelUpperTarget: Int, known: Bool) -> ROBHeadCameraPoseEstimator? {
        guard known, panRadians.isFinite,
              [lowerTarget, upperTarget, uprightLowerTarget, levelUpperTarget].allSatisfy({ (1...16383).contains($0) }) else { return nil }
        let radiansPerTarget = Double.pi / (180 * 33.3333333333)
        return ROBHeadCameraPoseEstimator(panRadians: panRadians,
            lowerPitch: Double(lowerTarget - uprightLowerTarget) * radiansPerTarget,
            upperPitch: Double(upperTarget - levelUpperTarget) * radiansPerTarget,
            lowerTarget: lowerTarget, upperTarget: upperTarget)
    }
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
    /// Physical identity is carried through FK, collision hulls and proposal hashes.
    let physicalSide: String
    var armJointPrefix: String { physicalSide + "_joint" }
    var toolLink: String { physicalSide + "_tool" }
    var selectedMappingID: String {
        physicalSide == "left" ? Self.mappingID : Self.hash(Data("right-scan-reference-prior-v1:\(referenceID):\(armUprightPrior);driver-directions:1,1,1,1,1,1,1".utf8))
    }
    /// Right values come from its own recorded model reference. They remain a
    /// prior, not an accepted absolute encoder calibration or reflected left fit.
    var armUprightPrior: [Double] {
        physicalSide == "left" ? Self.uprightPrior : (1...7).map { -(reference["right_joint\($0)"] ?? 0) }
    }
    var recyclingFrontTarget: [Double] {
        physicalSide == "left" ? ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!
            : [1.05,-0.60,0,0,0,0,0]
    }
    let modelID: String
    let referenceID: String
    let geometryID: String
    let joints: [Joint]
    let reference: [String: Double]
    let hulls: [String: String]
    private let hullBoxes: [String: [SIMD3<Double>]]
    static let uprightPrior = [0.0, 2.080432, 0, -0.687254, 0, 0.027043, 0]
    static let mappingID = hash(Data("upright-prior-2026-09-22:\(uprightPrior);driver-directions:1,1,1,1,1,1,1".utf8))

    init(directory: URL, physicalSide: String = "left") throws {
        guard ["left","right"].contains(physicalSide) else { throw ROBGhostMotionError.blocked("Unknown physical arm.") }
        self.physicalSide = physicalSide
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
            // Once every child frame exists, further dependency passes cannot
            // add or alter a transform. IK and swept-path checks call this
            // thousands of times, so avoid walking the completed tree again.
            if result.count == joints.count+1 { break }
        }
        return result
    }
    /// Legacy argument label retained for saved callers; values always refer
    /// to this model instance's explicit physicalSide, never both arms.
    func positions(vendorLeft: [Double]) -> [String: Double] {
        var result = reference
        guard vendorLeft.count == 7 else { return result }
        for index in 0..<7 { result["\(armJointPrefix)\(index + 1)"] = vendorLeft[index] - armUprightPrior[index] }
        return result
    }
    /// Display-only Maestro-to-URDF prior. Upright/level accepted commands
    /// map to zero neck angles, not the lean-back scan's captured joint pose.
    /// All three joints feed the same FK used for the mesh and depth camera.
    func headPositions(pan: Double, lowerPitch: Double, upperPitch: Double) -> [String: Double]? {
        guard [pan, lowerPitch, upperPitch].allSatisfy(\.isFinite) else { return nil }
        // The two Maestro pitch servos have opposing mechanical directions.
        // Increasing both targets counter-rotates the upper head as the lower
        // neck leans forward; summing them incorrectly aimed the cloud upward.
        let values = ["lower_neck": lowerPitch, "neck_pan": pan,
                      "upper_neck": -upperPitch]
        guard values.allSatisfy({ name, value in
            joints.contains { $0.name == name && ($0.lower...$0.upper).contains(value) }
        }) else { return nil }
        return values
    }
    func vendorLeft(_ positions: [String: Double]) -> [Double] {
        (0..<7).map { (positions["\(armJointPrefix)\($0 + 1)"] ?? reference["\(armJointPrefix)\($0 + 1)"] ?? 0) + armUprightPrior[$0] }
    }
    func toolPosition(_ positions: [String: Double]) -> SIMD3<Double>? {
        guard let frame = frames(positions)[toolLink] else { return nil }
        return SIMD3(frame.columns.3.x, frame.columns.3.y, frame.columns.3.z)
    }
    /// Conservative rigid-model AABB separation. This does not account for
    /// unmeasured cables, mounting errors, payloads or people.
    func treadSeparation(vendorLeft: [Double]) -> Double {
        let bounds = worldCollisionBounds(positions:positions(vendorLeft:vendorLeft))
        let arms = bounds.keys.filter { $0.hasPrefix(physicalSide + "_") && ($0.hasSuffix("_Link") || $0 == toolLink) }
        let treads = bounds.keys.filter { $0.contains("track") || $0.contains("flipper") || $0.contains("sprocket") }
        var minimum = Double.infinity
        for arm in arms {
            for tread in treads {
                let a = bounds[arm]!, b = bounds[tread]!
                minimum = min(minimum, simd_length(simd_max(.zero, simd_max(a.low - b.high, b.low - a.high))))
            }
        }
        return minimum
    }
    /// Exact world AABBs of the verified model's local collision boxes. Used
    /// by depth self filtering and full-arm workspace checking, never as a
    /// claim that a model prior is a measured camera/arm registration.
    func worldCollisionBounds(positions: [String:Double]) -> [String:(low:SIMD3<Double>,high:SIMD3<Double>)] {
        let transforms = frames(positions)
        var bounds: [String:(low:SIMD3<Double>,high:SIMD3<Double>)] = [:]
        for (link, corners) in hullBoxes {
            guard let frame = transforms[link] else { continue }
            let points = corners.map { point -> SIMD3<Double> in
                let p = frame * SIMD4(point, 1); return SIMD3(p.x, p.y, p.z)
            }
            bounds[link] = (points.reduce(points[0]) { simd_min($0, $1) }, points.reduce(points[0]) { simd_max($0, $1) })
        }
        return bounds
    }
    /// Bounded position-only numerical IK for preview. No motor command is
    /// generated here; the separate proposal compiler enforces execution scope.
    func solveLeft(target: SIMD3<Double>, from initial: [String: Double], frontWorkspace: Bool = false) -> [String: Double]? {
        guard target.x.isFinite, target.y.isFinite, target.z.isFinite else { return nil }
        var q = initial
        let chain = joints.filter { $0.name.hasPrefix(armJointPrefix) && $0.name != armJointPrefix + "7" }
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
                let index = Int(joint.name.dropFirst(armJointPrefix.count))! - 1
                let bound = physicalSide == "left" ? ROBLeftGestureCompiler.frontBounds[index] : ROBArmJointLimits.radians[index]
                let low = frontWorkspace ? max(joint.lower, bound.lowerBound - armUprightPrior[index]) : joint.lower
                let high = frontWorkspace ? min(joint.upper, bound.upperBound - armUprightPrior[index]) : joint.upper
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
    enum JawAction: String, Codable { case prepare, grip, release }
    struct Step: Codable, Equatable {
        let positions: [Double]
        let seconds: Double
        // Optional for compatibility with existing saved gestures/recordings.
        // Performed only after measured arrival and a confirmed position hold.
        var jawAction: JawAction? = nil
        var stage: String? = nil
    }
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
    var recyclingActions: [Int: JawAction]? = nil
    var recyclingParameters: ROBRecyclingTestParameters? = nil
    var workspaceCollisionPlan: ROBWorkspaceCollisionPlan? = nil
    var workspaceApproachPlan: ROBWorkspaceCollisionPlan? = nil
    var seconds: Double { steps.reduce(0) { $0 + $1.seconds } }
    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
    var fingerprint: String { (try? encoded()).map(ROBGhostRobotModel.hash) ?? "invalid" }
    /// Historical recordings need identity/shape checks, not recompilation
    /// against today's gesture angles. This never authorizes execution.
    func validForReplay(model: ROBGhostRobotModel) -> Bool {
        modelID == model.modelID && referenceID == model.referenceID && geometryID == model.geometryID &&
            mappingID == model.selectedMappingID && baseline.count == 7 && baseline.allSatisfy(\.isFinite) &&
            !steps.isEmpty && steps.count <= 80 && steps.allSatisfy {
                $0.positions.count == 7 && $0.positions.allSatisfy { $0.isFinite && abs($0) <= 3.1 } &&
                $0.seconds.isFinite && (ROBArmRoutinePlan.minimumLeasedTrajectorySeconds...5).contains($0.seconds)
            }
    }
}

enum ROBLeftGestureCompiler {
    static let maximumScheduledSeconds = 135.0
    static let frontBounds: [ClosedRange<Double>] = [(-1.20)...(-0.75), 0.60...1.20, (-0.65)...(-0.30),
        (-0.60)...0, (-0.65)...(-0.30), (-0.60)...0, (-0.001)...0.001]

    static func compile(kind: String, name: String, poses: [[String: Double]] = [], model: ROBGhostRobotModel,
                        baseline: [Double], generation: UInt64, id: UUID = UUID(),
                        recyclingActions: [Int: ROBLeftGestureProposal.JawAction]? = nil,
                        recyclingParameters: ROBRecyclingTestParameters? = nil,
                        workspaceCollisionPlan: ROBWorkspaceCollisionPlan? = nil,
                        workspaceApproachPlan: ROBWorkspaceCollisionPlan? = nil,
                        collisionMap: (any ROBWorkspaceCollisionMap)? = nil,
                        collisionSceneID: UUID? = nil, collisionCameraGeneration: UUID? = nil,
                        nowMilliseconds: Double = Date().timeIntervalSince1970*1000) throws -> ROBLeftGestureProposal {
        func checked(_ proposal: ROBLeftGestureProposal) throws -> ROBLeftGestureProposal {
            guard let path = workspaceCollisionPlan else { return proposal }
            guard let map = collisionMap, let sceneID = collisionSceneID, let camera = collisionCameraGeneration,
                  path.baseline == proposal.baseline, path.steps == proposal.steps else {
                throw ROBGhostMotionError.blocked("The complete arm path needs its matching live workspace map before review.")
            }
            try path.validate(map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:camera,nowMilliseconds:nowMilliseconds)
            var result = proposal; result.workspaceCollisionPlan = path; return result
        }
        guard kind == "recycling" || workspaceApproachPlan == nil else {
            throw ROBGhostMotionError.blocked("A recycling approach cannot alter another gesture type.")
        }
        if kind == "workspace_collision" {
            guard let path = workspaceCollisionPlan, path.baseline == baseline,
                  path.steps.allSatisfy({ $0.jawAction == nil }), recyclingParameters == nil, recyclingActions == nil,
                  !name.isEmpty, name.count <= 100 else {
                throw ROBGhostMotionError.blocked("A workspace connector needs a complete frozen collision plan and cannot contain gripper actions.")
            }
            return try checked(.init(id:id,name:name,kind:kind,modelID:model.modelID,referenceID:model.referenceID,
                geometryID:model.geometryID,mappingID:model.selectedMappingID,sessionGeneration:generation,
                baseline:baseline,poses:path.steps.map { model.positions(vendorLeft:$0.positions) },steps:path.steps))
        }
        if kind == "recycling" {
            var bodyBaseline = baseline
            if let entry = workspaceApproachPlan {
                let front = model.recyclingFrontTarget
                guard entry.baseline == baseline, entry.goal == front, !entry.steps.isEmpty,
                      entry.steps.allSatisfy({ $0.jawAction == nil }),
                      let map = collisionMap, let sceneID = collisionSceneID, let camera = collisionCameraGeneration else {
                    throw ROBGhostMotionError.blocked("The complete recycling approach needs a matching live map and an exact front endpoint before any arm movement.")
                }
                try entry.validate(map:map,model:model,generation:generation,sceneID:sceneID,cameraGeneration:camera,nowMilliseconds:nowMilliseconds)
                bodyBaseline = entry.goal
            }
            let body = try ROBHorizontalCanRecycle.compile(name:name,poses:poses,actions:recyclingActions ?? [:],
                model:model,baseline:bodyBaseline,generation:generation,id:id,parameters:recyclingParameters)
            guard let entry = workspaceApproachPlan else { return try checked(body) }
            let combined = entry.steps+body.steps
            guard combined.count <= 80, combined.reduce(0,{ $0+$1.seconds }) <= maximumScheduledSeconds else {
                throw ROBGhostMotionError.blocked("The complete approach and recycling path exceed one bounded operation.")
            }
            return try checked(.init(id:body.id,name:body.name,kind:body.kind,modelID:body.modelID,referenceID:body.referenceID,
                geometryID:body.geometryID,mappingID:body.mappingID,sessionGeneration:body.sessionGeneration,baseline:baseline,
                poses:body.poses,steps:combined,recyclingActions:body.recyclingActions,recyclingParameters:body.recyclingParameters,
                workspaceApproachPlan:entry))
        }
        guard model.physicalSide == "left" else { throw ROBGhostMotionError.blocked("Right-arm execution currently supports dynamically checked recycling/connectors only.") }
        guard recyclingParameters == nil else { throw ROBGhostMotionError.blocked("Recycling sandbox parameters cannot alter another gesture type.") }
        if kind == "tabletop" {
            return try checked(ROBTabletopPickPlace.compile(name: name, poses: poses, model: model,
                baseline: baseline, generation: generation, id: id))
        }
        guard baseline.count == 7, baseline.allSatisfy(\.isFinite), generation > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              ["center", "wave", "custom", "lower"].contains(kind), poses.count <= 12 else {
            throw ROBGhostMotionError.blocked("Invalid gesture or missing live gateway session.")
        }
        guard let route = ROBLeftArmInteractionPlan.executionRoute(from: baseline, hanging: kind == "lower", waving: kind == "wave") else {
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
                for joint in model.joints where !joint.name.hasPrefix(model.armJointPrefix) {
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
        for target in compactRoute(baseline: baseline, targets: targets) {
            let seconds = ROBLeftArmInteractionPlan.duration(from: previous, to: target,
                padding: ROBArmRoutinePlan.tolerance)!
            guard seconds <= 5 else { throw ROBGhostMotionError.blocked("A gesture segment exceeds the bounded timing window.") }
            steps.append(.init(positions: target, seconds: seconds)); previous = target
        }
        guard !steps.isEmpty, steps.count <= 80, steps.reduce(0, { $0 + $1.seconds }) <= maximumScheduledSeconds else {
            throw ROBGhostMotionError.blocked("Gesture is too long for one supervised operation. Center the hand first or use fewer poses.")
        }
        return try checked(ROBLeftGestureProposal(id: id, name: name, kind: kind, modelID: model.modelID, referenceID: model.referenceID,
            geometryID: model.geometryID, mappingID: model.selectedMappingID,
            sessionGeneration: generation, baseline: baseline, poses: poses, steps: steps))
    }

    static func validate(_ proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel,
                         collisionMap: (any ROBWorkspaceCollisionMap)? = nil,
                         collisionSceneID: UUID? = nil, collisionCameraGeneration: UUID? = nil,
                         nowMilliseconds: Double = Date().timeIntervalSince1970*1000) throws {
        guard proposal.modelID == model.modelID, proposal.referenceID == model.referenceID,
              proposal.geometryID == model.geometryID, proposal.mappingID == model.selectedMappingID else {
            throw ROBGhostMotionError.blocked("The robot model changed; rebuild and review this proposal.")
        }
        let expected = try compile(kind: proposal.kind, name: proposal.name, poses: proposal.poses, model: model,
            baseline: proposal.baseline, generation: proposal.sessionGeneration, id: proposal.id,
            recyclingActions: proposal.recyclingActions, recyclingParameters: proposal.recyclingParameters,
            workspaceCollisionPlan:proposal.workspaceCollisionPlan,workspaceApproachPlan:proposal.workspaceApproachPlan,collisionMap:collisionMap,
            collisionSceneID:collisionSceneID,collisionCameraGeneration:collisionCameraGeneration,nowMilliseconds:nowMilliseconds)
        guard proposal == expected else { throw ROBGhostMotionError.blocked("The reviewed path or timing changed; review a new proposal.") }
    }

    /// Remove artificial stops only where the joint-space route is exactly a
    /// straight line in the same direction. Retain every corner and reversal;
    /// a longer segment traverses the same modeled/swept positions.
    static func compactRoute(baseline: [Double], targets: [[Double]]) -> [[Double]] {
        ROBArmRoutinePlan.compactTargetIndices(baseline: baseline, targets: targets).map { targets[$0] }
    }
}

/// Executes the same seven-joint, horizontal-jaw route used in the accepted
/// can rehearsal. Unlike legacy taught tabletop poses this explicitly maps
/// wrist roll and binds the two payload transitions into the frozen proposal.
enum ROBHorizontalCanRecycle {
    static func compile(name: String, poses: [[String: Double]], actions: [Int: ROBLeftGestureProposal.JawAction],
                        model: ROBGhostRobotModel, baseline: [Double], generation: UInt64, id: UUID,
                        parameters: ROBRecyclingTestParameters? = nil) throws -> ROBLeftGestureProposal {
        guard parameters?.isValid ?? true else { throw ROBGhostMotionError.blocked("The recycling sandbox parameters exceed their supported bounds.") }
        guard (10...65).contains(poses.count), baseline.count == 7, baseline.allSatisfy(\.isFinite), generation > 0,
              !name.isEmpty, name.count <= 100, actions.count == 2,
              let grip = actions.first(where: { $0.value == .grip })?.key,
              let release = actions.first(where: { $0.value == .release })?.key,
              grip >= 7, release > grip + 1, release < poses.count - 1,
              let route = model.physicalSide == "left" ? ROBLeftArmInteractionPlan.executionRoute(from: baseline, hanging: false)
                : (ROBArmRoutinePlan.near(baseline,model.recyclingFrontTarget,tolerance:0.001) ? [] : nil) else {
            throw ROBGhostMotionError.blocked("The horizontal recycling route or its jaw boundaries are incomplete.")
        }
        let front = model.recyclingFrontTarget
        let reference = model.positions(vendorLeft: front)
        let targets = try poses.map { pose -> [Double] in
            guard pose.allSatisfy({ key, value in value.isFinite && model.joints.contains { $0.name == key } }) else {
                throw ROBGhostMotionError.blocked("Recycling pose contains an invalid joint.")
            }
            for joint in model.joints {
                let value = pose[joint.name] ?? reference[joint.name] ?? 0
                if joint.name.hasPrefix(model.armJointPrefix), !(joint.lower...joint.upper).contains(value) {
                    throw ROBGhostMotionError.blocked("Recycling exceeds the model limit for \(joint.name).")
                }
                if !joint.name.hasPrefix(model.armJointPrefix), abs(value - (reference[joint.name] ?? 0)) > 0.000001 {
                    throw ROBGhostMotionError.blocked("Recycling may move only the selected physical arm.")
                }
            }
            let target = model.vendorLeft(pose)
            guard target.allSatisfy({ $0.isFinite && abs($0) <= 3.1 }) else { throw ROBGhostMotionError.blocked("Recycling exceeds a transport joint limit.") }
            return target
        }
        guard ROBArmRoutinePlan.near(targets[0], front, tolerance: 0.001),
              ROBArmRoutinePlan.near(targets[grip], targets[grip-1], tolerance: 0.001),
              ROBArmRoutinePlan.near(targets[release], targets[release-1], tolerance: 0.001),
              let grasp = model.toolPosition(poses[grip]), let lift = model.toolPosition(poses[grip+1]),
              let drop = model.toolPosition(poses[release]), let retreat = model.toolPosition(poses.last!),
              (0.015...0.15).contains(lift.z-grasp.z), hypot(lift.x-grasp.x,lift.y-grasp.y) <= 0.10,
              simd_distance(drop,grasp) >= 0.04, retreat.z - drop.z >= 0.04 else {
            throw ROBGhostMotionError.blocked("Recycling needs a stationary grasp, small upward lift, separate release and upward retreat.")
        }
        var steps: [ROBLeftGestureProposal.Step] = [], previous = baseline
        func append(_ target: [Double], stage: String, action: ROBLeftGestureProposal.JawAction? = nil) throws {
            guard let duration = ROBLeftArmInteractionPlan.duration(from: previous, to: target, padding: ROBArmRoutinePlan.tolerance), duration <= 5 else {
                throw ROBGhostMotionError.blocked("A recycling motion exceeds the bounded timing window.")
            }
            steps.append(.init(positions: target, seconds: duration, jawAction: action, stage: stage)); previous = target
        }
        guard let compact = model.physicalSide == "left" ? ROBLeftArmInteractionPlan.compactRoute(from: baseline, indices: route) : [] else {
            throw ROBGhostMotionError.blocked("Start recycling from the registered empty-arm route.")
        }
        for index in compact { try append(ROBLeftArmInteractionPlan.target(index: index)!, stage: "Present empty left arm") }
        if steps.last?.positions == front { steps[steps.count-1].jawAction = .prepare }
        else { try append(front, stage: "Open empty gripper", action: .prepare) }
        for (index, target) in targets.enumerated().dropFirst() {
            let start = previous
            let travel = 1.5 * zip(start,target).reduce(0.0) { $0 + abs($1.0-$1.1) }
            let checks = max(1, Int(ceil(travel/0.01)))
            for sample in 0...checks {
                let t = Double(sample)/Double(checks), q = zip(start,target).map { $0 + ($1-$0)*t }
                guard model.treadSeparation(vendorLeft: q) >= 0.030 else {
                    throw ROBGhostMotionError.blocked("The horizontal recycling path enters the tread clearance margin.")
                }
                if index > 1, let frame = model.frames(model.positions(vendorLeft: q))[model.toolLink] {
                    guard max(abs(frame.columns.1.z),abs(frame.columns.2.z)) <= sin(8 * .pi / 180) else {
                        throw ROBGhostMotionError.blocked("The recycling approach would turn the jaws vertically.")
                    }
                }
            }
            let count = max(1, Int(ceil((zip(start,target).map { abs($0-$1) }.max() ?? 0)/0.30)))
            for part in 1...count {
                let t = Double(part)/Double(count)
                try append(zip(start,target).map { $0+($1-$0)*t }, stage: index < grip ? "Approach can with horizontal jaws" : index == grip ? "Grip can" : index == grip+1 ? "Verification lift" : index < release ? "Lift and carry can" : index == release ? "Release above bucket" : "Retreat above bucket",
                    action: part == count ? actions[index] : nil)
            }
        }
        if let parameters { steps = compactSteps(steps,baseline:baseline,model:model,parameters:parameters) }
        guard steps.count <= 80, steps.reduce(0, { $0+$1.seconds }) <= 135 else {
            throw ROBGhostMotionError.blocked("The recycling path exceeds one bounded operation; bring the objects closer.")
        }
        return .init(id: id, name: name, kind: "recycling", modelID: model.modelID, referenceID: model.referenceID,
            geometryID: model.geometryID, mappingID: model.selectedMappingID, sessionGeneration: generation,
            baseline: baseline, poses: poses, steps: steps, recyclingActions: actions,recyclingParameters:parameters)
    }

    /// Dense IK samples describe a continuous path, not a requirement to stop
    /// every 3 cm. Join only near-straight portions whose replacement chord is
    /// checked against the original joint/tool path and all motion constraints.
    /// Jaw boundaries and their adjacent poses remain independent stops.
    private static func compactSteps(_ steps: [ROBLeftGestureProposal.Step], baseline: [Double], model: ROBGhostRobotModel,
                                parameters: ROBRecyclingTestParameters) -> [ROBLeftGestureProposal.Step] {
        guard !steps.isEmpty else { return steps }
        let protected = Set(steps.indices.filter { index in
            steps[index].jawAction != nil || (index > 0 && steps[index-1].jawAction != nil) ||
            (index+1 < steps.count && steps[index+1].jawAction != nil) || steps[index].stage == "Present empty left arm"
        })
        func timed(_ target: [Double], from start: [Double], stage: String?, action: ROBLeftGestureProposal.JawAction?) -> ROBLeftGestureProposal.Step? {
            guard let minimum = ROBLeftArmInteractionPlan.duration(from:start,to:target),
                  let padded = ROBLeftArmInteractionPlan.duration(from:start,to:target,padding:ROBArmRoutinePlan.tolerance) else { return nil }
            let seconds = max(minimum,padded/parameters.motionPace)
            guard seconds <= 5 else { return nil }
            return .init(positions:target,seconds:seconds,jawAction:action,stage:stage)
        }
        func accepts(from start: [Double], first: Int, last: Int) -> Bool {
            let target = steps[last].positions
            // Keep the existing compiler's maximum single joint increment.
            guard (zip(start,target).map { abs($0-$1) }.max() ?? 0) <= 0.30+1e-9 else { return false }
            let route = [start]+steps[first...last].map(\.positions)
            let lengths = zip(route,route.dropFirst()).map { a,b in zip(a,b).map { abs($0-$1) }.max() ?? 0 }
            let total = lengths.reduce(0,+)
            guard total > 1e-12 else { return true }
            let travel = 1.5*zip(start,target).reduce(0.0) { $0+abs($1.0-$1.1) }
            let checks = max(1,Int(ceil(travel/0.005)))
            var originalIndex = 0, traversed = 0.0
            for sample in 0...checks {
                let t = Double(sample)/Double(checks), distance = total*t
                while originalIndex+1 < lengths.count && traversed+lengths[originalIndex] < distance {
                    traversed += lengths[originalIndex]; originalIndex += 1
                }
                let fraction = lengths[originalIndex] > 1e-12 ? min(1,max(0,(distance-traversed)/lengths[originalIndex])) : 0
                let original = zip(route[originalIndex],route[originalIndex+1]).map { $0+($1-$0)*fraction }
                let q = zip(start,target).map { $0+($1-$0)*t }
                guard zip(original,q).allSatisfy({ abs($0-$1) <= 0.01 }),
                      model.treadSeparation(vendorLeft:q) >= 0.030,
                      let actualFrame = model.frames(model.positions(vendorLeft:q))[model.toolLink],
                      let originalTip = model.toolPosition(model.positions(vendorLeft:original)) else { return false }
                let actualTip = SIMD3(actualFrame.columns.3.x,actualFrame.columns.3.y,actualFrame.columns.3.z)
                guard simd_distance(actualTip,originalTip) <= parameters.maximumPathDeviationMeters+1e-10,
                      // Do not spend the path tolerance by lowering the hand
                      // toward the table along the corresponding original path.
                      actualTip.z >= originalTip.z-0.0005,
                      max(abs(actualFrame.columns.1.z),abs(actualFrame.columns.2.z)) <= sin(8 * .pi/180) else { return false }
            }
            return true
        }
        var result: [ROBLeftGestureProposal.Step] = [], start = baseline, index = 0
        while index < steps.count {
            var end = index
            if !protected.contains(index), parameters.maximumPathDeviationMeters > 0 {
                while end+1 < steps.count, !protected.contains(end+1), steps[end+1].stage == steps[index].stage,
                      accepts(from:start,first:index,last:end+1),
                      timed(steps[end+1].positions,from:start,stage:steps[end+1].stage,action:nil) != nil {
                    end += 1
                }
            }
            let step = steps[end]
            // Registered presentation retains its physically exercised timing.
            let next = step.stage == "Present empty left arm" ? step :
                timed(step.positions,from:start,stage:step.stage,action:step.jawAction) ?? step
            result.append(next); start = step.positions; index = end+1
        }
        return result
    }
}

/// A fixed-station experimental task. The operator teaches five positions;
/// Cerebro chooses the transitions locally inside one immutable approval.
/// Neither image text nor a language model can supply joint targets here.
enum ROBTabletopPickPlace {
    static let stages = ["Pickup approach", "Grasp can", "Small lift", "Bucket release", "Retreat"]
    static let savedKey = "ROBTabletopPickPlace.v1"
    static let intensity = 2

    static func saved() -> ROBGhostGesture? {
        guard let data = UserDefaults.standard.data(forKey: savedKey), data.count <= 200_000,
              let value = try? JSONDecoder().decode(ROBGhostGesture.self, from: data),
              value.kind == "tabletop", value.poses.count == stages.count else { return nil }
        return value
    }

    static func compile(name: String, poses: [[String: Double]], model: ROBGhostRobotModel,
                        baseline: [Double], generation: UInt64, id: UUID = UUID()) throws -> ROBLeftGestureProposal {
        guard poses.count == stages.count, baseline.count == 7, baseline.allSatisfy(\.isFinite), generation > 0,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              let approach = ROBLeftArmInteractionPlan.executionRoute(from: baseline, hanging: false) else {
            throw ROBGhostMotionError.blocked("Teach five tabletop positions: pickup approach, grasp, small lift, bucket release and retreat. Start from the known arm route.")
        }
        let center = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!
        let reference = model.positions(vendorLeft: center)
        var targets: [[Double]] = []
        for pose in poses {
            guard pose.allSatisfy({ key, value in value.isFinite && model.joints.contains(where: { $0.name == key }) }) else {
                throw ROBGhostMotionError.blocked("Tabletop position contains an unknown or invalid joint.")
            }
            for joint in model.joints {
                let value = pose[joint.name] ?? reference[joint.name] ?? 0
                if joint.name.hasPrefix(model.armJointPrefix) {
                    guard (joint.lower...joint.upper).contains(value) else {
                        throw ROBGhostMotionError.blocked("Tabletop position exceeds the URDF limit for \(joint.name).")
                    }
                } else if abs(value - (reference[joint.name] ?? 0)) > 0.000001 {
                    throw ROBGhostMotionError.blocked("Tabletop execution supports only the physical left arm. \(joint.name) is preview-only.")
                }
            }
            let q = model.vendorLeft(pose)
            guard q.allSatisfy({ abs($0) <= 3.1 }), abs(q[6]) <= 0.001 else {
                throw ROBGhostMotionError.blocked("Tabletop joint targets exceed the transport limits; J7 must remain unchanged.")
            }
            targets.append(q)
        }
        guard let grasp = model.toolPosition(poses[1]), let lift = model.toolPosition(poses[2]),
              let bucket = model.toolPosition(poses[3]), lift.z - grasp.z >= 0.015,
              lift.z - grasp.z <= 0.15, hypot(lift.x - grasp.x, lift.y - grasp.y) <= 0.10,
              simd_distance(bucket, grasp) >= 0.04 else {
            throw ROBGhostMotionError.blocked("Teach a small upward test lift (1.5–15 cm, at most 10 cm sideways) and a separate bucket release position. Model distances are provisional.")
        }
        var steps: [ROBLeftGestureProposal.Step] = []
        var previous = baseline
        func append(_ target: [Double], stage: String, action: ROBLeftGestureProposal.JawAction? = nil) throws {
            guard let seconds = ROBLeftArmInteractionPlan.duration(from: previous, to: target,
                padding: ROBArmRoutinePlan.tolerance), seconds <= 5 else {
                throw ROBGhostMotionError.blocked("A tabletop segment exceeds the bounded timing window.")
            }
            steps.append(.init(positions: target, seconds: seconds, jawAction: action, stage: stage))
            previous = target
        }
        guard let compactApproach = ROBLeftArmInteractionPlan.compactRoute(from: baseline, indices: approach) else {
            throw ROBGhostMotionError.blocked("Tabletop start is outside the registered approach.")
        }
        for index in compactApproach { try append(ROBLeftArmInteractionPlan.target(index: index)!, stage: "Present empty arm") }
        // Keep jaw boundaries even when the start already equals the front pose.
        if steps.last?.positions == center {
            steps[steps.count - 1].jawAction = .prepare
        } else { try append(center, stage: "Open empty gripper", action: .prepare) }
        for (index, target) in targets.enumerated() {
            let start = previous
            let travel = 1.5 * zip(start, target).reduce(0.0) { $0 + abs($1.0 - $1.1) }
            let checks = max(1, Int(ceil(travel / 0.01)))
            for sample in 0...checks {
                let t = Double(sample) / Double(checks)
                let q = zip(start, target).map { $0 + ($1 - $0) * t }
                guard model.treadSeparation(vendorLeft: q) >= 0.030 else {
                    throw ROBGhostMotionError.blocked("The taught tabletop path enters the model's tread clearance margin. Adjust the taught position before review.")
                }
            }
            // Bound individual travel while preserving every taught corner and
            // jaw boundary. No extra approval is made at these subdivisions.
            let delta = zip(start, target).map { abs($0 - $1) }.max() ?? 0
            let count = max(1, Int(ceil(delta / 0.30)))
            for part in 1...count {
                let t = Double(part) / Double(count)
                let q = zip(start, target).map { $0 + ($1 - $0) * t }
                let action: ROBLeftGestureProposal.JawAction? = part == count
                    ? (index == 1 ? .grip : index == 3 ? .release : nil) : nil
                try append(q, stage: stages[index], action: action)
            }
        }
        guard steps.count <= 80, steps.reduce(0, { $0 + $1.seconds }) <= 110 else {
            throw ROBGhostMotionError.blocked("Tabletop path is too long for one operation. Use closer positions or present the empty arm first.")
        }
        return ROBLeftGestureProposal(id: id, name: name, kind: "tabletop", modelID: model.modelID,
            referenceID: model.referenceID, geometryID: model.geometryID, mappingID: model.selectedMappingID,
            sessionGeneration: generation, baseline: baseline, poses: poses, steps: steps)
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

/// A newly authorized EMPTY-arm preparation may retrace the actually executed
/// prefix of a frozen recycling proposal. No payload assumption or old grant
/// survives a failure/restart, and no unvisited point becomes a return route.
enum ROBRecordedLeftRecovery {
    static func make(previous: ROBLeftGestureProposal, samples: [ROBGhostRecordingSample],
                     measured: [Double], model: ROBGhostRobotModel, generation: UInt64,
                     graspClearanceMeters: Double = 0) throws -> ROBLeftGestureProposal {
        guard previous.kind == "recycling", previous.validForReplay(model: model), generation > 0,
              measured.count == 7, measured.allSatisfy(\.isFinite),
              graspClearanceMeters.isFinite, (0...0.15).contains(graspClearanceMeters),
              let lastVisited = samples.last(where: { $0.step >= 0 })?.step,
              previous.steps.indices.contains(lastVisited),
              let frontIndex = previous.steps.firstIndex(where: { $0.jawAction == .prepare }), lastVisited > frontIndex else {
            throw ROBGhostMotionError.blocked("No recorded recycling route is available for empty-arm recovery.")
        }
        try ROBLeftGestureCompiler.validate(previous,model:model)
        // An explicitly reviewed clearance shortcut may omit the low grasp
        // portion of this executed route. Every retained target remains an
        // original visited pose, and every new connecting segment is checked.
        let toolFloor: Double?
        if graspClearanceMeters > 0 {
            guard let gripIndex = previous.steps.firstIndex(where: { $0.jawAction == .grip }), gripIndex <= lastVisited,
                  let grip = model.toolPosition(model.positions(vendorLeft:previous.steps[gripIndex].positions)), grip.z.isFinite,
                  let start = model.toolPosition(model.positions(vendorLeft:measured)), start.z.isFinite,
                  let front = model.toolPosition(model.positions(vendorLeft:previous.steps[frontIndex].positions)), front.z.isFinite,
                  let registeredFront = ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex),
                  ROBArmRoutinePlan.near(previous.steps[frontIndex].positions,registeredFront,tolerance:0.001),
                  start.z >= grip.z + graspClearanceMeters, front.z >= grip.z + graspClearanceMeters else {
                throw ROBGhostMotionError.blocked("The recorded empty return has no safe start and matching front above the calibrated grasp clearance.")
            }
            toolFloor = grip.z + graspClearanceMeters
        } else { toolFloor = nil }
        var segment: Int?
        for index in stride(from: lastVisited,through: frontIndex+1,by:-1) {
            let a = previous.steps[index-1].positions, b = previous.steps[index].positions
            let delta = zip(a,b).map { $1-$0 }, square = delta.reduce(0) { $0+$1*$1 }
            let t = square > 0 ? max(0,min(1,zip(zip(measured,a),delta).reduce(0) { $0+($1.0.0-$1.0.1)*$1.1 }/square)) : 0
            if ROBArmRoutinePlan.near(measured,zip(a,delta).map { $0+t*$1 }) { segment = index; break }
        }
        guard let segment else { throw ROBGhostMotionError.blocked("Measured left arm is outside the recorded route; no recovery movement was proposed.") }
        var steps: [ROBLeftGestureProposal.Step] = [], previousQ = measured
        for index in stride(from: segment-1,through: frontIndex,by:-1) {
            let target = previous.steps[index].positions
            if let toolFloor {
                guard let tool = model.toolPosition(model.positions(vendorLeft:target)), tool.z.isFinite else {
                    throw ROBGhostMotionError.blocked("A recorded return pose is missing its modeled tool height.")
                }
                if tool.z < toolFloor { continue }
            }
            let checks = max(1,Int(ceil(1.5*zip(previousQ,target).reduce(0.0) { $0+abs($1.0-$1.1) }/0.01)))
            for sample in 0...checks {
                let t = Double(sample)/Double(checks), q = zip(previousQ,target).map { $0+($1-$0)*t }
                guard q.allSatisfy({ abs($0) <= 3.1 }), model.treadSeparation(vendorLeft:q) >= 0.030 else {
                    throw ROBGhostMotionError.blocked("The measured recorded return enters the tread clearance margin.")
                }
                if let toolFloor {
                    let positions = model.positions(vendorLeft:q)
                    guard let tool = model.toolPosition(positions), tool.z.isFinite, tool.z >= toolFloor,
                          model.joints.filter({ $0.name.hasPrefix("left_joint") }).allSatisfy({ joint in
                              guard let value = positions[joint.name] else { return false }
                              return value.isFinite && (joint.lower...joint.upper).contains(value)
                          }) else {
                        throw ROBGhostMotionError.blocked("The recorded empty return shortcut crosses the calibrated grasp clearance or a model joint limit.")
                    }
                }
            }
            guard let seconds = ROBLeftArmInteractionPlan.duration(from:previousQ,to:target,padding:ROBArmRoutinePlan.tolerance), seconds <= 5 else {
                throw ROBGhostMotionError.blocked("The recorded return exceeds the bounded step timing.")
            }
            steps.append(.init(positions:target,seconds:seconds,stage:toolFloor == nil ? "Return EMPTY arm on recorded path" : "Return EMPTY arm above calibrated grasp clearance")); previousQ = target
        }
        guard !steps.isEmpty, steps.last?.positions == previous.steps[frontIndex].positions,
              steps.count <= 80, steps.reduce(0,{ $0+$1.seconds }) <= 100 else {
            throw ROBGhostMotionError.blocked("The recorded empty return exceeds one preparation operation.")
        }
        return .init(id:UUID(),name:"Return confirmed-empty left arm to front",kind:"recover",modelID:model.modelID,
            referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:generation,baseline:measured,poses:[],steps:steps)
    }
}
