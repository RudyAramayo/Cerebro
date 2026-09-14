import AppKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import UniformTypeIdentifiers
import simd

private final class ROBGeometryInspectorStack: NSStackView {
    override var isFlipped: Bool { true }
}

@objc(ROBRobotGeometryWindowController)
public final class ROBRobotGeometryWindowController: NSWindowController {
    @objc public static let shared = ROBRobotGeometryWindowController()
    var profile = ROBGeometryProfile.draft()
    private var vendor: ROBGeometryVendor?
    private let sceneView = SCNView(frame: .zero)
    private let robotRoot = SCNNode()
    private let scanRoot = SCNNode()
    private let modelRoot = SCNNode()
    private let cloudRoot = SCNNode()
    private var meshCache: [String: SCNGeometry] = [:]
    private let jointMenu = NSPopUpButton()
    private let parentMenu = NSPopUpButton()
    private let kindMenu = NSPopUpButton()
    private let evidenceLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Draft estimates. No robot commands are available in this window.")
    private let cloudLabel = NSTextField(wrappingLabelWithString: "Depth: waiting for calibrated OAK RGB-D in Cerebro; imports work offline.")
    private let qSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let qField = NSTextField(string: "0")
    private var originFields: [NSTextField] = []
    private var axisFields: [NSTextField] = []
    private var limitFields: [NSTextField] = []
    private var boxFields: [NSTextField] = []
    private var boxOriginFields: [NSTextField] = []
    private var scanFields: [NSTextField] = []
    private var lactFields: [NSTextField] = []
    private var targetFields: [NSTextField] = []
    private let scaleField = NSTextField(string: "1")
    private let armMenu = NSPopUpButton()
    private let axesToggle = NSButton(checkboxWithTitle: "Joint frames and axes", target: nil, action: nil)
    private let envelopesToggle = NSButton(checkboxWithTitle: "Approximate collision envelopes", target: nil, action: nil)
    private let cloudToggle = NSButton(checkboxWithTitle: "Show latest depth at preview camera pose", target: nil, action: nil)
    private let modelToggle = NSButton(checkboxWithTitle: "Show robot model (off to inspect scan)", target: nil, action: nil)
    private var lastCloudUptime: TimeInterval = 0
    private var lastCloudSource = ""
    private var cloudObserver: NSObjectProtocol?
    private var cloudTimer: Timer?
    private var target: SIMD3<Double>?
    private let assetQueue = DispatchQueue(label: "com.orbitusrobotics.geometry.assets", qos: .userInitiated)
    private var scanLoadID = UUID()
    private var vendorLoadID = UUID()
    #if !ROB_GEOMETRY_STANDALONE
    private let cloudLock = NSLock()
    private var pendingCloud: ROBDepthCloudFrame?
    #endif

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ROB Geometry Lab — Simulation"
        window.minSize = NSSize(width: 980, height: 680)
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        buildInterface(); buildScene(); populateMenus(); refreshFields(); render()
        window.center()
        #if !ROB_GEOMETRY_STANDALONE
        // Never queue every camera frame on the UI thread or block its producer.
        // Retain at most one pending frame; the display timer consumes the latest.
        cloudObserver = NotificationCenter.default.addObserver(forName: .ROBDepthCloudFrame, object: nil, queue: nil) { [weak self] notification in
            guard let self, let frame = notification.object as? ROBDepthCloudFrame else { return }
            self.cloudLock.lock(); self.pendingCloud = frame; self.cloudLock.unlock()
        }
        #endif
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            #if !ROB_GEOMETRY_STANDALONE
            self.cloudLock.lock(); let frame = self.pendingCloud; self.pendingCloud = nil; self.cloudLock.unlock()
            if let frame { self.offerCloud(frame) }
            #endif
            guard self.lastCloudUptime > 0 else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastCloudUptime > 1 {
                self.cloudRoot.childNodes.forEach { $0.removeFromParentNode() }
                self.cloudLabel.stringValue = "Depth stale — cloud hidden. Preview transforms are not measured live joint state."
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use shared") }
    deinit { if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }; cloudTimer?.invalidate() }
    public override func showWindow(_ sender: Any?) { super.showWindow(sender); window?.makeKeyAndOrderFront(sender) }

    private func label(_ title: String, size: CGFloat = 11, bold: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: title)
        view.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return view
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 6
        return stack
    }
    private func fields(_ names: [String], into collection: inout [NSTextField], stack: NSStackView) {
        let controls = names.map { title -> NSView in
            let field = NSTextField(string: "0"); field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
            collection.append(field)
            let column = NSStackView(views: [label(title), field]); column.orientation = .vertical; column.alignment = .leading
            return column
        }
        let group = row(controls); group.distribution = .fillEqually; stack.addArrangedSubview(group)
    }
    private func section(_ title: String, _ stack: NSStackView) { stack.addArrangedSubview(label(title, size: 12, bold: true)) }
    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let inspector = ROBGeometryInspectorStack(); inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 10
        inspector.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = inspector
        let right = NSStackView(); right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        let title = label("ROBOT GEOMETRY LAB", size: 18, bold: true)
        let subtitle = label("Simulation only • meters in files, millimeters/degrees in controls • X forward / Y ROB-left / Z up", size: 11)
        for view in [title, subtitle, sceneView, statusLabel, cloudLabel] { right.addArrangedSubview(view) }
        for view in [scroll, right] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor), scroll.widthAnchor.constraint(equalToConstant: 370),
            inspector.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            right.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 14), right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), right.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), right.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            sceneView.widthAnchor.constraint(equalTo: right.widthAnchor), sceneView.heightAnchor.constraint(greaterThanOrEqualToConstant: 390),
            statusLabel.widthAnchor.constraint(equalTo: right.widthAnchor), cloudLabel.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
        sceneView.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cloudLabel.font = .systemFont(ofSize: 10)
        cloudLabel.textColor = .secondaryLabelColor
        section("1  PROFILE & VENDOR MODEL", inspector)
        inspector.addArrangedSubview(row([button("Open…", #selector(openProfile)), button("Save…", #selector(saveProfile)), button("Export URDF…", #selector(exportURDF))]))
        inspector.addArrangedSubview(row([button("Load single B1 URDF…", #selector(loadVendor)), button("URDF zero", #selector(zeroPose))]))
        inspector.addArrangedSubview(label("Mounts and body sizes are estimates. Hanging startup offsets belong in each boot’s arm reference, not in joint origins."))
        section("2  FRAME & JOINT CALIBRATION", inspector)
        jointMenu.target = self; jointMenu.action = #selector(selectionChanged)
        inspector.addArrangedSubview(jointMenu)
        inspector.addArrangedSubview(row([label("Parent"), parentMenu, kindMenu]))
        fields(["X mm", "Y mm", "Z mm"], into: &originFields, stack: inspector)
        fields(["Roll °", "Pitch °", "Yaw °"], into: &originFields, stack: inspector)
        fields(["Axis X", "Axis Y", "Axis Z"], into: &axisFields, stack: inspector)
        fields(["Lower ° / mm", "Upper ° / mm"], into: &limitFields, stack: inspector)
        inspector.addArrangedSubview(label("Preview q (degrees; millimeters for prismatic)"))
        qSlider.target = self; qSlider.action = #selector(slideJoint); qSlider.isContinuous = true
        inspector.addArrangedSubview(row([qSlider, qField]))
        fields(["Box X mm", "Box Y mm", "Box Z mm"], into: &boxFields, stack: inspector)
        fields(["Box offset X", "Box offset Y", "Box offset Z"], into: &boxOriginFields, stack: inspector)
        inspector.addArrangedSubview(button("Apply frame / limits / envelope", #selector(applyJoint)))
        inspector.addArrangedSubview(button("Fit fixed mount from landmarks…", #selector(fitMount)))
        evidenceLabel.font = .systemFont(ofSize: 10); evidenceLabel.textColor = .secondaryLabelColor
        inspector.addArrangedSubview(evidenceLabel)
        axesToggle.state = .on; axesToggle.target = self; axesToggle.action = #selector(togglesChanged)
        envelopesToggle.target = self; envelopesToggle.action = #selector(togglesChanged)
        inspector.addArrangedSubview(axesToggle); inspector.addArrangedSubview(envelopesToggle)
        section("3  SCAN OVERLAY", inspector)
        inspector.addArrangedSubview(button("Import mesh / point cloud…", #selector(importScan)))
        modelToggle.state = .on; modelToggle.target = self; modelToggle.action = #selector(togglesChanged)
        inspector.addArrangedSubview(modelToggle)
        fields(["Scan X mm", "Scan Y mm", "Scan Z mm"], into: &scanFields, stack: inspector)
        fields(["Scan roll °", "Scan pitch °", "Scan yaw °"], into: &scanFields, stack: inspector)
        inspector.addArrangedSubview(row([label("Scale → meters"), scaleField]))
        inspector.addArrangedSubview(row([button("Apply scan transform", #selector(applyScan)), button("Fit scan…", #selector(fitScan))]))
        inspector.addArrangedSubview(label("Click the scene for XYZ in the base frame. Scale must come from a known length; rigid fitting never changes scale."))
        cloudToggle.target = self; cloudToggle.action = #selector(togglesChanged)
        inspector.addArrangedSubview(cloudToggle)
        section("4  LACT PIN CENTERS", inspector)
        fields(["Base X mm", "Base Y mm", "Base Z mm"], into: &lactFields, stack: inspector)
        fields(["Lean X mm", "Lean Y mm", "Lean Z mm"], into: &lactFields, stack: inspector)
        inspector.addArrangedSubview(button("Apply LACT anchors", #selector(applyLACT)))
        inspector.addArrangedSubview(label("Anchors are local to base_link and lean_link. The derived pin distance changes nonlinearly with body_lean."))
        section("5  BALL REACH PREVIEW", inspector)
        armMenu.addItems(withTitles: ["left", "right"]); inspector.addArrangedSubview(armMenu)
        fields(["Target X mm", "Target Y mm", "Target Z mm"], into: &targetFields, stack: inspector)
        [400.0, 250.0, 650.0].enumerated().forEach { targetFields[$0.offset].doubleValue = $0.element }
        inspector.addArrangedSubview(button("Preview position-only IK", #selector(previewReach)))
        inspector.addArrangedSubview(button("Open URDF Pose IK…", #selector(openPoseIK)))
        inspector.addArrangedSubview(label("Preview only: no wrist-orientation goal, grasp, trajectory, or hardware command. Envelope overlaps are approximate warnings, not certified collision checks."))
        for view in inspector.arrangedSubviews { view.widthAnchor.constraint(lessThanOrEqualTo: inspector.widthAnchor, constant: -32).isActive = true }
    }

    private func buildScene() {
        let scene = SCNScene(); sceneView.scene = scene; sceneView.allowsCameraControl = true
        sceneView.backgroundColor = NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.055, alpha: 1)
        sceneView.autoenablesDefaultLighting = true; sceneView.antialiasingMode = .multisampling4X
        robotRoot.simdTransform = simd_float4x4(columns: (SIMD4(0, 0, -1, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
        scene.rootNode.addChildNode(robotRoot); robotRoot.addChildNode(modelRoot); robotRoot.addChildNode(scanRoot); robotRoot.addChildNode(cloudRoot)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.01; camera.camera?.zFar = 30; camera.camera?.fieldOfView = 38
        camera.position = SCNVector3(1.4, 1.25, -2.2); camera.look(at: SCNVector3(0, 0.72, 0)); scene.rootNode.addChildNode(camera); sceneView.pointOfView = camera
        sceneView.defaultCameraController.target = SCNVector3(0, 0.72, 0)
        let floor = SCNFloor(); floor.reflectivity = 0; floor.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.10, alpha: 1)
        scene.rootNode.addChildNode(SCNNode(geometry: floor))
        for i in -10...10 {
            let d = Double(i) / 10
            robotRoot.addChildNode(line(SIMD3(-1, d, 0.002), SIMD3(1, d, 0.002), color: i == 0 ? .systemRed : .darkGray, radius: 0.0006))
            robotRoot.addChildNode(line(SIMD3(d, -1, 0.002), SIMD3(d, 1, 0.002), color: i == 0 ? .systemGreen : .darkGray, radius: 0.0006))
        }
        let click = NSClickGestureRecognizer(target: self, action: #selector(inspectPoint(_:))); sceneView.addGestureRecognizer(click)
    }

    @objc private func openPoseIK() { ROBArmIKWindowController.shared.showWindow(nil) }
    private func floats(_ m: simd_double4x4) -> simd_float4x4 { .init(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3))) }
    private func material(_ color: NSColor, wire: Bool = false) -> SCNMaterial {
        let value = SCNMaterial(); value.diffuse.contents = color; value.roughness.contents = 0.7; value.isDoubleSided = true
        if wire { value.fillMode = .lines; value.lightingModel = .constant }
        return value
    }
    private func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>, color: NSColor, radius: CGFloat) -> SCNNode {
        let delta = b - a, length = simd_length(delta)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(max(0.00001, length))); cylinder.radialSegmentCount = 8; cylinder.materials = [material(color)]
        let node = SCNNode(geometry: cylinder); node.simdPosition = SIMD3<Float>((a + b) / 2)
        if length > 1e-8 { node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3<Float>(delta / length)) }
        return node
    }
    private func axes() -> SCNNode {
        let root = SCNNode()
        for (axis, color) in [(SIMD3<Double>(0.085, 0, 0), NSColor.systemRed), (SIMD3<Double>(0, 0.085, 0), .systemGreen), (SIMD3<Double>(0, 0, 0.085), .systemBlue)] { root.addChildNode(line(.zero, axis, color: color, radius: 0.002)) }
        return root
    }
    private func render(_ message: String? = nil) {
        modelRoot.isHidden = modelToggle.state != .on
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        let frames = profile.transforms(), overlaps = profile.envelopeOverlaps()
        let overlapping = Set(overlaps.flatMap { [$0.0, $0.1] })
        for link in profile.links {
            guard let transform = frames[link.name] else { continue }
            let root = SCNNode(); root.name = link.name; root.simdTransform = floats(transform)
            let color: NSColor = link.name.hasPrefix("left_") ? .systemTeal : link.name.hasPrefix("right_") ? .systemOrange : .systemGray
            if let vendorLink = link.vendorLink, let geometry = meshCache[vendorLink] {
                let mesh = SCNNode(geometry: geometry.copy() as? SCNGeometry); mesh.geometry?.materials = [material(color)]; root.addChildNode(mesh)
            } else {
                let box = SCNBox(width: CGFloat(link.boxMeters[0]), height: CGFloat(link.boxMeters[1]), length: CGFloat(link.boxMeters[2]), chamferRadius: 0.004)
                box.materials = [material(color.withAlphaComponent(0.8))]
                let node = SCNNode(geometry: box); node.simdTransform = floats(link.boxOrigin.matrix); root.addChildNode(node)
            }
            if envelopesToggle.state == .on {
                let box = SCNBox(width: CGFloat(link.boxMeters[0]), height: CGFloat(link.boxMeters[1]), length: CGFloat(link.boxMeters[2]), chamferRadius: 0)
                box.materials = [material(overlapping.contains(link.name) ? .systemRed : .systemYellow, wire: true)]
                let node = SCNNode(geometry: box); node.simdTransform = floats(link.boxOrigin.matrix); root.addChildNode(node)
            }
            if axesToggle.state == .on { root.addChildNode(axes()) }
            modelRoot.addChildNode(root)
        }
        scanRoot.simdTransform = floats(profile.scanToBase.matrix); scanRoot.simdScale = SIMD3(repeating: Float(profile.scanScale)); scanRoot.opacity = 0.45
        if let endpoints = profile.lactEndpoints() { modelRoot.addChildNode(line(endpoints.0, endpoints.1, color: .systemPurple, radius: 0.018)) }
        if let target {
            let sphere = SCNSphere(radius: 0.035); sphere.materials = [material(.systemPink)]
            let node = SCNNode(geometry: sphere); node.name = "ball_target"; node.simdPosition = SIMD3<Float>(target); modelRoot.addChildNode(node)
        }
        let length = profile.lactEndpoints().map { String(format: "%.1f mm", simd_distance($0.0, $0.1) * 1000) } ?? "unknown"
        let warnings = overlaps.prefix(3).map { "\($0.0) ↔ \($0.1)" }.joined(separator: "; ")
        statusLabel.stringValue = [message ?? "\(profile.name) — physical calibration unverified.", "\(overlaps.count) approximate envelope overlaps. LACT pin distance: \(length). Grid: 100 mm.", warnings].filter { !$0.isEmpty }.joined(separator: "\n")
        // A cloud captured at another preview pose cannot remain registered
        // after a joint edit. The next valid frame will use the new preview.
        cloudRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    private var selectedIndex: Int { max(0, jointMenu.indexOfSelectedItem) }
    private var selectedJoint: ROBGeometryJoint { profile.joints[selectedIndex] }
    private func factor(_ joint: ROBGeometryJoint) -> Double { joint.kind == "prismatic" ? 1000 : 180 / .pi }
    private func populateMenus() {
        jointMenu.removeAllItems(); jointMenu.addItems(withTitles: profile.joints.map(\.name))
        parentMenu.removeAllItems(); parentMenu.addItems(withTitles: profile.links.map(\.name))
        kindMenu.removeAllItems(); kindMenu.addItems(withTitles: ["fixed", "revolute", "prismatic", "continuous"])
        jointMenu.selectItem(withTitle: "left_b1_mount")
    }
    private func fill(_ fields: [NSTextField], _ values: [Double]) { for (field, value) in zip(fields, values) { field.stringValue = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value) } }
    private func numbers(_ fields: [NSTextField]) throws -> [Double] {
        try fields.map { guard let value = Double($0.stringValue), value.isFinite else { throw ROBGeometryError.invalid("Enter finite numbers, using a decimal point.") }; return value }
    }
    private func refreshFields() {
        let joint = selectedJoint, scale = factor(joint)
        parentMenu.selectItem(withTitle: joint.parent); kindMenu.selectItem(withTitle: joint.kind)
        fill(originFields, joint.origin.xyzMeters.map { $0 * 1000 } + joint.origin.rpyRadians.map { $0 * 180 / .pi })
        fill(axisFields, joint.axis); fill(limitFields, [joint.lower * scale, joint.upper * scale])
        qSlider.minValue = joint.kind == "continuous" ? -180 : joint.lower * scale
        qSlider.maxValue = joint.kind == "continuous" ? 180 : max(qSlider.minValue + 0.001, joint.upper * scale)
        qSlider.isEnabled = joint.kind != "fixed"; qField.isEnabled = joint.kind != "fixed"
        qSlider.doubleValue = (profile.previewPositions[joint.name] ?? 0) * scale; qField.doubleValue = qSlider.doubleValue
        if let link = profile.links.first(where: { $0.name == joint.child }) {
            fill(boxFields, link.boxMeters.map { $0 * 1000 }); fill(boxOriginFields, link.boxOrigin.xyzMeters.map { $0 * 1000 })
        }
        fill(scanFields, profile.scanToBase.xyzMeters.map { $0 * 1000 } + profile.scanToBase.rpyRadians.map { $0 * 180 / .pi }); scaleField.doubleValue = profile.scanScale
        fill(lactFields, (profile.lact.fixedAnchorMeters + profile.lact.movingAnchorMeters).map { $0 * 1000 })
        evidenceLabel.stringValue = "\(joint.evidence.source): \(joint.evidence.note)\n\(joint.hardwareAnnotation)"
    }
    private func perform(_ body: () throws -> Void) { do { try body() } catch { statusLabel.stringValue = "Could not apply: \(error.localizedDescription)" } }
    @objc private func selectionChanged() { refreshFields() }
    @objc private func togglesChanged() { render() }
    @objc private func zeroPose() { perform {
        var candidate = profile; candidate.previewPositions = [:]; try candidate.validate()
        profile = candidate; refreshFields(); render("URDF zero pose. This is not ROB’s gravity-hanging startup pose.")
    } }
    @objc private func slideJoint() {
        let joint = selectedJoint; guard joint.kind != "fixed" else { return }
        profile.previewPositions[joint.name] = qSlider.doubleValue / factor(joint); qField.doubleValue = qSlider.doubleValue
        render("Preview \(joint.name): \(qField.stringValue). Hardware has not moved.")
    }
    @objc private func applyJoint() { perform {
        var candidate = profile, joint = selectedJoint
        let values = try numbers(originFields), limits = try numbers(limitFields)
        joint.origin = .init(xyzMeters: Array(values[0..<3]).map { $0 / 1000 }, rpyRadians: Array(values[3..<6]).map { $0 * .pi / 180 })
        let axis = try numbers(axisFields), axisLength = sqrt(axis.reduce(0) { $0 + $1 * $1 })
        guard axisLength.isFinite && axisLength > 1e-8 else { throw ROBGeometryError.invalid("Enter a nonzero axis; it will be normalized.") }
        joint.axis = axis.map { $0 / axisLength }; joint.parent = parentMenu.titleOfSelectedItem ?? joint.parent; joint.kind = kindMenu.titleOfSelectedItem ?? joint.kind
        joint.lower = limits[0] / factor(joint); joint.upper = limits[1] / factor(joint)
        joint.evidence = .init(note: "Manually edited draft. Validate with independent landmarks and record uncertainty.")
        candidate.joints[selectedIndex] = joint
        candidate.landmarkFits?.removeValue(forKey: joint.name)
        candidate.previewPositions[joint.name] = joint.kind == "fixed" ? 0 : try numbers([qField])[0] / factor(joint)
        if let i = candidate.links.firstIndex(where: { $0.name == joint.child }) {
            candidate.links[i].boxMeters = try numbers(boxFields).map { $0 / 1000 }
            candidate.links[i].boxOrigin.xyzMeters = try numbers(boxOriginFields).map { $0 / 1000 }
            candidate.links[i].evidence = .init(note: "Manually edited envelope; measurement and uncertainty unverified.")
        }
        try candidate.validate(); profile = candidate; refreshFields(); render("Draft frame updated. Calibration evidence must be rechecked.")
    } }
    @objc private func applyScan() { perform {
        var candidate = profile; let values = try numbers(scanFields)
        candidate.scanToBase = .init(xyzMeters: Array(values[0..<3]).map { $0 / 1000 }, rpyRadians: Array(values[3..<6]).map { $0 * .pi / 180 })
        candidate.scanScale = try numbers([scaleField])[0]; try candidate.validate(); profile = candidate; render()
        profile.landmarkFits?.removeValue(forKey: "scanToBase")
    } }
    @objc private func applyLACT() { perform {
        var candidate = profile; let values = try numbers(lactFields).map { $0 / 1000 }
        candidate.lact.fixedAnchorMeters = Array(values[0..<3]); candidate.lact.movingAnchorMeters = Array(values[3..<6]); candidate.lact.evidence = .init()
        try candidate.validate(); profile = candidate; render()
    } }
    @objc private func previewReach() { perform {
        let xyz = try numbers(targetFields).map { $0 / 1000 }; let goal = SIMD3(xyz[0], xyz[1], xyz[2])
        guard let solution = profile.previewIK(arm: armMenu.titleOfSelectedItem ?? "left", target: goal) else { throw ROBGeometryError.invalid("Missing B1 chain or invalid target.") }
        profile.previewPositions = solution.positions; target = goal; refreshFields()
        render(String(format: "Position-only IK residual: %.1f mm. Orientation and trajectory unplanned; no hardware command.", solution.errorMeters * 1000))
    } }

    private func openPanel(_ title: String, extensions: [String]) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.allowedContentTypes = extensions.map { UTType(filenameExtension: $0) ?? .data }
        return panel.runModal() == .OK ? panel.url : nil
    }
    @objc private func openProfile() { guard let url = openPanel("Open geometry profile", extensions: ["json"]) else { return }; perform {
        try installProfile(.load(url))
    } }
    func installProfile(_ newProfile: ROBGeometryProfile) throws {
        try newProfile.validate(); profile = newProfile; target = nil
        scanLoadID = UUID()
        scanRoot.childNodes.forEach { $0.removeFromParentNode() }; cloudRoot.childNodes.forEach { $0.removeFromParentNode() }
        populateMenus(); refreshFields(); render("Profile loaded. Reimport its scan; scan transforms are saved, file contents are not.")
    }
    @objc private func saveProfile() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "rob_geometry_calibration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try profile.encoded().write(to: url, options: .atomic); render("Saved \(url.lastPathComponent)") }
    }
    @objc private func exportURDF() {
        let panel = NSSavePanel(); panel.title = "Create a new calibration bundle folder"; panel.nameFieldStringValue = "ROB-Calibration-\(Int(Date().timeIntervalSince1970))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let savedProfile = profile, savedVendor = vendor
        statusLabel.stringValue = "Exporting the current profile and meshes…"
        assetQueue.async { [weak self] in
            let result = Result { try ROBGeometryURDF.export(savedProfile, vendor: savedVendor, to: url) }
            DispatchQueue.main.async {
                self?.perform { try result.get(); self?.render("Exported \(url.lastPathComponent): URDF, captured profile, meshes, and limitations.") }
            }
        }
    }
    @objc private func loadVendor() {
        guard let url = openPanel("Choose the single-arm amber_b1.urdf", extensions: ["urdf"]) else { return }
        let id = UUID(); vendorLoadID = id; statusLabel.stringValue = "Loading original B1 meshes…"
        assetQueue.async { [weak self] in
            let result = Result { try Self.vendorAsset(url) }
            DispatchQueue.main.async {
                guard let self, self.vendorLoadID == id else { return }
                self.perform { let (candidate, cache) = try result.get(); self.applyVendor(candidate, cache: cache) }
            }
        }
    }
    private static func vendorAsset(_ url: URL) throws -> (ROBGeometryVendor, [String: SCNGeometry]) {
        let candidate = try ROBGeometryVendor(url: url); var cache: [String: SCNGeometry] = [:]
        for name in candidate.links.keys { if let mesh = try candidate.visualMesh(for: name) { cache[name] = try Self.binarySTL(mesh) } }
        return (candidate, cache)
    }
    func installVendor(_ url: URL) throws {
        let (candidate, cache) = try Self.vendorAsset(url)
        applyVendor(candidate, cache: cache)
    }
    private func applyVendor(_ candidate: ROBGeometryVendor, cache: [String: SCNGeometry]) {
        vendor = candidate; meshCache = cache
        for i in profile.links.indices {
            if let name = profile.links[i].vendorLink, let geometry = cache[name],
               profile.links[i].evidence.source == "unmeasured",
               profile.links[i].evidence.note == ROBGeometryEvidence().note {
                let bounds = geometry.boundingBox
                profile.links[i].boxMeters = [Double(bounds.max.x - bounds.min.x), Double(bounds.max.y - bounds.min.y), Double(bounds.max.z - bounds.min.z)].map { max(0.001, $0) }
                profile.links[i].boxOrigin = .init(xyzMeters: [Double(bounds.max.x + bounds.min.x) / 2, Double(bounds.max.y + bounds.min.y) / 2, Double(bounds.max.z + bounds.min.z) / 2])
                profile.links[i].evidence = .init(source: "vendor", note: "Visual-mesh AABB; broad-phase preview only. Does not include cables or payload.")
            }
        }
        refreshFields(); render("Loaded original B1 meshes for both arms. Mounts and boot references remain uncalibrated.")
    }
    static func binarySTL(_ url: URL) throws -> SCNGeometry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 84 else { throw ROBGeometryError.invalid("Invalid binary STL.") }
        let count = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))) }
        guard count > 0 && count <= 2_000_000 && data.count == 84 + count * 50 else { throw ROBGeometryError.invalid("Expected binary STL with at most two million triangles.") }
        var vertices: [SCNVector3] = []; vertices.reserveCapacity(count * 3)
        var normals: [SCNVector3] = []; normals.reserveCapacity(count * 3)
        data.withUnsafeBytes { raw in
            for triangle in 0..<count {
                var points: [SIMD3<Float>] = []
                for vertex in 0..<3 {
                    let offset = 84 + triangle * 50 + 12 + vertex * 12
                    func f(_ delta: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + delta, as: UInt32.self))) }
                    let p = SIMD3(f(0), f(4), f(8)); points.append(p); vertices.append(SCNVector3(p))
                }
                let cross = simd_cross(points[1] - points[0], points[2] - points[0])
                let normal = simd_length(cross) > 1e-12 ? simd_normalize(cross) : SIMD3<Float>(0, 0, 1)
                normals.append(contentsOf: Array(repeating: SCNVector3(normal), count: 3))
            }
        }
        guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ROBGeometryError.invalid("Non-finite STL vertices.") }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: [SCNGeometryElement(data: nil, primitiveType: .triangles, primitiveCount: count, bytesPerIndex: 0)])
    }
    @objc private func importScan() {
        guard let url = openPanel("Import a scan mesh or point cloud", extensions: ["usdz", "obj", "ply", "stl", "dae", "scn"]) else { return }
        let id = UUID(); scanLoadID = id; statusLabel.stringValue = "Importing scan…"
        assetQueue.async { [weak self] in
            let result = Result { try Self.scanAsset(url) }
            DispatchQueue.main.async {
                guard let self, self.scanLoadID == id else { return }
                self.perform {
                    let node = try result.get()
                    self.scanRoot.childNodes.forEach { $0.removeFromParentNode() }; self.scanRoot.addChildNode(node)
                    self.render("Scan loaded. Set scale from a known length, then register landmarks.")
                }
            }
        }
    }
    private static func scanAsset(_ url: URL) throws -> SCNNode {
        let node: SCNNode
        if url.pathExtension.lowercased() == "stl" { node = SCNNode(geometry: try Self.binarySTL(url)) }
        else {
            let asset = MDLAsset(url: url)
            guard asset.count > 0 else { throw ROBGeometryError.invalid("Could not read scan. Export a mesh as OBJ or USDZ, or a conventional point-cloud PLY.") }
            node = SCNNode(); for i in 0..<asset.count { node.addChildNode(SCNNode(mdlObject: asset.object(at: i))) }
        }
        return node
    }
    private func fitLandmarks(toScan: Bool) {
        guard toScan || selectedJoint.kind == "fixed" else { statusLabel.stringValue = "Mount fitting requires a fixed joint. Preview joint angles are separate."; return }
        guard let url = openPanel("Landmarks: localMeters → parentMeters, with holdouts", extensions: ["json"]) else { return }
        perform {
            let data = try Data(contentsOf: url); guard data.count < 2_000_000 else { throw ROBGeometryError.invalid("Landmark file too large.") }
            let landmarks = try JSONDecoder().decode([ROBGeometryLandmark].self, from: data)
            let fit = try ROBGeometryMath.fit(landmarks)
            if profile.landmarkFits == nil { profile.landmarkFits = [:] }
            profile.landmarkFits?[toScan ? "scanToBase" : selectedJoint.name] = .init(sourceFile: url.lastPathComponent, landmarks: landmarks, fitRMSEMeters: fit.fitRMSEMeters, validationRMSEMeters: fit.validationRMSEMeters, previewPositionsAtFit: profile.previewPositions, scanScaleAtFit: profile.scanScale)
            if toScan { profile.scanToBase = fit.origin }
            else { profile.joints[selectedIndex].origin = fit.origin; profile.joints[selectedIndex].evidence = .init(source: "landmark_fit", note: "Landmark fit from \(url.lastPathComponent); residual is a fit statistic, not absolute measurement accuracy.", uncertaintyMeters: nil) }
            refreshFields()
            let holdout = fit.validationRMSEMeters.map { String(format: "%.2f mm", $0 * 1000) } ?? "NONE — independently validate"
            render(String(format: "Fit RMS %.2f mm; held-out RMS %@. Check scale and measurement uncertainty.", fit.fitRMSEMeters * 1000, holdout))
        }
    }
    @objc private func fitMount() { fitLandmarks(toScan: false) }
    @objc private func fitScan() { fitLandmarks(toScan: true) }
    @objc private func inspectPoint(_ sender: NSClickGestureRecognizer) {
        guard let hit = sceneView.hitTest(sender.location(in: sceneView), options: nil).first else { return }
        let p = robotRoot.convertPosition(hit.worldCoordinates, from: nil)
        var details = [String(format: "base_link: X %.2f mm, Y %.2f mm, Z %.2f mm", p.x * 1000, p.y * 1000, p.z * 1000)]
        var ancestor: SCNNode? = hit.node
        while let node = ancestor {
            if node === scanRoot {
                let raw = scanRoot.convertPosition(hit.worldCoordinates, from: nil)
                details.append(String(format: "scan localMeters after scale: %.6f, %.6f, %.6f", raw.x * profile.scanScale, raw.y * profile.scanScale, raw.z * profile.scanScale))
                break
            }
            if node.parent === modelRoot, let name = node.name {
                let local = node.convertPosition(hit.worldCoordinates, from: nil)
                details.append(String(format: "\(name) localMeters: %.6f, %.6f, %.6f", local.x, local.y, local.z))
                break
            }
            ancestor = node.parent
        }
        if let parent = profile.transforms()[selectedJoint.parent] {
            let local = ROBGeometryMath.point(parent.inverse, [Double(p.x), Double(p.y), Double(p.z)])
            details.append(String(format: "\(selectedJoint.parent) parentMeters: %.6f, %.6f, %.6f", local.x, local.y, local.z))
        }
        details.append("Displayed precision is not measurement accuracy.")
        statusLabel.stringValue = details.joined(separator: "\n")
    }

    #if !ROB_GEOMETRY_STANDALONE
    private func offerCloud(_ frame: ROBDepthCloudFrame) {
        guard window?.isVisible == true, cloudToggle.state == .on else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - frame.receivedUptime < 1 else { return }
        guard now - lastCloudUptime >= 0.25 else { return }
        guard let intrinsics = frame.calibratedIntrinsics, intrinsics.isValid(forWidth: frame.width, height: frame.height) else {
            cloudLabel.stringValue = "Depth registration unavailable: calibrated intrinsics missing. No guessed field of view is used."; cloudRoot.childNodes.forEach { $0.removeFromParentNode() }; return
        }
        guard frame.width > 0, frame.height > 0, frame.width <= 8192, frame.height <= 8192, frame.millimetersLittleEndian.length == frame.width * frame.height * 2 else { return }
        let name = frame.isBelly ? "belly_oak_optical_frame" : "oak_optical_frame"
        guard let transform = profile.transforms()[name] else { return }
        var points: [SCNVector3] = []
        let bytes = frame.millimetersLittleEndian.bytes.assumingMemoryBound(to: UInt8.self)
        let step = max(4, Int(sqrt(Double(frame.width * frame.height) / 16000)))
        for y in stride(from: 0, to: frame.height, by: step) { for x in stride(from: 0, to: frame.width, by: step) {
            let offset = 2 * (y * frame.width + x), mm = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            guard mm >= 150, mm <= 6000 else { continue }
            let z = Double(mm) / 1000
            if let p = ROBGeometryMath.deproject(x: Double(x), y: Double(y), depthMeters: z, fx: intrinsics.fx, fy: intrinsics.fy, cx: intrinsics.cx, cy: intrinsics.cy) { points.append(SCNVector3(p.x, p.y, p.z)) }
        } }
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: points.count, bytesPerIndex: 0)
        element.pointSize = 2; element.minimumPointScreenSpaceRadius = 1; element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [element]); geometry.materials = [material(.systemCyan)]
        geometry.firstMaterial?.lightingModel = .constant
        cloudRoot.childNodes.forEach { $0.removeFromParentNode() }
        let node = SCNNode(geometry: geometry); node.simdTransform = floats(transform); cloudRoot.addChildNode(node)
        lastCloudUptime = now; lastCloudSource = name
        cloudLabel.stringValue = "\(points.count) calibrated depth pixels • \(name) • PREVIEW camera transform, not measured live robot pose"
    }
    #endif

    func sceneSnapshot(to url: URL) throws {
        let image = sceneView.snapshot()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw ROBGeometryError.invalid("Could not render preview.") }
        try png.write(to: url)
    }
}
