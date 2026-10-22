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
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(editor.panelView)
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
        let trial = ROBLeftArmTrial.shared
        trial.isRunning = true
        for (stage, title) in [("object_placed", "Object placed; fingers clear → grip"),
                               ("receiver_supporting", "Hand supporting → release"),
                               ("object_clear", "Object clear → lower")] {
            trial.interactionStage = stage
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            precondition(!continuation.isHidden && continuation.isEnabled && continuation.title == title)
            NSApp.sendAction(continuation.action!, to: continuation.target, from: continuation)
            precondition(trial.continuedStages.last == stage && trial.interactionStage.isEmpty)
        }
        trial.interactionStage = "object_placed"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let confirmedCount = trial.continuedStages.count
        trial.interactionStage = "receiver_supporting"
        NSApp.sendAction(continuation.action!, to: continuation.target, from: continuation)
        precondition(trial.continuedStages.count == confirmedCount, "A stale continuation button advanced another stage")
        trial.interactionStage = ""; trial.isRunning = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(continuation.isHidden)
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
