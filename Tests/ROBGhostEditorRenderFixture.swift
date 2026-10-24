import AppKit
import SceneKit

// Deliberately no transport, arm driver, credential or real approval broker.
final class ROBAmberGatewayClient {
    static let shared = ROBAmberGatewayClient()
    var ready = false
    var samples: [String:FixtureTelemetry] = [:]
    var requestedArms: [String] = []
    func isReady() -> Bool { ready }
    func telemetry(forArm arm:String) -> FixtureTelemetry? { requestedArms.append(arm);return samples[arm] }
    func connectionSnapshot() -> NSDictionary { ready ? ["sessionGeneration":NSNumber(value:UInt64(17))] : [:] }
}
final class FixtureTelemetry {
    let effectiveSampleAgeMilliseconds: Double
    let positionsRadians: [NSNumber]
    init(age:Double=1000,positions:[Double]=[]) {
        effectiveSampleAgeMilliseconds=age;positionsRadians=positions.map(NSNumber.init(value:))
    }
}
final class ROBAmberGatewayTunnel {
    static let shared = ROBAmberGatewayTunnel()
    func connect() {} // no network object exists in this fixture
}
final class ROBControllerArmApproval {
    static let shared = ROBControllerArmApproval()
    let isPending = false
    func cancel(reason: String) {}
}
final class ROBArmRoutineCoordinator {
    static let shared = ROBArmRoutineCoordinator()
    let isRunning = false
    func cancel(reason: String) {}
    func performCommand(_ command: String, target: String, completion: @escaping (NSDictionary) -> Void) {
        precondition(command == "left_search_workspace", "Ghost can search attempted a motion command")
        completion(["detail":"Fixture camera only"])
    }
}
final class ROBWorkspaceSearch {
    static let shared = ROBWorkspaceSearch()
    var announce: ((String) -> Void)?
    var locatedObjects: [ROBWorkspaceTarget: ROBWorkspaceLocatedObject] = [:]
    private(set) var collisionPreviewSnapshot: ROBWorkspaceCollisionSnapshot?
    var collisionSnapshot: ROBWorkspaceCollisionSnapshot? {
        didSet { if let collisionSnapshot { collisionPreviewSnapshot = collisionSnapshot } }
    }
}
final class ROBAmberGestureExecutor {
    static let shared = ROBAmberGestureExecutor()
    func cancelCurrentGesture(reason: String) -> Bool { false }
    func requestPriorityHold() -> Bool { false }
}
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var physicalSide = "left"
    var isRunning = false
    var isNeckOnlyInspection = false
    let status = "Fixture only", lastRecordingPath = ""
    var interactionStage = ""
    var continuedStages: [String] = []
    var collisionReviewProposal: ROBLeftGestureProposal?
    var collisionReviewStatus: NSDictionary = [:]
    func continueOperation(stage: String) -> Bool {
        guard isRunning, !stage.isEmpty, interactionStage == stage else { return false }
        continuedStages.append(stage); interactionStage = ""; return true
    }
    func perform(proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel, completion: @escaping (NSDictionary) -> Void) {
        preconditionFailure("A preview or editing action attempted physical execution")
    }
    func recoveryProposal(model: ROBGhostRobotModel) throws -> ROBLeftGestureProposal {
        throw ROBGhostMotionError.blocked("No hardware in this fixture")
    }
}

final class GhostFixtureSnapshotView: NSView {
    var picture: NSImage?
    override func draw(_ dirtyRect: NSRect) { picture?.draw(in: bounds) }
}

@main struct GhostEditorRenderFixture {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let defaults = UserDefaults.standard
        let previousDepthAlignment = defaults.object(forKey: ROBWorkspaceDepthAlignment.preferenceKey)
        defaults.removeObject(forKey: ROBWorkspaceDepthAlignment.preferenceKey)
        defer {
            if let previousDepthAlignment { defaults.set(previousDepthAlignment, forKey: ROBWorkspaceDepthAlignment.preferenceKey) }
            else { defaults.removeObject(forKey: ROBWorkspaceDepthAlignment.preferenceKey) }
        }
        let scene = SCNScene(); scene.background.contents = NSColor(calibratedWhite: 0.025, alpha: 1)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.fieldOfView = 52
        camera.position = SCNVector3(1.6, 1.45, -3.1); camera.look(at: SCNVector3(0, 0.85, 0))
        scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light!.type = .omni
        light.light!.intensity = 1600; light.position = SCNVector3(0.3, 2.8, -2)
        scene.rootNode.addChildNode(light)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light!.type = .ambient; fill.light!.intensity = 350
        scene.rootNode.addChildNode(fill)
        let floor = SCNFloor(); floor.firstMaterial?.diffuse.contents = NSColor(white: 0.09, alpha: 1)
        scene.rootNode.addChildNode(SCNNode(geometry: floor))
        let original = SCNNode(); scene.rootNode.addChildNode(original)
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 960, height: 820)); view.scene = scene
        let editor = ROBGhostGestureEditor(sceneView: view, originalRobot: original)
        defer { editor.invalidate(); UserDefaults.standard.removeObject(forKey: "ROBGhostSavedGestures.v1") }
        precondition(original.isHidden, "Canonical URDF model did not load")
        precondition(editor.depthCloudCameraTransform(false).isEmpty)
        editor.setHeadCommand(pan: 0, lowerPitch: 0, upperPitch: 0, known: true)
        let levelCamera = editor.depthCloudCameraTransform(false)
        let originalHead = scene.rootNode.childNodes.flatMap(\.childNodes).first { $0.name == "Original URDF oak_link" }!
        let levelHead = originalHead.simdTransform
        editor.setHeadCommand(pan: .pi / 12, lowerPitch: 0, upperPitch: -.pi / 10, known: true)
        let downCamera = editor.depthCloudCameraTransform(false)
        precondition(levelCamera.count == 12 && downCamera != levelCamera && originalHead.simdTransform != levelHead)
        let headGhost = scene.rootNode.childNodes.flatMap(\.childNodes).first { $0.name == "Blue ghost oak_link" }!
        precondition(headGhost.simdTransform == originalHead.simdTransform, "Untouched ghost neck differs from live model")
        precondition(headGhost.isHidden && !originalHead.isHidden,
            "An unchanged camera must show the normal model without a coincident blue overlay")
        let model = try ROBGhostRobotModel(directory: Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil)!)
        let opticalInHead = simd_inverse(model.frames(model.reference)["oak_link"]!) * model.frames(model.reference)["oak_optical_frame"]!
        let origin = originalHead.simdWorldTransform * SIMD4<Float>(opticalInHead.columns.3)
        precondition(abs(origin.x - downCamera[3].floatValue) < 1e-6 &&
            abs(origin.y - downCamera[7].floatValue) < 1e-6 && abs(origin.z - downCamera[11].floatValue) < 1e-6,
            "Depth projection origin differs from the rendered head's optical mount")

        // The operator confirmed a vertical neck and forward-facing OAK at
        // L6011/U6906. The previously inferred L7014/U7790 must remain an
        // articulated pose rather than silently becoming the display zero.
        let headLinks = ["lower_neck_link", "neck_pan_link", "upper_neck_link", "insta360_link", "oak_link"]
        func headNode(_ prefix: String, _ link: String) -> SCNNode {
            scene.rootNode.childNodes.flatMap(\.childNodes).first { $0.name == "\(prefix) \(link)" }!
        }
        func estimate(_ lower: Int, _ upper: Int, pan: Double = 0) -> ROBHeadCameraPoseEstimator {
            ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: pan, lowerTarget: lower,
                upperTarget: upper, known: true)!
        }
        func assertReferenceGeometry(_ original: SCNNode, _ ghost: SCNNode) {
            func dimensions(_ geometry: SCNGeometry) -> [CGFloat] {
                if let box = geometry as? SCNBox { return [box.width, box.height, box.length, box.chamferRadius] }
                if let cylinder = geometry as? SCNCylinder { return [cylinder.radius, cylinder.height] }
                if let sphere = geometry as? SCNSphere { return [sphere.radius] }
                preconditionFailure("Head reference unexpectedly contains captured scan geometry")
            }
            precondition(original.childNodes.map(\.name) == ghost.childNodes.map(\.name),
                "Normal and blue head reference hierarchies differ")
            precondition((original.geometry == nil) == (ghost.geometry == nil))
            if let geometry = original.geometry, let proposed = ghost.geometry {
                precondition(type(of: geometry) == type(of: proposed) && dimensions(geometry) == dimensions(proposed),
                    "Normal and blue head reference shapes differ")
                precondition(geometry.firstMaterial !== proposed.firstMaterial &&
                    geometry.firstMaterial!.transparency > 0.9 && proposed.firstMaterial!.transparency < 0.5,
                    "Normal/blue head styling must keep separate opaque/translucent materials")
            }
            for (actual, proposed) in zip(original.childNodes, ghost.childNodes) {
                precondition(actual.simdTransform == proposed.simdTransform,
                    "Normal and blue head reference bindings differ")
                if actual.geometry != nil {
                    precondition(actual.renderingOrder == 0 && proposed.renderingOrder == 10,
                        "Head reference geometry changed normal/blue render layering")
                }
                assertReferenceGeometry(actual, proposed)
            }
        }
        func assertAcceptedHead(_ lower: Int, _ upper: Int, pan: Double = 0) {
            editor.setHeadCommandEstimate(estimate(lower, upper, pan: pan))
            var expected = model.reference
            let radiansPerTarget = Double.pi / (180 * 33.3333333333)
            expected["lower_neck"] = Double(lower-6011) * radiansPerTarget
            expected["upper_neck"] = -Double(upper-6906) * radiansPerTarget
            expected["neck_pan"] = pan
            let frames = model.frames(expected)
            for link in headLinks {
                let originalNode = headNode("Original URDF", link), ghostNode = headNode("Blue ghost", link)
                precondition(originalNode.geometry == nil && !originalNode.childNodes.isEmpty,
                    "Normal \(link) still displays a captured scan fragment instead of the corrected reference")
                assertReferenceGeometry(originalNode, ghostNode)
                precondition(!originalNode.isHidden && ghostNode.isHidden,
                    "Accepted live head motion must keep the original visible and hide its coincident ghost")
                let frame = frames[link]!
                for col in 0..<4 {
                    precondition(simd_distance(originalNode.simdTransform[col], SIMD4<Float>(frame[col])) < 1e-6,
                        "Accepted neck target omitted or reversed the original \(link)")
                    precondition(simd_distance(ghostNode.simdTransform[col], originalNode.simdTransform[col]) < 1e-6,
                        "Untouched ghost \(link) differs from accepted original")
                }
            }
            let cloud = editor.depthCloudCameraTransform(false)
            let renderedCamera = originalHead.simdWorldTransform * simd_float4x4(columns:
                (SIMD4<Float>(opticalInHead.columns.0), SIMD4<Float>(opticalInHead.columns.1),
                 SIMD4<Float>(opticalInHead.columns.2), SIMD4<Float>(opticalInHead.columns.3)))
            for row in 0..<3 { for col in 0..<4 {
                precondition(abs(renderedCamera[col][row] - cloud[row*4+col].floatValue) < 1e-6,
                    "Cloud optical ray/origin differs from the accepted rendered head chain")
            } }
            // The reference lens cylinder's local +Y is rotated into the
            // OAK link's +X forward axis; its center is the optical origin.
            let cloudForward = simd_normalize(SIMD3(cloud[2].floatValue, cloud[6].floatValue, cloud[10].floatValue))
            for head in [originalHead, headGhost] {
                let lens = head.childNode(withName: "reference-oak-lens-0", recursively: true)!
                let lensMatrix = lens.simdWorldTransform
                let lensForward = simd_normalize(SIMD3(lensMatrix.columns.1.x, lensMatrix.columns.1.y, lensMatrix.columns.1.z))
                precondition(simd_distance(lensForward, cloudForward) < 1e-6,
                    "Normal/blue OAK lens does not face along the unchanged cloud optical ray")
                precondition(simd_distance(SIMD3(lensMatrix.columns.3.x, lensMatrix.columns.3.y, lensMatrix.columns.3.z),
                    SIMD3(cloud[3].floatValue, cloud[7].floatValue, cloud[11].floatValue)) < 1e-6,
                    "Normal/blue OAK lens center differs from the cloud optical origin")
            }
        }
        assertAcceptedHead(6011, 6906)
        let paletteData = try Data(contentsOf: Bundle.main.url(forResource: "rob-visual", withExtension: "json")!)
        let sourcePalette = (try JSONSerialization.jsonObject(with: paletteData) as! [String: Any])["materials"] as! [String: Any]
        for (link, primitive, surface) in [
            ("insta360_link", "reference-insta-body", "polymer"),
            ("oak_link", "reference-oak-body", "polymer"),
            ("upper_neck_link", "reference-upper-servo", "polymer"),
            ("upper_neck_link", "reference-upper-pitch-axis", "aluminum"),
            ("lower_neck_link", "reference-lower-stem", "aluminum"),
            ("insta360_link", "reference-insta-lens-0", "lens"),
            ("oak_link", "reference-oak-lens-0", "lens"),
            ("insta360_link", "reference-insta-antenna-1.0", "rubber")
        ] {
            let normal = headNode("Original URDF", link).childNode(withName: primitive, recursively: true)!
            let ghost = headNode("Blue ghost", link).childNode(withName: primitive, recursively: true)!
            let material = normal.geometry!.firstMaterial!
            let color = (material.diffuse.contents as! NSColor).usingColorSpace(.sRGB)!
            let expected = (sourcePalette[surface] as! [String: Any])["color"] as! [Double]
            for (actual, expected) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                precondition(abs(Double(actual) - expected) < 1e-6,
                    "Normal \(primitive) lost the existing \(surface) source appearance")
            }
            let expectedLighting: SCNMaterial.LightingModel = surface == "polymer" || surface == "rubber" ? .constant : .physicallyBased
            precondition(material.lightingModel == expectedLighting && material.transparency == 1 &&
                material.writesToDepthBuffer && material !== ghost.geometry!.firstMaterial,
                "Normal hardware appearance must stay opaque and separate from blue movement overlays")
            if surface == "lens" {
                precondition(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.2 &&
                    (material.roughness.contents as! NSNumber).doubleValue < 0.2,
                    "Normal camera lenses must remain dark and glossy")
            } else if surface == "polymer" {
                precondition(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3,
                    "The normal camera/servo housing must not become a white merged sphere")
            }
        }
        print("Normal head appearance: original hardware palette retained for dark polymer camera/servo housings, glossy dark lenses, aluminum brackets and rubber antennas; geometry and poses unchanged")
        for prefix in ["Original URDF", "Blue ghost"] {
            let stem = headNode(prefix, "lower_neck_link").childNode(withName: "reference-lower-stem", recursively: true)!
            let stemMatrix = stem.simdWorldTransform
            let stemUp = simd_normalize(SIMD3(stemMatrix.columns.2.x, stemMatrix.columns.2.y, stemMatrix.columns.2.z))
            precondition(simd_distance(stemUp, SIMD3<Float>(0, 1, 0)) < 1e-6,
                "Neutral normal/blue neck retained the captured scan's tilted visual binding")
            precondition(abs((stem.geometry as! SCNBox).length - 0.13) < 1e-8 && abs(stem.position.z - 0.065) < 1e-6)
            for (link, name) in [("lower_neck_link", "reference-lower-pitch-axis"),
                                 ("upper_neck_link", "reference-upper-pitch-axis")] {
                let axis = headNode(prefix, link).childNode(withName: name, recursively: true)!.simdWorldTransform.columns.1
                precondition(simd_distance(simd_normalize(SIMD3(axis.x, axis.y, axis.z)), SIMD3<Float>(-1, 0, 0)) < 1e-6,
                    "Neutral normal/blue servo pitch axis is not aligned to its URDF joint")
            }
            let instaMount = headNode(prefix, "insta360_link").childNode(withName: "reference-insta-mount", recursively: true)!
            let instaAxis = instaMount.simdWorldTransform.columns.2
            let backward20 = Float(20) * .pi / 180
            precondition(simd_distance(simd_normalize(SIMD3(instaAxis.x, instaAxis.y, instaAxis.z)),
                SIMD3<Float>(0, cos(backward20), sin(backward20))) < 1e-6,
                "Normal/blue Insta mounting tilt must be independently 20 degrees backward at neutral")
        }
        print("Reference head: shared normal/blue shapes, neutral neck/servo axes, independent backward-20-degree Insta, both OAK lenses/cloud agreement and unchanged FK passed")
        let uprightLower = headNode("Original URDF", "lower_neck_link").simdTransform
        let uprightPanPivot = headNode("Original URDF", "neck_pan_link").simdTransform.columns.3
        let uprightRay = editor.depthCloudCameraTransform(false)
        precondition(abs(editor.headOpticalPitchRadians!.doubleValue) < 1e-8,
            "Operator-confirmed L6011/U6906 must render a vertical neck and forward OAK")
        assertAcceptedHead(7014, 7790)
        let articulated = estimate(7014, 7790)
        precondition(abs(articulated.lowerPitch * 180 / .pi - 30.09) < 1e-5 &&
            abs(-articulated.upperPitch * 180 / .pi + 26.52) < 1e-5,
            "L7014/U7790 must articulate both joints from the confirmed display datum")
        let articulatedPitch = editor.headOpticalPitchRadians!.doubleValue * 180 / .pi
        precondition(abs(articulatedPitch + 3.57) < 1e-5,
            "L7014/U7790 must face slightly down rather than redefine display neutral")
        precondition(headNode("Original URDF", "lower_neck_link").simdTransform != uprightLower)
        precondition(simd_distance(headNode("Original URDF", "neck_pan_link").simdTransform.columns.3, uprightPanPivot) > 0.06,
            "Lower-neck motion did not move its downstream pan pivot")
        let liveLower = headNode("Original URDF", "lower_neck_link").simdTransform
        assertAcceptedHead(7014, 6906)
        precondition(headNode("Original URDF", "lower_neck_link").simdTransform == liveLower,
            "An upper-only target change unexpectedly moved the lower joint")
        // Equal opposite mechanical contributions keep the optical direction
        // level, but cached rendering must still update the lower articulation
        // and translated camera origin instead of treating the pose as equal.
        assertAcceptedHead(6011, 6906)
        assertAcceptedHead(6311, 7206)
        let compensatedRay = editor.depthCloudCameraTransform(false)
        precondition(abs(editor.headOpticalPitchRadians!.doubleValue) < 1e-8)
        precondition(headNode("Original URDF", "lower_neck_link").simdTransform != uprightLower)
        for row in 0..<3 { precondition(abs(compensatedRay[row*4+2].doubleValue-uprightRay[row*4+2].doubleValue) < 1e-8) }
        precondition(abs(compensatedRay[11].doubleValue-uprightRay[11].doubleValue) > 0.02,
            "Compensated head direction incorrectly suppressed the lower pivot/camera-origin update")

        // A provisional face-camera mounting correction rotates only the OAK
        // body/lenses about the optical origin. Its independent cloud offset
        // must not translate the rendered camera or alter the neck/Insta mount.
        assertAcceptedHead(6011, 6906)
        let unaffectedLinks = headLinks.filter { $0 != "oak_link" }
        let unchangedHeadFrames = ["Original URDF", "Blue ghost"].flatMap { prefix in
            unaffectedLinks.map { headNode(prefix, $0).simdTransform }
        }
        let lensBeforePitch = originalHead.childNode(withName: "reference-oak-lens-0", recursively: true)!.simdWorldTransform
        let bellyBeforePitch = editor.depthCloudCameraTransform(true)
        let alignment = try ROBWorkspaceDepthAlignment.setAlignment(towardRobotMeters: 0.1778, downwardPitchDegrees: 15)
        NotificationCenter.default.post(name: Notification.Name("ROBWorkspaceDepthAlignmentDidChange"), object: nil)
        precondition(["Original URDF", "Blue ghost"].flatMap { prefix in
            unaffectedLinks.map { headNode(prefix, $0).simdTransform }
        } == unchangedHeadFrames, "Face-camera pitch changed the neck or Insta360 model")
        precondition(editor.depthCloudCameraTransform(true) == bellyBeforePitch,
            "Face-camera pitch or cloud translation changed the belly camera")
        precondition(abs(editor.headOpticalPitchRadians!.doubleValue + .pi/12) < 1e-8,
            "Neutral face-camera model does not point exactly15degrees lower")
        let shiftedCloud = editor.depthCloudCameraTransform(false)
        let shiftedOrigin = SIMD3(shiftedCloud[3].floatValue, shiftedCloud[7].floatValue, shiftedCloud[11].floatValue)
        let cloudForward = simd_normalize(SIMD3(shiftedCloud[2].floatValue, shiftedCloud[6].floatValue, shiftedCloud[10].floatValue))
        let lensOrigin = SIMD3(lensBeforePitch.columns.3.x, lensBeforePitch.columns.3.y, lensBeforePitch.columns.3.z)
        let worldShift = originalHead.parent!.simdWorldTransform * SIMD4<Float>(-0.1778, 0, 0, 0)
        precondition(simd_distance(shiftedOrigin-lensOrigin, SIMD3(worldShift.x, worldShift.y, worldShift.z)) < 1e-6,
            "Seven-inch cloud shift was lost, rotated into camera axes or applied to the camera mesh")
        for head in [originalHead, headGhost] {
            let lens = head.childNode(withName: "reference-oak-lens-0", recursively: true)!.simdWorldTransform
            let origin = SIMD3(lens.columns.3.x, lens.columns.3.y, lens.columns.3.z)
            let forward = simd_normalize(SIMD3(lens.columns.1.x, lens.columns.1.y, lens.columns.1.z))
            let previousForward = simd_normalize(SIMD3(lensBeforePitch.columns.1.x, lensBeforePitch.columns.1.y, lensBeforePitch.columns.1.z))
            precondition(simd_distance(origin, lensOrigin) < 1e-6, "Face-camera pitch moved its optical origin")
            precondition(simd_distance(forward, cloudForward) < 1e-6,
                "Normal/blue OAK lens does not agree with the corrected cloud ray")
            precondition(abs(acos(min(1, max(-1, simd_dot(previousForward, forward)))) - Float.pi/12) < 1e-6 && forward.y < previousForward.y,
                "Face-camera model tilted in the wrong direction or by the wrong angle")
        }
        for pan in [-45.0, 0, 45] {
            editor.setHeadCommandEstimate(estimate(6011, 6906, pan: pan * .pi/180))
            precondition(abs(editor.headOpticalPitchRadians!.doubleValue + .pi/12) < 1e-8,
                "Downward camera mount correction changed with neck pan")
            let corrected = alignment.applying(to: ROBWorkspaceView(panDegrees: pan, upperTarget: 6906).rawCameraFrame(model: model)!)
            let expected = originalHead.parent!.simdWorldTransform * simd_float4x4(columns:
                (SIMD4<Float>(corrected.columns.0), SIMD4<Float>(corrected.columns.1), SIMD4<Float>(corrected.columns.2), SIMD4<Float>(corrected.columns.3)))
            let actual = editor.depthCloudCameraTransform(false)
            for row in 0..<3 { for column in 0..<4 {
                precondition(abs(expected[column][row] - actual[row*4+column].floatValue) < 1e-6,
                    "Panned ghost camera and shared workspace projection disagree")
            } }
        }
        _ = try ROBWorkspaceDepthAlignment.setAlignment(towardRobotMeters: 0, downwardPitchDegrees: 0)
        NotificationCenter.default.post(name: Notification.Name("ROBWorkspaceDepthAlignmentDidChange"), object: nil)
        assertAcceptedHead(6011, 6906)
        print("Face-camera mounting:15degree downward OAK model/lens/cloud agreement, fixed optical origin, independent7inch cloud offset, unchanged neck/Insta/belly and pan consistency passed")
        assertAcceptedHead(6011, 6306, pan: .pi / 12)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(editor.panelView)
        let jointPicker = controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("lower_neck") }!
        let jointAngle = controls.compactMap { $0 as? NSSlider }.first { $0.action == NSSelectorFromString("changeAngle") }!
        func setGhostJoint(_ name: String, radians: Double) {
            jointPicker.selectItem(withTitle: name)
            NSApp.sendAction(jointPicker.action!, to: jointPicker.target, from: jointPicker)
            jointAngle.doubleValue = radians * 180 / .pi
            NSApp.sendAction(jointAngle.action!, to: jointAngle.target, from: jointAngle)
        }
        let allRobotNodes = scene.rootNode.childNodes.flatMap(\.childNodes)
        let allGhostNodes = allRobotNodes.filter { $0.name?.hasPrefix("Blue ghost ") == true }
        let allOriginalNodes = allRobotNodes.filter { $0.name?.hasPrefix("Original URDF ") == true }
        for joint in 1...7 {
            let name = "left_joint\(joint)"
            setGhostJoint(name, radians: model.reference[name]!)
        }
        precondition(allGhostNodes.count >= 40 && allGhostNodes.allSatisfy(\.isHidden),
            "A fully coincident baseline must hide every blue link, including cameras and torso")
        precondition(allOriginalNodes.allSatisfy { !$0.isHidden },
            "Ghost masking must preserve every normal robot link")
        let originalFramesBeforeDelta = allOriginalNodes.map(\.simdTransform)
        setGhostJoint("left_joint4", radians: model.reference["left_joint4"]! + 0.1)
        let expectedMovingLinks: Set<String> = ["left_four_Link", "left_five_Link", "left_six_Link", "left_seven_Link", "left_tool"]
        let visibleMovingLinks = Set(allGhostNodes.filter { !$0.isHidden }.map {
            String($0.name!.dropFirst("Blue ghost ".count))
        })
        precondition(visibleMovingLinks == expectedMovingLinks,
            "A J4 edit must show only its physical link and downstream descendants; got \(visibleMovingLinks)")
        precondition(allOriginalNodes.map(\.simdTransform) == originalFramesBeforeDelta &&
            allOriginalNodes.allSatisfy { !$0.isHidden }, "A proposed delta changed or hid the normal model")
        for link in expectedMovingLinks {
            let material = headNode("Blue ghost", link).geometry!.firstMaterial!
            precondition(material.transparency > 0 && material.transparency < 0.5 &&
                material.blendMode == .alpha && material.transparencyMode == .singleLayer &&
                !material.writesToDepthBuffer && material.readsFromDepthBuffer,
                "Blue movement overlays must remain translucent and respect the normal model's depth")
        }
        precondition(headLinks.allSatisfy { headNode("Blue ghost", $0).isHidden },
            "An arm-only edit must not tint a coincident camera sphere or neck")
        setGhostJoint("left_joint4", radians: model.reference["left_joint4"]!)
        precondition(allGhostNodes.allSatisfy(\.isHidden),
            "Returning the ghost to its baseline must immediately remove every coincident overlay")
        print("Ghost deltas: coincident baseline hidden, original model visible, J4-only descendants blue, opaque normal/translucent depth-respecting ghost materials and untinted unchanged camera passed")
        let acceptedHeadFrames = headLinks.map { headNode("Original URDF", $0).simdTransform }
        let acceptedHeadCloud = editor.depthCloudCameraTransform(false)
        jointPicker.selectItem(withTitle: "lower_neck")
        NSApp.sendAction(jointPicker.action!, to: jointPicker.target, from: jointPicker)
        jointAngle.doubleValue = 20
        NSApp.sendAction(jointAngle.action!, to: jointAngle.target, from: jointAngle)
        precondition(headNode("Blue ghost", "lower_neck_link").simdTransform != acceptedHeadFrames[0],
            "Explicit ghost neck edit did not update its preview")
        precondition(headLinks.allSatisfy { !headNode("Blue ghost", $0).isHidden },
            "A proposed lower-neck change must show its moved downstream cameras as blue deltas")
        precondition(headLinks.map { headNode("Original URDF", $0).simdTransform } == acceptedHeadFrames &&
            editor.depthCloudCameraTransform(false) == acceptedHeadCloud,
            "Explicit ghost neck edit changed the normal accepted model or cloud pose")
        let presets = controls.first { $0.identifier?.rawValue == "ghost-preset" } as! NSPopUpButton
        let selection = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1 : 1
        presets.selectItem(at: selection); NSApp.sendAction(presets.action!, to: presets.target, from: presets)
        let timeline = controls.first { $0.identifier?.rawValue == "ghost-timeline" } as! NSSlider
        timeline.doubleValue = timeline.maxValue; NSApp.sendAction(timeline.action!, to: timeline.target, from: timeline)
        let execute = controls.first { $0.identifier?.rawValue == "ghost-execute" } as! NSButton
        precondition(!execute.isEnabled, "Offline preview offered hardware execution")
        let pauseHost = NSView(frame: view.frame); pauseHost.addSubview(view)
        editor.setPreviewFrozen(true)
        precondition(!view.isHidden && view.rendersContinuously && view.isPlaying && pauseHost.subviews.count == 1)
        let frozenHead = originalHead.simdTransform
        let originalArm = scene.rootNode.childNodes.flatMap(\.childNodes).first { $0.name == "Original URDF left_two_Link" }!
        let frozenArm = originalArm.simdTransform
        editor.setHeadCommand(pan: 0, lowerPitch: 0, upperPitch: -.pi / 10, known: true)
        precondition(originalHead.simdTransform != frozenHead && originalArm.simdTransform == frozenArm,
            "Accepted neck update must move the head without changing the frozen arm")
        precondition(headGhost.simdTransform == originalHead.simdTransform)
        editor.refreshPreparedHeadPreview()
        precondition(!view.isHidden && pauseHost.subviews.count == 1, "Preparation must not replace the live viewport with a snapshot")
        editor.refreshPreparedHeadPreview()
        precondition(!view.isHidden && pauseHost.subviews.count == 1)
        let preparedCamera = editor.depthCloudCameraTransform(false)
        let preparedOrigin = originalHead.simdWorldTransform * SIMD4<Float>(opticalInHead.columns.3)
        precondition(abs(preparedOrigin.x - preparedCamera[3].floatValue) < 1e-6 &&
            abs(preparedOrigin.y - preparedCamera[7].floatValue) < 1e-6 &&
            abs(preparedOrigin.z - preparedCamera[11].floatValue) < 1e-6)
        editor.setPreviewFrozen(false)
        precondition(!view.isHidden && pauseHost.subviews.count == 1 && originalHead.simdTransform != frozenHead)
        // Settings can start a cycle without owning an editor preview request.
        editor.refreshPreparedHeadPreview()
        precondition(!view.isHidden && pauseHost.subviews.count == 1)
        editor.setPreviewFrozen(false)
        let continuation = controls.first { $0.identifier?.rawValue == "ghost-continue-interaction" } as! NSButton
        func awaitContinuation(_ title: String?) {
            let deadline = Date().addingTimeInterval(1)
            func ready() -> Bool {
                if let title { return !continuation.isHidden && continuation.isEnabled && continuation.title == title }
                return continuation.isHidden
            }
            while !ready() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(ready(), "Continue controls did not reach the expected readiness stage within one second")
        }
        let trial = ROBLeftArmTrial.shared
        trial.isRunning = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!view.isHidden && view.isPlaying && view.preferredFramesPerSecond == 15)
        trial.isNeckOnlyInspection = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(!view.isHidden && view.preferredFramesPerSecond == 30)
        trial.isNeckOnlyInspection = false
        for (stage, title) in [("object_placed", "Object placed; fingers clear → grip"),
                               ("receiver_supporting", "Hand supporting → release"),
                               ("object_clear", "Object clear → lower")] {
            trial.interactionStage = stage
            awaitContinuation(title)
            NSApp.sendAction(continuation.action!, to: continuation.target, from: continuation)
            precondition(trial.continuedStages.last == stage && trial.interactionStage.isEmpty)
        }
        trial.interactionStage = "object_placed"
        awaitContinuation("Object placed; fingers clear → grip")
        let confirmedCount = trial.continuedStages.count
        trial.interactionStage = "receiver_supporting"
        NSApp.sendAction(continuation.action!, to: continuation.target, from: continuation)
        precondition(trial.continuedStages.count == confirmedCount, "A stale continuation button advanced another stage")
        trial.interactionStage = ""; trial.isRunning = false
        awaitContinuation(nil)
        let blue = scene.rootNode.childNodes.flatMap(\.childNodes).filter { $0.name?.hasPrefix("Blue ghost ") == true }
        precondition(blue.count >= 40)
        let canTarget = ROBWorkspaceLocatedObject(target: .can, position: [0.589,-0.300,0.873], confidence: 0.6,
            capturedAt: Date().timeIntervalSince1970 * 1000, sequence: 1234,
            view: .init(panDegrees: -45, upperTarget: 6306))
        let canPreview = try ROBCanGrabPreview.make(can: canTarget, model: model, baseline: model.reference)
        precondition(canPreview.gripperTiltDegrees <= 5, "Cross-body ghost gripper is not horizontal")
        var previousCanPose = canPreview.baseline
        for step in canPreview.steps {
            if step.stage.hasPrefix("Final approach") || step.stage.hasPrefix("Closest horizontal") || step.stage == "Grasp pose" {
                precondition(abs(step.pose["left_joint7", default: 0] - previousCanPose["left_joint7", default: 0]) < .pi/2,
                    "Final approach chose the opposite wrist-roll branch")
                for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
                    var pose = previousCanPose
                    for (joint, value) in step.pose { pose[joint] = previousCanPose[joint, default: 0] + (value-previousCanPose[joint, default: 0])*fraction }
                    let frame = model.frames(pose)["left_tool"]!
                    precondition(abs(frame.columns.1.z) < sin(5 * .pi/180) && abs(frame.columns.2.z) < sin(5 * .pi/180),
                        "The captured gripper's Y jaw opening became vertical between approach stages")
                }
            }
            previousCanPose = step.pose
        }
        let originalLeft = headNode("Original URDF", "left_two_Link").simdTransform
        editor.showCanPreview(canPreview)
        let marker = scene.rootNode.childNode(withName: "Detected Coke can RGB-D center", recursively: true)!
        precondition(simd_distance(marker.simdPosition, SIMD3<Float>(canTarget.point)) < 1e-6,
            "Can label is not anchored at its measured robot-frame position")
        let label = marker.childNode(withName: "Coke can label", recursively: true)!
        precondition((label.geometry as! SCNText).string as? String == "COKE CAN · RGB-D\nX 0.589  Y -0.300  Z 0.873 m\nLeft ghost · simulation only")
        timeline.doubleValue = timeline.maxValue; NSApp.sendAction(timeline.action!, to: timeline.target, from: timeline)
        precondition(!execute.isEnabled && headNode("Original URDF", "left_two_Link").simdTransform == originalLeft,
            "Can rehearsal changed measured/original geometry or offered execution")
        precondition(headNode("Blue ghost", "left_two_Link").simdTransform != originalLeft)
        if !canPreview.reachesCan {
            precondition(scene.rootNode.childNode(withName: "Simulated held can", recursively: true)!.isHidden)
            precondition(controls.compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("Please bring the can closer.") && $0.stringValue.contains("check again")
            }, "An unreachable preview must explain how to get a fresh reach check after moving the can")
        }
        let replay = controls.compactMap { $0 as? NSButton }.first { $0.title == "Play ×4" }!
        NSApp.sendAction(replay.action!, to: replay.target, from: replay)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(timeline.doubleValue < timeline.maxValue / 2, "Replay must restart a completed ghost rehearsal")
        timeline.doubleValue = timeline.maxValue; NSApp.sendAction(timeline.action!, to: timeline.target, from: timeline)
        print(String(format: "Can overlay: robot-frame label, selected left cross-body ghost, unchanged original, disabled hardware; grasp gap %.1f mm, horizontal tilt %.2f degrees", canPreview.graspError * 1000, canPreview.gripperTiltDegrees))

        // A real provisional depth map is visible without being promoted to
        // measured registration. There is no gateway, driver or grant here.
        let captured = Date().timeIntervalSince1970 * 1000, cameraGeneration = UUID()
        var depthMap = ROBWorkspaceDepthMap(modelID: model.modelID, geometryID: model.geometryID,
            mappingID: ROBGhostRobotModel.mappingID, sessionGeneration: 1, cameraGeneration: cameraGeneration,
            nowMilliseconds: captured - 200)
        let cameraFrame = ROBWorkspaceView(panDegrees: 0, upperTarget: 6306).cameraFrame(model: model)!
        for (sequence, age) in [(UInt64(1), 100.0), (UInt64(2), 50.0)] {
            try depthMap.append(width: 96, height: 96, fx: 80, fy: 80, cx: 48, cy: 48,
                depth: { _, _ in 900 }, cameraToRobot: cameraFrame, capturedAtMilliseconds: captured-age,
                sequence: sequence, cameraGeneration: cameraGeneration, nowMilliseconds: captured)
        }
        let collisionMap = depthMap.snapshot(nowMilliseconds: captured)!
        precondition(collisionMap.registrationID == nil && collisionMap.occupiedVoxelCount > 2500)
        ROBWorkspaceSearch.shared.collisionSnapshot = collisionMap
        trial.collisionReviewStatus = ["status": "blocked", "blocked_reason": "Fixture registration unavailable",
            "registration_verified": true] // A summary flag cannot certify a provisional map.
        editor.reviewPresetNamed("collision")
        let mapOverlay = scene.rootNode.childNode(withName: "Observed depth obstacles · provisional registration", recursively: true)!
        let depthNode = mapOverlay.childNodes.first!
        let source = depthNode.geometry!.sources(for: .vertex).first!
        precondition(source.vectorCount > 0 && source.vectorCount <= 2500,
            "Depth overlay exceeded its bounded render sample")
        let collisionStatus = controls.first { $0.identifier?.rawValue == "ghost-collision-status" } as! NSTextField
        precondition(collisionStatus.stringValue.contains("\(collisionMap.occupiedVoxelCount) occupied cells") &&
            collisionStatus.stringValue.contains("Registration: unverified") &&
            collisionStatus.stringValue.contains("Fixture registration unavailable") &&
            collisionStatus.stringValue.contains("no validated route"))
        precondition(!execute.isEnabled && !view.isHidden && view.rendersContinuously && view.isPlaying)
        let mapToggle = controls.first { $0.identifier?.rawValue == "ghost-depth-obstacles-visible" } as! NSButton
        mapToggle.state = .off; NSApp.sendAction(mapToggle.action!, to: mapToggle.target, from: mapToggle)
        precondition(mapOverlay.isHidden && mapOverlay.childNodes.isEmpty)
        mapToggle.state = .on; NSApp.sendAction(mapToggle.action!, to: mapToggle.target, from: mapToggle)
        precondition(!mapOverlay.isHidden && mapOverlay.childNodes.count == 1)
        let cachedDepthNode = mapOverlay.childNodes[0]
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        precondition(mapOverlay.childNodes[0] === cachedDepthNode,
            "An unchanged capture rebuilt the depth cloud on the render timer")
        precondition(!view.isHidden && view.rendersContinuously && view.isPlaying)
        precondition(!collisionStatus.stringValue.contains("Stored scan preview"))
        // Opening the live camera may invalidate admission while the last
        // capture remains useful for inspection. Its pixels never become fresh.
        ROBWorkspaceSearch.shared.collisionSnapshot = nil
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        precondition(ROBWorkspaceSearch.shared.collisionPreviewSnapshot?.fingerprint == collisionMap.fingerprint)
        precondition(mapOverlay.childNodes.count == 1 && mapOverlay.childNodes[0] === cachedDepthNode,
            "Camera/session expiry removed or rebuilt the stored preview cloud")
        precondition(collisionStatus.stringValue.contains("Stored scan preview; rescan before motion.") &&
            collisionStatus.stringValue.contains("Registration: unverified") && !execute.isEnabled)
        precondition(!view.isHidden && view.rendersContinuously && view.isPlaying)

        // Display an offline model artifact as a historical/read-only path.
        // It supplies no measured scene proof and must never enable execution.
        let historical = try ROBLeftGestureCompiler.compile(kind: "center", name: "Read-only render fixture",
            model: model, baseline: Array(repeating: 0, count: 7), generation: 1)
        trial.collisionReviewProposal = historical
        let originalBeforePath = headNode("Original URDF", "left_two_Link").simdTransform
        editor.reviewPresetNamed("collision")
        let pathOverlay = scene.rootNode.childNode(withName: "Read-only collision route", recursively: true)!
        precondition(pathOverlay.childNode(withName: "Checked complete tool trajectory", recursively: false) != nil)
        timeline.doubleValue = timeline.maxValue; NSApp.sendAction(timeline.action!, to: timeline.target, from: timeline)
        let expectedEnd = model.frames(model.positions(vendorLeft: historical.steps.last!.positions))["left_two_Link"]!
        let renderedEnd = headNode("Blue ghost", "left_two_Link").simdTransform
        for column in 0..<4 {
            precondition(simd_distance(renderedEnd[column], SIMD4<Float>(expectedEnd[column])) < 1e-6)
        }
        precondition(headNode("Original URDF", "left_two_Link").simdTransform == originalBeforePath && !execute.isEnabled)
        NSApp.sendAction(execute.action!, to: execute.target, from: execute)
        let pathToggle = controls.first { $0.identifier?.rawValue == "ghost-collision-path-visible" } as! NSButton
        pathToggle.state = .off; NSApp.sendAction(pathToggle.action!, to: pathToggle.target, from: pathToggle)
        precondition(pathOverlay.isHidden)
        pathToggle.state = .on; NSApp.sendAction(pathToggle.action!, to: pathToggle.target, from: pathToggle)
        precondition(!pathOverlay.isHidden && !execute.isEnabled && view.rendersContinuously && view.isPlaying)
        precondition(collisionStatus.stringValue.contains("Stored scan preview; rescan before motion.") &&
            ROBWorkspaceSearch.shared.collisionSnapshot == nil)
        print("Collision overlay: real provisional RGB-D cloud capped at 2500 points, unchanged-capture caching, retained stale-camera preview with rescan label, obstacle/path visibility, unverified registration, read-only path FK and continuous rendering passed; execution unavailable")

        // Physical RIGHT uses its own mapping and gateway `left` (L10). An old
        // physical-left artifact cannot be silently rendered as a right path.
        trial.physicalSide="right"
        editor.reviewPresetNamed("collision")
        precondition(controls.compactMap{$0 as? NSTextField}.contains{$0.stringValue=="Path preview unavailable for this robot model"})
        precondition(!execute.isEnabled,"Changing physical side must not grant execution")
        let rightModel=try ROBGhostRobotModel(directory:model.directory,physicalSide:"right")
        let rightStart=Array(repeating:0.0,count:7),rightEnd=[0.1,-0.03,0.08,0.01,-0.02,0.02,0.04]
        let rightReadOnly=ROBLeftGestureProposal(id:UUID(),name:"Fixture estimated right preview",kind:"estimated_calibration",
            modelID:rightModel.modelID,referenceID:rightModel.referenceID,geometryID:rightModel.geometryID,
            mappingID:rightModel.selectedMappingID,sessionGeneration:17,baseline:rightStart,poses:[],
            steps:[.init(positions:rightEnd,seconds:4,stage:"Read-only estimated fixture")])
        trial.collisionReviewProposal=rightReadOnly
        let normalRightBefore=headNode("Original URDF","right_two_Link").simdTransform
        let normalLeftBefore=headNode("Original URDF","left_two_Link").simdTransform
        editor.reviewPresetNamed("collision")
        precondition(controls.compactMap{$0 as? NSTextField}.contains{
            $0.stringValue.contains("ESTIMATED EMPTY-ARM TRIAL") && $0.stringValue.contains("Physical right arm") && $0.stringValue.contains("no actuator authority")
        },"Estimated right artifact must be identified as read-only and physically right")
        timeline.doubleValue=timeline.maxValue;NSApp.sendAction(timeline.action!,to:timeline.target,from:timeline)
        let rightFrames=rightModel.frames(rightModel.positions(vendorLeft:rightEnd))
        for link in ["right_two_Link","right_four_Link","right_tool","left_two_Link"] {
            let actual=headNode("Blue ghost",link).simdTransform,expected=rightFrames[link]!
            for col in 0..<4 {precondition(simd_distance(actual[col],SIMD4<Float>(expected[col]))<1e-6,
                "Right collision preview updated the wrong physical arm or mapping: \(link)")}
        }
        precondition(headNode("Original URDF","right_two_Link").simdTransform==normalRightBefore &&
            headNode("Original URDF","left_two_Link").simdTransform==normalLeftBefore && !execute.isEnabled)
        NSApp.sendAction(execute.action!,to:execute.target,from:execute)

        // Fresh original feedback must come from L10/gateway-left, while the
        // unrelated R11 sample is deliberately a different physical pose.
        let gateway=ROBAmberGatewayClient.shared
        gateway.ready=true
        let measuredRight=[0.17,-0.07,0.03,0.01,-0.01,0.02,0.04]
        gateway.samples=["left":FixtureTelemetry(age:1,positions:measuredRight),
                         "right":FixtureTelemetry(age:1,positions:[-0.7,0.9,-0.5,0,-0.4,0,0])]
        gateway.requestedArms=[]
        let rightScene=SCNScene(),rightOriginal=SCNNode();rightScene.rootNode.addChildNode(rightOriginal)
        let rightView=SCNView(frame:NSRect(x:0,y:0,width:320,height:240));rightView.scene=rightScene
        let rightEditor=ROBGhostGestureEditor(sceneView:rightView,originalRobot:rightOriginal)
        let measuredFrames=rightModel.frames(rightModel.positions(vendorLeft:measuredRight))
        for link in ["right_two_Link","left_two_Link"] {
            let actual=rightScene.rootNode.childNodes.flatMap(\.childNodes).first{$0.name=="Original URDF \(link)"}!.simdTransform
            for col in 0..<4 {precondition(simd_distance(actual[col],SIMD4<Float>(measuredFrames[link]![col]))<1e-6,
                "Original model used the wrong gateway arm for \(link)")}
        }
        precondition(!gateway.requestedArms.isEmpty && gateway.requestedArms.allSatisfy{$0=="left"},
            "Physical-right initialization read R11 rather than L10")
        let rightExecute=descendants(rightEditor.panelView).first{$0.identifier?.rawValue=="ghost-execute"} as! NSButton
        precondition(!rightExecute.isEnabled,"Live-shaped fixture data must not create actuator authority")
        rightEditor.invalidate();gateway.ready=false;gateway.samples=[:]
        trial.physicalSide="left";trial.collisionReviewProposal=historical
        editor.reviewPresetNamed("collision")
        print("Right preview: side-mismatch rejected, all-right FK with unchanged originals, explicit estimated/read-only label, L10-only fresh baseline and disabled execution passed")
        trial.collisionReviewProposal = nil; trial.collisionReviewStatus = [:]
        if CommandLine.arguments.last != "can" {
            presets.selectItem(at: selection); NSApp.sendAction(presets.action!, to: presets.target, from: presets)
            timeline.doubleValue = timeline.maxValue; NSApp.sendAction(timeline.action!, to: timeline.target, from: timeline)
        }
        let renderer = SCNRenderer(device: nil, options: nil); renderer.scene = scene; renderer.pointOfView = camera
        let picture = renderer.snapshot(atTime: 0, with: CGSize(width: 960, height: 820), antialiasingMode: .multisampling4X)
        let imageView = GhostFixtureSnapshotView(frame: NSRect(x: 0, y: 0, width: 960, height: 820)); imageView.picture = picture
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1330, height: 820), styleMask: .borderless,
            backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1330, height: 820))
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        for child in [imageView, editor.panelView] { child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child) }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.topAnchor.constraint(equalTo: content.topAnchor), imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            imageView.trailingAnchor.constraint(equalTo: editor.panelView.leadingAnchor),
            editor.panelView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.panelView.topAnchor.constraint(equalTo: content.topAnchor), editor.panelView.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        // The offscreen borderless fixture does not receive AppKit's normal
        // window-server resize events. Exercise the embedded content at both
        // window sizes; live titled-window resizing is checked in Cerebro.
        for size in [NSSize(width: 1100, height: 700), NSSize(width: 1330, height: 820)] {
            content.setFrameSize(size); content.layoutSubtreeIfNeeded()
            precondition(abs(editor.panelView.frame.width - 370) < 1)
            precondition(abs(imageView.frame.width + 370 - size.width) < 1)
            precondition(abs(imageView.frame.height - size.height) < 1)
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("No UI bitmap") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Ghost editor: captured URDF/blue overlay, shared head/cloud FK, live viewport without snapshots, 30/15 FPS search/motion display, stage-bound Continue controls and embedded resizing passed; offline execution disabled; no hardware transport linked")
    }
}
