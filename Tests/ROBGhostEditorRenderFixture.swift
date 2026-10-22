import AppKit
import SceneKit

// Deliberately no transport, arm driver, credential or real approval broker.
final class ROBAmberGatewayClient {
    static let shared = ROBAmberGatewayClient()
    func isReady() -> Bool { false }
    func telemetry(forArm: String) -> FixtureTelemetry? { nil }
    func connectionSnapshot() -> NSDictionary { [:] }
}
final class FixtureTelemetry {
    let effectiveSampleAgeMilliseconds = 1000.0
    let positionsRadians: [NSNumber] = []
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
}
final class ROBAmberGestureExecutor {
    static let shared = ROBAmberGestureExecutor()
    func cancelCurrentGesture(reason: String) -> Bool { false }
    func requestPriorityHold() -> Bool { false }
}
final class ROBLeftArmTrial {
    static let shared = ROBLeftArmTrial()
    var isRunning = false
    let status = "Fixture only", lastRecordingPath = ""
    var interactionStage = ""
    var continuedStages: [String] = []
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
        assertAcceptedHead(6011, 6306, pan: .pi / 12)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(editor.panelView)
        let jointPicker = controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("lower_neck") }!
        let jointAngle = controls.compactMap { $0 as? NSSlider }.first { $0.action == NSSelectorFromString("changeAngle") }!
        let acceptedHeadFrames = headLinks.map { headNode("Original URDF", $0).simdTransform }
        let acceptedHeadCloud = editor.depthCloudCameraTransform(false)
        jointPicker.selectItem(withTitle: "lower_neck")
        NSApp.sendAction(jointPicker.action!, to: jointPicker.target, from: jointPicker)
        jointAngle.doubleValue = 20
        NSApp.sendAction(jointAngle.action!, to: jointAngle.target, from: jointAngle)
        precondition(headNode("Blue ghost", "lower_neck_link").simdTransform != acceptedHeadFrames[0],
            "Explicit ghost neck edit did not update its preview")
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
        precondition(view.isHidden && pauseHost.subviews.count == 2)
        let frozenHead = originalHead.simdTransform
        let originalArm = scene.rootNode.childNodes.flatMap(\.childNodes).first { $0.name == "Original URDF left_two_Link" }!
        let frozenArm = originalArm.simdTransform
        let frozenImage = pauseHost.subviews.compactMap { $0 as? NSImageView }.first!
        let beforePreparation = frozenImage.image!
        editor.setHeadCommand(pan: 0, lowerPitch: 0, upperPitch: -.pi / 10, known: true)
        precondition(originalHead.simdTransform != frozenHead && originalArm.simdTransform == frozenArm,
            "Accepted neck update must move the head without changing the frozen arm")
        precondition(headGhost.simdTransform == originalHead.simdTransform)
        precondition(frozenImage.image === beforePreparation, "Neck command resnapshotted during motion")
        editor.refreshPreparedHeadPreview()
        let preparedImage = frozenImage.image!
        precondition(preparedImage !== beforePreparation && view.isHidden)
        precondition(preparedImage.tiffRepresentation != beforePreparation.tiffRepresentation,
            "Prepared neck snapshot still displays the preapproval pose")
        editor.refreshPreparedHeadPreview()
        precondition(frozenImage.image === preparedImage, "Duplicate preparation checkpoint resnapshotted")
        let preparedCamera = editor.depthCloudCameraTransform(false)
        let preparedOrigin = originalHead.simdWorldTransform * SIMD4<Float>(opticalInHead.columns.3)
        precondition(abs(preparedOrigin.x - preparedCamera[3].floatValue) < 1e-6 &&
            abs(preparedOrigin.y - preparedCamera[7].floatValue) < 1e-6 &&
            abs(preparedOrigin.z - preparedCamera[11].floatValue) < 1e-6)
        editor.setPreviewFrozen(false)
        precondition(!view.isHidden && pauseHost.subviews.count == 1 && originalHead.simdTransform != frozenHead)
        // Settings can start a cycle without owning an editor preview request.
        editor.refreshPreparedHeadPreview()
        precondition(view.isHidden && pauseHost.subviews.count == 2)
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
        print("Ghost editor: captured URDF/blue overlay, shared head/cloud FK, one post-preparation snapshot, frozen arm, stage-bound Continue controls and embedded resizing passed; offline execution disabled; no hardware transport linked")
    }
}
