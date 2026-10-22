import AppKit
import SceneKit
import UniformTypeIdentifiers
import simd

/// Gesture authoring lives in the existing controller-input scene. Moving a
/// slider, an XYZ target, or the playback clock never sends a motor command.
@objcMembers final class ROBGhostGestureEditor: NSObject {
    let panelView = NSView()
    @nonobjc private let scene: SCNScene
    @nonobjc private let capturedRobot: SCNNode
    @nonobjc private weak var sceneView: SCNView?
    private var frozenPreview: NSImageView?
    private var previewFrozen = false
    private var preparationSnapshotRefreshed = false
    private let headLinks: Set<String> = ["lower_neck_link", "neck_pan_link", "upper_neck_link", "insta360_link", "oak_link"]
    private var acceptedHeadTargets: ROBHeadCameraPoseEstimator?
    @nonobjc private var model: ROBGhostRobotModel?
    @nonobjc private var originalNodes: [String: SCNNode] = [:]
    @nonobjc private var ghostNodes: [String: SCNNode] = [:]
    @nonobjc private let renderRoot = SCNNode()
    @nonobjc private var modelBasis = matrix_identity_float4x4
    @nonobjc private var ghost: [String: Double] = [:]
    @nonobjc private var headEstimate: [String: Double]?
    @nonobjc private var originalPositions: [String: Double] = [:]
    @nonobjc private var ghostDisplayPositions: [String: Double] = [:]
    @nonobjc private var poses: [[String: Double]] = []
    @nonobjc private var saved: [ROBGhostGesture] = []
    @nonobjc private var proposal: ROBLeftGestureProposal?
    private var liveBaseline = false
    private var ownsPendingRequest = false
    private var replayingRecording = false
    private var playing = false
    private var animationStarted = 0.0
    private var lastOriginalUpdate = 0.0
    private var timer: Timer?
    private let presets = NSPopUpButton()
    private let name = NSTextField(string: "My gesture")
    private let joints = NSPopUpButton()
    private let angle = NSSlider(value: 0, minValue: -120, maxValue: 120, target: nil, action: nil)
    private let angleText = NSTextField(labelWithString: "")
    private let xyz = (0..<3).map { _ in NSTextField(string: "0") }
    private let poseCount = NSTextField(labelWithString: "No custom poses")
    private let referenceInfo = NSTextField(wrappingLabelWithString: "Original model: waiting for left-arm feedback")
    private let headInfo = NSTextField(wrappingLabelWithString: "Head: waiting for accepted neck commands")
    private let continueButton = NSButton()
    private var displayedInteractionStage = ""
    private let status = NSTextField(wrappingLabelWithString: "")
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let clock = NSTextField(labelWithString: "0.0 s")
    private let executeButton = NSButton(title: "Request execution of reviewed path", target: nil, action: nil)
    private let currentPlot = ROBGhostCurrentPlot()
    @nonobjc private var record: [ROBGhostRecordingSample] = []

    init(sceneView: SCNView, originalRobot: SCNNode) {
        scene = sceneView.scene!; capturedRobot = originalRobot; self.sceneView = sceneView
        super.init()
        buildPanel()
        do {
            guard let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
                throw ROBGhostMotionError.blocked("Bundled robot model is missing.")
            }
            let model = try ROBGhostRobotModel(directory: directory)
            self.model = model; ghost = model.reference
            // ROB X-forward/Y-left/Z-up -> the existing scene's Y-up/-Z-forward.
            let scale = ROBScanVisualModel.presentationScale
            modelBasis = simd_float4x4(columns: (SIMD4(0, 0, -scale, 0),
                SIMD4(-scale, 0, 0, 0), SIMD4(0, scale, 0, 0), SIMD4(0, 0, 0, 1)))
            renderRoot.simdTransform = capturedRobot.presentation.simdWorldTransform * modelBasis
            scene.rootNode.addChildNode(renderRoot)
            for (link, geometry, ghostGeometry) in try capturedGeometry(model) {
                let originalMaterial = SCNMaterial()
                originalMaterial.diffuse.contents = headLinks.contains(link) ? NSColor.lightGray : NSColor.white
                originalMaterial.lightingModel = .constant; originalMaterial.isDoubleSided = true
                let original = referenceHeadNode(link: link, material: originalMaterial, renderingOrder: 0)
                    ?? SCNNode(geometry: geometry)
                original.geometry?.materials = [originalMaterial]; original.name = "Original URDF \(link)"
                renderRoot.addChildNode(original); originalNodes[link] = original
                let blue = SCNMaterial(); blue.diffuse.contents = NSColor.systemBlue
                blue.transparency = 0.12
                blue.lightingModel = .constant
                blue.isDoubleSided = true; blue.writesToDepthBuffer = false; blue.readsFromDepthBuffer = false
                let proposed = referenceHeadNode(link: link, material: blue, renderingOrder: 10) ?? SCNNode(geometry: ghostGeometry)
                proposed.geometry?.materials = [blue]; proposed.renderingOrder = 10; proposed.name = "Blue ghost \(link)"
                renderRoot.addChildNode(proposed); ghostNodes[link] = proposed
            }
            capturedRobot.isHidden = true
            let initial = freshBaseline()
            updateOriginal(initial.map { model.positions(vendorLeft: $0.q) } ?? model.reference)
            referenceInfo.stringValue = initial == nil ? "Original: scan reference; fresh left feedback unavailable."
                : "Original left: fresh encoders with upright mapping prior. Other joints: scan reference."
            for joint in model.joints where joint.kind != "fixed" && joint.upper > joint.lower {
                joints.addItem(withTitle: joint.name)
            }
            if let data = UserDefaults.standard.data(forKey: "ROBGhostSavedGestures.v1"),
               data.count <= 2_000_000, let values = try? JSONDecoder().decode([ROBGhostGesture].self, from: data) {
                saved = Array(values.prefix(40))
            }
            reloadPresets(); selectPreset()
        } catch { status.stringValue = error.localizedDescription; executeButton.isEnabled = false }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }

    func invalidate() { timer?.invalidate(); timer = nil; setPreviewFrozen(false); renderRoot.removeFromParentNode(); capturedRobot.isHidden = false }

    /// Keep the reviewed picture embedded while physical execution records its
    /// own telemetry. SceneKit must not compete with the motion watchdog.
    func setPreviewFrozen(_ frozen: Bool) {
        guard frozen != previewFrozen, let view = sceneView else { return }
        previewFrozen = frozen
        if frozen {
            preparationSnapshotRefreshed = false
            if let host = view.superview {
                let picture = NSImageView(); picture.image = view.snapshot()
                picture.imageScaling = .scaleProportionallyUpOrDown
                picture.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(picture, positioned: .above, relativeTo: view)
                NSLayoutConstraint.activate([picture.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    picture.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    picture.topAnchor.constraint(equalTo: view.topAnchor), picture.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
                frozenPreview = picture
            }
            view.isHidden = true
        } else {
            frozenPreview?.removeFromSuperview(); frozenPreview = nil; view.isHidden = false
            if !ROBLeftArmTrial.shared.isRunning && !ROBArmRoutineCoordinator.shared.isRunning {
                updateOriginal(originalPositions); updateGhost(ghostDisplayPositions, updateFields: false)
            }
        }
        updateHeadInfo()
    }

    /// Called synchronously after the neck settles and before arm position
    /// mode/travel starts. Refresh the static picture once, never per frame.
    func refreshPreparedHeadPreview() {
        guard headEstimate != nil, let view = sceneView else { return }
        if !previewFrozen {
            // Normal arm controls may launch outside this editor. Camera
            // preparation is the last safe point to capture their picture.
            setPreviewFrozen(true)
            preparationSnapshotRefreshed = true
            updateHeadInfo()
            return
        }
        guard !preparationSnapshotRefreshed,
              let picture = frozenPreview else { return }
        preparationSnapshotRefreshed = true
        picture.image = view.snapshot()
        updateHeadInfo()
    }

    func setHeadCommandEstimate(_ estimate: ROBHeadCameraPoseEstimator?) {
        acceptedHeadTargets = estimate
        setHeadCommand(pan: estimate?.panRadians ?? 0, lowerPitch: estimate?.lowerPitch ?? 0,
            upperPitch: estimate?.upperPitch ?? 0, known: estimate != nil)
        updateHeadInfo()
    }

    @objc(setHeadCommandPan:lowerPitch:upperPitch:known:)
    func setHeadCommand(pan: Double, lowerPitch: Double, upperPitch: Double, known: Bool) {
        let value = known ? model?.headPositions(pan: pan, lowerPitch: lowerPitch, upperPitch: upperPitch) : nil
        guard value != headEstimate else { return }
        headEstimate = value
        // Only the five head-chain nodes change. Arm poses and the approved
        // path stay frozen, including while the static picture is displayed.
        updateNodes(originalNodes.filter { headLinks.contains($0.key) }, positions: renderPositions(originalPositions, preview: false))
        updateNodes(ghostNodes.filter { headLinks.contains($0.key) }, positions: renderPositions(ghostDisplayPositions, preview: true))
        updateHeadInfo()
    }

    var headOpticalPitchRadians: NSNumber? {
        guard headEstimate != nil, let model,
              let camera = model.frames(renderPositions(model.reference, preview: false))["oak_optical_frame"] else { return nil }
        let direction = camera.columns.2
        return NSNumber(value: atan2(direction.z, hypot(direction.x, direction.y)))
    }

    private func updateHeadInfo() {
        guard let pitch = headOpticalPitchRadians else {
            headInfo.stringValue = "Head: command estimate unavailable"; return
        }
        let targets = acceptedHeadTargets.map { "L\($0.lowerTarget) / U\($0.upperTarget) · " } ?? ""
        let frozen = previewFrozen ? (preparationSnapshotRefreshed
            ? " · picture frozen after neck preparation" : " · picture awaiting neck preparation") : ""
        headInfo.stringValue = String(format: "Head command estimate: %@optical tilt %+.1f°%@\nNeck reference: L6011/U6906 · Insta mount ≈20° back", targets,
            pitch.doubleValue * 180 / .pi, frozen)
    }

    /// Row-major optical-to-scene affine transform, including the shared mesh
    /// scale. There is no second neck rotation or optical-axis approximation.
    func depthCloudCameraTransform(_ belly: Bool) -> [NSNumber] {
        guard let model, belly || headEstimate != nil,
              let frame = model.frames(renderPositions(model.reference, preview: false))[
                belly ? "belly_oak_optical_frame" : "oak_optical_frame"] else { return [] }
        let basis = simd_double4x4(columns: (SIMD4<Double>(modelBasis.columns.0), SIMD4<Double>(modelBasis.columns.1),
            SIMD4<Double>(modelBasis.columns.2), SIMD4<Double>(modelBasis.columns.3)))
        let transform = basis * frame
        return (0..<3).flatMap { row in (0..<4).map { NSNumber(value: transform[$0][row]) } }
    }

    @nonobjc private func renderPositions(_ positions: [String: Double], preview: Bool) -> [String: Double] {
        var result = positions
        for (joint, value) in headEstimate ?? [:] {
            // Live estimates are render-only: saved poses and execution hashes
            // keep their original values; an explicit ghost neck edit wins.
            if !preview || positions[joint] == model?.reference[joint] { result[joint] = value }
        }
        return result
    }

    @nonobjc private func updateOriginal(_ positions: [String: Double]) {
        originalPositions = positions
        updateNodes(originalNodes, positions: renderPositions(positions, preview: false))
    }

    func reviewPresetNamed(_ name: String) {
        presets.selectItem(at: name == "wave" ? 1 : 0)
        selectPreset()
        timeline.doubleValue = 0; play()
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton { NSButton(title: title, target: self, action: selector) }
    private func row(_ views: [NSView]) -> NSStackView { let value = NSStackView(views: views); value.spacing = 7; return value }
    private func buildPanel() {
        let title = NSTextField(labelWithString: "Ghost gestures"); title.font = .boldSystemFont(ofSize: 19)
        let help = NSTextField(wrappingLabelWithString: "Robot: measured left arm and accepted neck command estimates. Blue: proposed motion. Preview and save every named joint; execution currently supports supervised left-arm gestures. Other joints remain reference estimates.")
        help.textColor = .secondaryLabelColor
        headInfo.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        headInfo.identifier = NSUserInterfaceItemIdentifier("ghost-head-command")
        continueButton.target = self; continueButton.action = #selector(continueInteraction)
        continueButton.identifier = NSUserInterfaceItemIdentifier("ghost-continue-interaction")
        continueButton.isHidden = true
        presets.target = self; presets.action = #selector(selectPreset)
        presets.identifier = NSUserInterfaceItemIdentifier("ghost-preset")
        name.placeholderString = "Gesture name"
        joints.target = self; joints.action = #selector(selectJoint)
        angle.target = self; angle.action = #selector(changeAngle); angle.isContinuous = true
        for field in xyz { field.widthAnchor.constraint(equalToConstant: 76).isActive = true }
        let xyzLabels = row([NSTextField(labelWithString: "Forward X / Left Y / Up Z · meters")])
        let targets = row(xyz + [button("Move ghost", #selector(moveTarget))])
        let nudgeRow = row([button("X−", #selector(nudgeXMinus)), button("X+", #selector(nudgeXPlus)),
            button("Y−", #selector(nudgeYMinus)), button("Y+", #selector(nudgeYPlus)),
            button("Z−", #selector(nudgeZMinus)), button("Z+", #selector(nudgeZPlus))])
        let posesRow = row([button("Add pose", #selector(addPose)), button("Undo pose", #selector(undoPose)),
            button("Save gesture", #selector(saveGesture))])
        timeline.target = self; timeline.action = #selector(scrub); timeline.isContinuous = true
        timeline.identifier = NSUserInterfaceItemIdentifier("ghost-timeline")
        executeButton.target = self; executeButton.action = #selector(executeReviewed)
        executeButton.identifier = NSUserInterfaceItemIdentifier("ghost-execute")
        let preview = row([button("Review path", #selector(review)), button("Play ×4", #selector(play)), clock])
        let stop = button("Stop + hold", #selector(stop)); stop.bezelColor = .systemRed
        let currentHelp = NSTextField(wrappingLabelWithString: "Replay: original measured arm, blue approved target. Orange shows the largest joint current jump per sample; scrub to inspect all seven currents. Current units are not calibrated force.")
        currentHelp.textColor = .secondaryLabelColor
        currentPlot.heightAnchor.constraint(equalToConstant: 75).isActive = true
        let stack = NSStackView(views: [title, help, referenceInfo, headInfo, continueButton, presets, name, joints, angle, angleText, xyzLabels, targets, nudgeRow,
            posesRow, poseCount, preview, timeline, identity, executeButton,
            row([stop, button("Review stopped return", #selector(recover))]),
            button("Replay current recording…", #selector(loadRecording)), currentPlot, currentHelp, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = ROBGhostFlippedView(); scroll.documentView = document
        panelView.addSubview(scroll); document.addSubview(stack)
        for value in [scroll, document, stack] { value.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            panelView.widthAnchor.constraint(equalToConstant: 370), scroll.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panelView.trailingAnchor), scroll.topAnchor.constraint(equalTo: panelView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: panelView.bottomAnchor), document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)])
        for value in [help, referenceInfo, headInfo, continueButton, presets, name, joints, angle, timeline, identity, executeButton, currentPlot, currentHelp, status] {
            value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        status.isSelectable = true; identity.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.font = .systemFont(ofSize: 11)
    }

    private struct CapturedRig: Decodable {
        struct Segment: Decodable {
            let link: String, vertexCount: Int, triangleCount: Int
            let positions: Data, normals: Data, colors: Data, indices: Data
        }
        let simulationOnly: Bool
        let segments: [Segment]
    }
    /// Reuse the existing scan's rigid segments, not its convex collision hulls.
    /// The source hash pins both geometry and the provisional URDF assignments.
    private func capturedGeometry(_ model: ROBGhostRobotModel) throws -> [(String, SCNGeometry, SCNGeometry)] {
        let data = try Data(contentsOf: model.directory.appendingPathComponent("robot-visual-rig.json"))
        let surfaces = try JSONSerialization.jsonObject(with: Data(contentsOf:
            model.directory.appendingPathComponent("surfaces.json"))) as? [String: Any]
        guard ROBGhostRobotModel.hash(data) == surfaces?["sourceSHA256"] as? String else {
            throw ROBGhostMotionError.blocked("Captured robot geometry does not match the reviewed URDF surfaces.")
        }
        let rig = try JSONDecoder().decode(CapturedRig.self, from: data)
        guard rig.simulationOnly, Set(rig.segments.map(\.link)) == Set(model.hulls.keys),
              rig.segments.count == model.hulls.count else {
            throw ROBGhostMotionError.blocked("Captured robot segment catalog does not match the URDF.")
        }
        return try rig.segments.map { part in
            guard (1...2_000_000).contains(part.vertexCount), (1...2_000_000).contains(part.triangleCount),
                  part.positions.count == part.vertexCount * 12, part.normals.count == part.vertexCount * 12,
                  part.colors.count == part.vertexCount * 16, part.indices.count == part.triangleCount * 12 else {
                throw ROBGhostMotionError.blocked("Invalid captured robot segment.")
            }
            func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
                SCNGeometrySource(data: data, semantic: semantic, vectorCount: part.vertexCount,
                    usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4,
                    dataOffset: 0, dataStride: components * 4)
            }
            let positions = source(part.positions, .vertex, 3), normals = source(part.normals, .normal, 3)
            let element = SCNGeometryElement(data: part.indices, primitiveType: .triangles,
                primitiveCount: part.triangleCount, bytesPerIndex: 4)
            return (part.link, SCNGeometry(sources: [positions, normals, source(part.colors, .color, 4)], elements: [element]),
                SCNGeometry(sources: [positions, normals], elements: [element]))
        }
    }

    /// The lean-back scan contains skewed neck housings even at zero FK angles.
    /// Use the same mechanical reference for normal and proposed head geometry.
    /// Its dimensions are display envelopes; no motor or collision calibration
    /// is inferred from these shapes. The source scan asset remains unchanged.
    private func referenceHeadNode(link: String, material: SCNMaterial, renderingOrder: Int) -> SCNNode? {
        guard headLinks.contains(link) else { return nil }
        let root = SCNNode()
        func add(_ geometry: SCNGeometry, _ name: String, _ position: SCNVector3,
                 angles: SCNVector3 = SCNVector3Zero, parent: SCNNode? = nil) {
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry); node.name = name
            node.position = position; node.eulerAngles = angles; node.renderingOrder = renderingOrder
            (parent ?? root).addChildNode(node)
        }
        func box(_ name: String, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ position: SCNVector3) {
            add(SCNBox(width: x, height: y, length: z, chamferRadius: 0.004), name, position)
        }
        switch link {
        case "lower_neck_link":
            box("reference-lower-mount", 0.055, 0.07, 0.035, SCNVector3(0, 0, -0.0175))
            box("reference-lower-stem", 0.025, 0.04, 0.13, SCNVector3(0, 0, 0.065))
            box("reference-lower-servo", 0.05, 0.07, 0.05, SCNVector3(0, 0, 0.02))
            add(SCNCylinder(radius: 0.024, height: 0.075), "reference-lower-pitch-axis", SCNVector3(0, 0, 0.02))
        case "neck_pan_link":
            add(SCNCylinder(radius: 0.025, height: 0.026), "reference-pan-servo", SCNVector3(0, 0, 0.013),
                angles: SCNVector3(Float.pi/2, 0, 0))
        case "upper_neck_link":
            box("reference-upper-servo", 0.05, 0.07, 0.07, SCNVector3Zero)
            add(SCNCylinder(radius: 0.022, height: 0.075), "reference-upper-pitch-axis", SCNVector3Zero)
            box("reference-head-support", 0.025, 0.04, 0.04, SCNVector3(0, 0, 0.04))
        case "insta360_link":
            let mount = SCNNode(); mount.name = "reference-insta-mount"
            mount.eulerAngles.y = -20 * .pi / 180; root.addChildNode(mount)
            let sphere = SCNSphere(radius: 0.075); sphere.segmentCount = 24
            add(sphere, "reference-insta-body", SCNVector3Zero, parent: mount)
            for index in 0..<6 {
                let angle = Float(index) * .pi / 3
                add(SCNCylinder(radius: 0.013, height: 0.008), "reference-insta-lens-\(index)",
                    SCNVector3(0.074*cos(angle), 0.074*sin(angle), 0),
                    angles: SCNVector3(0, 0, angle - .pi/2), parent: mount)
            }
            for side: Float in [-1, 1] {
                add(SCNCylinder(radius: 0.003, height: 0.05), "reference-insta-antenna-\(side)",
                    SCNVector3(0, side*0.023, 0.098), angles: SCNVector3(Float.pi/2, 0, 0), parent: mount)
            }
        case "oak_link":
            box("reference-oak-body", 0.025, 0.14, 0.035, SCNVector3Zero)
            for index in -1...1 {
                add(SCNCylinder(radius: 0.008, height: 0.004), "reference-oak-lens-\(index)",
                    SCNVector3(0.015, Float(index)*0.045, 0), angles: SCNVector3(0, 0, -Float.pi/2))
            }
        default: break
        }
        return root
    }

    private func reloadPresets() {
        presets.removeAllItems(); presets.addItems(withTitles: ["Center hand · J6 inward", "Wave above shoulder · J2/J4", "New custom gesture"] + saved.map(\.name))
    }
    private func freshBaseline() -> (q: [Double], generation: UInt64)? {
        let gateway = ROBAmberGatewayClient.shared
        guard gateway.isReady(), let sample = gateway.telemetry(forArm: "right"), sample.effectiveSampleAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7,
              let generation = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value,
              generation > 0 else { return nil }
        return (sample.positionsRadians.map(\.doubleValue), generation)
    }
    private func invalidateReview() {
        if ownsPendingRequest, !ROBLeftArmTrial.shared.isRunning, ROBControllerArmApproval.shared.isPending {
            ROBControllerArmApproval.shared.cancel(reason: "Ghost was edited; review and approve a new path.")
        }
        ownsPendingRequest = false
        setPreviewFrozen(false)
        proposal = nil; playing = false; replayingRecording = false; record = []; currentPlot.values = []
        for node in ghostNodes.values { node.isHidden = false }
        executeButton.isEnabled = false; identity.stringValue = "Unreviewed edits · no hardware output"
    }
    @objc private func selectPreset() {
        guard let model else { return }
        invalidateReview(); poses = []
        let index = presets.indexOfSelectedItem
        if index >= 3, saved.indices.contains(index - 3) {
            let value = saved[index - 3]; poses = value.poses; name.stringValue = value.name
            ghost = poses.last ?? model.reference
        } else if index == 0 {
            name.stringValue = "Centered handoff"; ghost = model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        } else if index == 1 {
            name.stringValue = "Above-shoulder wave"; ghost = model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveRestIndex)!)
        } else {
            name.stringValue = "My gesture"; ghost = model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!)
        }
        joints.selectItem(withTitle: index == 1 ? "left_joint2" : "left_joint6")
        poseCount.stringValue = "\(poses.count) custom poses"; selectJoint(); updateGhost(ghost); review()
    }
    @objc private func selectJoint() {
        guard let model, let title = joints.titleOfSelectedItem,
              let joint = model.joints.first(where: { $0.name == title }) else { return }
        angle.minValue = joint.lower * 180 / .pi; angle.maxValue = joint.upper * 180 / .pi
        angle.doubleValue = (renderPositions(ghost, preview: true)[title] ?? 0) * 180 / .pi
        angleText.stringValue = String(format: "%.1f° · %@", angle.doubleValue, title)
    }
    @objc private func changeAngle() {
        guard !ROBLeftArmTrial.shared.isRunning, let title = joints.titleOfSelectedItem else { return }
        invalidateReview(); presets.selectItem(at: 2); ghost[title] = angle.doubleValue * .pi / 180
        angleText.stringValue = String(format: "%.1f° · %@", angle.doubleValue, title); updateGhost(ghost)
        status.stringValue = "Ghost only. Add this pose, then review the complete path."
    }
    @objc private func moveTarget() {
        guard !ROBLeftArmTrial.shared.isRunning, let model,
              let x = Double(xyz[0].stringValue), let y = Double(xyz[1].stringValue), let z = Double(xyz[2].stringValue) else { return }
        guard let solution = model.solveLeft(target: SIMD3(x, y, z), from: ghost, frontWorkspace: true) else {
            status.stringValue = "That ghost target could not be reached within the model bounds."; return
        }
        invalidateReview(); presets.selectItem(at: 2); ghost = solution; updateGhost(ghost); selectJoint()
        status.stringValue = "Ghost target solved in the URDF. Add pose and review before requesting hardware."
    }
    private func nudge(_ axis: Int, _ sign: Double) {
        guard let position = model?.toolPosition(ghost) else { return }
        var value = position; value[axis] += sign * 0.02
        for i in 0..<3 { xyz[i].stringValue = String(format: "%.3f", value[i]) }; moveTarget()
    }
    @objc private func nudgeXMinus() { nudge(0, -1) }
    @objc private func nudgeXPlus() { nudge(0, 1) }
    @objc private func nudgeYMinus() { nudge(1, -1) }
    @objc private func nudgeYPlus() { nudge(1, 1) }
    @objc private func nudgeZMinus() { nudge(2, -1) }
    @objc private func nudgeZPlus() { nudge(2, 1) }
    @objc private func addPose() {
        guard !ROBLeftArmTrial.shared.isRunning, poses.count < 12 else { return }
        invalidateReview(); presets.selectItem(at: 2); poses.append(ghost); poseCount.stringValue = "\(poses.count) custom poses"
    }
    @objc private func undoPose() {
        guard !ROBLeftArmTrial.shared.isRunning else { return }
        invalidateReview(); if !poses.isEmpty { poses.removeLast() }
        if let last = poses.last { ghost = last; updateGhost(ghost) }; poseCount.stringValue = "\(poses.count) custom poses"
    }
    @objc private func saveGesture() {
        guard !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let model else { return }
        let value = ROBGhostGesture(name: String(name.stringValue.prefix(100)), poses: poses.isEmpty ? [ghost] : poses,
            modelID: model.modelID, referenceID: model.referenceID, geometryID: model.geometryID,
            kind: presets.indexOfSelectedItem == 0 ? "center" : presets.indexOfSelectedItem == 1 ? "wave" : "custom")
        invalidateReview()
        saved.removeAll { $0.name == value.name }; saved.append(value); saved = Array(saved.suffix(40))
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "ROBGhostSavedGestures.v1") }
        reloadPresets(); presets.selectItem(at: saved.count + 2); review()
    }
    @objc private func review() {
        guard !ROBLeftArmTrial.shared.isRunning, let model else { return }
        invalidateReview()
        let fresh = freshBaseline(); liveBaseline = fresh != nil
        if fresh == nil, !ROBAmberGatewayClient.shared.isReady() { ROBAmberGatewayTunnel.shared.connect() }
        let baseline = fresh?.q ?? Array(repeating: 0, count: 7)
        let savedIndex = presets.indexOfSelectedItem - 3
        let kind = presets.indexOfSelectedItem == 0 ? "center" : presets.indexOfSelectedItem == 1 ? "wave"
            : saved.indices.contains(savedIndex) ? saved[savedIndex].kind : "custom"
        do {
            let index = presets.indexOfSelectedItem - 3
            if saved.indices.contains(index), saved[index].modelID != model.modelID || saved[index].referenceID != model.referenceID || saved[index].geometryID != model.geometryID {
                throw ROBGhostMotionError.blocked("Saved gesture uses an older robot model. Inspect and save it against this model before execution.")
            }
            proposal = try ROBLeftGestureCompiler.compile(kind: kind, name: name.stringValue,
                poses: kind == "custom" ? (poses.isEmpty ? [ghost] : poses) : [], model: model,
                baseline: baseline, generation: fresh?.generation ?? 1)
            showReview()
        } catch {
            status.stringValue = error.localizedDescription
            if !ROBAmberGatewayClient.shared.isReady() { ROBAmberGatewayTunnel.shared.connect() }
        }
    }
    private func showReview() {
        guard let proposal else { return }
        replayingRecording = false; timeline.minValue = 0; timeline.maxValue = proposal.seconds; timeline.doubleValue = 0
        identity.stringValue = "\(proposal.name) · \(proposal.steps.count) steps · \(Int(ceil(proposal.seconds))) s\nSHA256 \(proposal.fingerprint.prefix(16))…\nModel \(proposal.modelID.prefix(12))… · session \(proposal.sessionGeneration)"
        executeButton.isEnabled = liveBaseline
        status.stringValue = liveBaseline ? "Review the blue path. Execution needs one approval on the authenticated phone or Vision controller; keep it open. New angles use a model prior and require direct supervision."
            : "Offline preview. Connect the Amber gateway, then Review path again to bind fresh measured position and session."
        renderTime(0)
    }
    @objc private func executeReviewed() {
        guard let proposal, let model, liveBaseline, !replayingRecording else { return }
        // Freeze the preview while awaiting/executing the real operation.
        // A concurrent ×4 animation needlessly contends with live feedback.
        playing = false
        executeButton.isEnabled = false
        ownsPendingRequest = true
        setPreviewFrozen(true)
        ROBLeftArmTrial.shared.perform(proposal: proposal, model: model) { [weak self] result in
            self?.ownsPendingRequest = false
            self?.setPreviewFrozen(false)
            self?.status.stringValue = result["detail"] as? String ?? "Gesture ended"
        }
        status.stringValue = "Review request sent to the authenticated controller. This exact path and hash are frozen; editing cancels a pending request."
    }
    @objc private func recover() {
        guard let model else { return }
        do { invalidateReview(); proposal = try ROBLeftArmTrial.shared.recoveryProposal(model: model); liveBaseline = true; showReview() }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func stop() {
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop + hold in ghost gesture editor")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop + hold in ghost gesture editor")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold(); playing = false
        status.stringValue = "Stop + hold requested. A stopped custom path needs a newly reviewed return."
    }
    @objc private func play() {
        guard proposal != nil || !record.isEmpty else { return }
        playing = true; animationStarted = ProcessInfo.processInfo.systemUptime - timeline.doubleValue / 4
    }
    @objc private func scrub() { playing = false; renderTime(timeline.doubleValue) }
    private func renderTime(_ time: Double) {
        guard let model else { return }
        clock.stringValue = String(format: "%.1f s", time)
        if replayingRecording, !record.isEmpty {
            let sample = record.last(where: { $0.time <= time }) ?? record[0]
            updateOriginal(model.positions(vendorLeft: sample.positions))
            currentPlot.cursor = time; currentPlot.needsDisplay = true
            status.stringValue = "Recording replay · \(String(format: "%.2f", sample.time)) s\n" +
                sample.currents.enumerated().map { String(format: "J%d %.3f", $0.offset + 1, $0.element) }.joined(separator: " · ") +
                String(format: "\nLargest current change: %.3f raw units", sample.deltas.map(abs).max() ?? 0)
            if let proposal {
                let index = sample.step
                if proposal.steps.indices.contains(index) {
                    updateGhost(model.positions(vendorLeft: proposal.steps[index].positions), updateFields: false)
                } else { updateGhost(model.positions(vendorLeft: proposal.baseline), updateFields: false) }
            }
            return
        }
        guard let proposal else { updateGhost(ghost); return }
        var previous = proposal.baseline, elapsed = 0.0
        for step in proposal.steps {
            if time <= elapsed + step.seconds {
                let fraction = max(0, min(1, (time - elapsed) / step.seconds))
                let q = zip(previous, step.positions).map { $0 + ($1 - $0) * fraction }
                updateGhost(model.positions(vendorLeft: q), updateFields: false); return
            }
            previous = step.positions; elapsed += step.seconds
        }
        updateGhost(model.positions(vendorLeft: previous), updateFields: false)
    }
    private func updateNodes(_ nodes: [String: SCNNode], positions: [String: Double]) {
        guard let model else { return }
        let frames = model.frames(positions)
        var changes: [(SCNNode, simd_float4x4)] = []
        for (link, node) in nodes {
            if let transform = frames[link] {
                let value = simd_float4x4(columns: (SIMD4<Float>(transform.columns.0), SIMD4<Float>(transform.columns.1),
                    SIMD4<Float>(transform.columns.2), SIMD4<Float>(transform.columns.3)))
                if node.simdTransform != value { changes.append((node, value)) }
            }
        }
        guard !changes.isEmpty else { return }
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        for (node, transform) in changes { node.simdTransform = transform }
        SCNTransaction.commit()
    }
    private func updateGhost(_ positions: [String: Double], updateFields: Bool = true) {
        ghostDisplayPositions = positions
        updateNodes(ghostNodes, positions: renderPositions(positions, preview: true))
        if updateFields, let tip = model?.toolPosition(positions) {
            for i in 0..<3 { xyz[i].stringValue = String(format: "%.3f", tip[i]) }
        }
    }
    private func tick() {
        guard let model else { return }
        refreshInteractionStage()
        let busy = ROBLeftArmTrial.shared.isRunning || ROBArmRoutineCoordinator.shared.isRunning
        for view in [presets, joints, angle, name] as [NSControl] { view.isEnabled = !busy }
        if busy || (ownsPendingRequest && ROBControllerArmApproval.shared.isPending) {
            // For operations launched elsewhere, hide without taking a costly
            // snapshot after motion has already started.
            sceneView?.isHidden = true; playing = false; executeButton.isEnabled = false
            referenceInfo.stringValue = busy ? "Preview frozen · measured motion and currents are being recorded."
                : "Preview frozen · waiting for controller approval."
            if busy { status.stringValue = ROBLeftArmTrial.shared.status }
            return
        }
        if previewFrozen { setPreviewFrozen(false) }
        else if sceneView?.isHidden == true {
            sceneView?.isHidden = false
            updateGhost(ghostDisplayPositions, updateFields: false)
        }
        let base = capturedRobot.presentation.simdWorldTransform * modelBasis
        if renderRoot.simdTransform != base { renderRoot.simdTransform = base }
        let now = ProcessInfo.processInfo.systemUptime
        if !replayingRecording, now - lastOriginalUpdate > 0.2 {
            lastOriginalUpdate = now
            let baseline = freshBaseline()
            updateOriginal(baseline.map { model.positions(vendorLeft: $0.q) } ?? model.reference)
            referenceInfo.stringValue = (baseline == nil ? "Left: scan reference; fresh encoders unavailable."
                : "Left: fresh encoders with upright mapping prior.") +
                (headEstimate == nil ? " Head: reference; command estimate unavailable." : " Head: accepted neck command estimate.") +
                " Other joints: scan reference."
        }
        if let proposal, let fresh = freshBaseline(), !busy, !ROBControllerArmApproval.shared.isPending, !replayingRecording {
            executeButton.isEnabled = liveBaseline && fresh.generation == proposal.sessionGeneration
                && ROBArmRoutinePlan.near(fresh.q, proposal.baseline, tolerance: 0.015)
        } else { executeButton.isEnabled = false }
        if busy { status.stringValue = ROBLeftArmTrial.shared.status }
        if playing {
            let time = min(timeline.maxValue, (now - animationStarted) * 4)
            timeline.doubleValue = time; renderTime(time)
            if time >= timeline.maxValue { playing = false }
        }
    }

    private func refreshInteractionStage() {
        let stage = ROBLeftArmTrial.shared.interactionStage
        let title: String
        switch stage {
        case "object_placed": title = "Object placed; fingers clear → grip"
        case "receiver_supporting": title = "Hand supporting → release"
        case "object_clear": title = "Object clear → lower"
        default: title = ""
        }
        displayedInteractionStage = stage
        continueButton.title = title
        continueButton.isHidden = title.isEmpty
        continueButton.isEnabled = !title.isEmpty && ROBLeftArmTrial.shared.isRunning
    }

    @objc private func continueInteraction() {
        let stage = displayedInteractionStage
        guard !stage.isEmpty, ROBLeftArmTrial.shared.continueOperation(stage: stage) else { return }
        continueButton.isEnabled = false
        refreshInteractionStage()
    }
    @objc private func loadRecording() {
        guard !ROBLeftArmTrial.shared.isRunning else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.allowsMultipleSelection = false
        let latest = ROBLeftArmTrial.shared.lastRecordingPath
        if !latest.isEmpty { panel.directoryURL = URL(fileURLWithPath: latest).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url, let model else { return }
        do {
            let samples = try ROBGhostRecordingSample.load(url)
            let manifest = url.deletingPathExtension().appendingPathExtension("proposal.json")
            let manifestData = try? Data(contentsOf: manifest)
            let frozen = manifestData.flatMap { $0.count <= 2_000_000 ? try? JSONDecoder().decode(ROBLeftGestureProposal.self, from: $0) : nil }
            if let frozen {
                guard frozen.validForReplay(model: model) else {
                    throw ROBGhostMotionError.blocked("Recording manifest is invalid or uses a different model/mapping.")
                }
            }
            invalidateReview(); record = samples; proposal = frozen; replayingRecording = true; liveBaseline = false
            for node in ghostNodes.values { node.isHidden = frozen == nil }
            timeline.maxValue = samples.last?.time ?? 1; timeline.doubleValue = 0
            currentPlot.values = samples.map { ($0.time, $0.deltas.map(abs).max() ?? 0) }
            identity.stringValue = "RECORDING REPLAY · no execution\n\(url.lastPathComponent)"
            status.stringValue = "Original: measured left joints. Blue: approved step target when a matching manifest exists. Raw-current trace below; scrub to inspect peaks."
            renderTime(0)
        } catch { status.stringValue = error.localizedDescription }
    }
}

private final class ROBGhostFlippedView: NSView { override var isFlipped: Bool { true } }

private final class ROBGhostCurrentPlot: NSView {
    var values: [(Double, Double)] = [] { didSet { needsDisplay = true } }
    var cursor = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        guard let end = values.last?.0, end > 0 else { return }
        let maximum = max(0.001, values.map(\.1).max() ?? 1), path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let point = NSPoint(x: value.0 / end * bounds.width, y: 4 + value.1 / maximum * (bounds.height - 8))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.systemOrange.setStroke(); path.lineWidth = 1.2; path.stroke()
        let marker = NSBezierPath(); marker.move(to: NSPoint(x: cursor / end * bounds.width, y: 0))
        marker.line(to: NSPoint(x: cursor / end * bounds.width, y: bounds.height)); NSColor.systemBlue.setStroke(); marker.stroke()
    }
}
