import AppKit
import CryptoKit
import simd

/// Independent of the motor gateway. Loading a calibrated URDF here never
/// installs it on Amber, changes a driver sign, or acquires motion authority.
final class ROBArmIKWindowController: NSWindowController {
    static let shared = ROBArmIKWindowController()
    private let sourceLabel = NSTextField(wrappingLabelWithString: "Load the exact URDF to inspect. No model has been selected.")
    private let baseField = NSTextField(string: "base_link")
    private let tipField = NSTextField(string: "seven_Link")
    private let seedField = NSTextField(string: "0,0,0,0,0,0,0")
    private let targetField = NSTextField(string: "0.3,0,0.3,0,0,0")
    private let toolField = NSTextField(string: "0,0,0,0,0,0")
    private let changeField = NSTextField(string: "0.35")
    private let positionOnly = NSButton(checkboxWithTitle: "Position only (ignore wrist orientation)", target: nil, action: nil)
    private let output = NSTextView()
    private var sourceData: Data?
    private var sourceHash = ""
    private var generation = UUID()
    private var busy = false
    private let worker = DispatchQueue(label: "com.orbitusrobotics.ik-preview", qos: .userInitiated)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "URDF Pose IK — Calculation Only"
        window.minSize = NSSize(width: 700, height: 620)
        super.init(window: window)
        buildInterface()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Use shared") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                                     stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
                                     stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
                                     stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)])
        let description = NSTextField(wrappingLabelWithString: "Load a single-arm or complete robot URDF and select its exact base → tool chain. Targets and seeds are model coordinates: meters and radians. Driver signs, boot offsets, collision checking and hardware execution are separate.")
        stack.addArrangedSubview(description)
        stack.addArrangedSubview(NSButton(title: "Load URDF…", target: self, action: #selector(loadURDF)))
        stack.addArrangedSubview(sourceLabel)
        for (label, field) in [("Base link", baseField), ("Tip link", tipField),
                               ("Seed q, in chain order", seedField), ("Target in base: x,y,z,roll,pitch,yaw", targetField),
                               ("Tip → TCP: x,y,z,roll,pitch,yaw", toolField), ("Maximum change from seed (rad / m)", changeField)] {
            let caption = NSTextField(labelWithString: label); caption.widthAnchor.constraint(equalToConstant: 280).isActive = true
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let row = NSStackView(views: [caption, field]); row.orientation = .horizontal
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "A zero TCP offset targets the selected tip frame, not necessarily the fingertips. Inspect FK first to see joint order. Unmeasured drafts can validate software, but cannot establish physical accuracy."))
        stack.addArrangedSubview(positionOnly)
        let buttons = NSStackView(views: [NSButton(title: "Inspect FK / Use as Target", target: self, action: #selector(inspectFK)),
                                         NSButton(title: "Solve IK", target: self, action: #selector(solveIK)),
                                         NSButton(title: "Copy Result JSON", target: self, action: #selector(copyResult))])
        stack.addArrangedSubview(buttons)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = output
        output.isEditable = false; output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.isVerticallyResizable = true; output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        description.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sourceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func loadURDF() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 5_000_000 else { throw ROBKinematicsError.invalid("Choose a URDF under 5 MB.") }
            let data = try Data(contentsOf: url)
            sourceData = data; sourceHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            generation = UUID(); busy = false
            sourceLabel.stringValue = "\(url.lastPathComponent) • SHA-256 \(sourceHash)"
            output.string = "Selected \(url.path). Set base/tip to the exact URDF names. File contents are snapshotted; reload after editing."
        } catch { output.string = error.localizedDescription }
    }
    private func chain() throws -> ROBSerialChain {
        guard let data = sourceData else { throw ROBKinematicsError.invalid("Load a URDF first.") }
        return try ROBSerialChain(urdf: data, base: baseField.stringValue.trimmingCharacters(in: .whitespaces),
                                 tip: tipField.stringValue.trimmingCharacters(in: .whitespaces))
    }
    private func values(_ field: NSTextField, count: Int) throws -> [Double] {
        let tokens = field.stringValue.split(separator: ",", omittingEmptySubsequences: false)
        let values = tokens.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard tokens.count == count, values.count == count, values.allSatisfy(\.isFinite) else {
            throw ROBKinematicsError.invalid("Enter exactly \(count) finite comma-separated numbers.")
        }
        return values
    }
    private func pose(_ field: NSTextField) throws -> simd_double4x4 {
        let v = try values(field, count: 6)
        return ROBSerialChain.pose(xyz: SIMD3(v[0], v[1], v[2]), rpy: SIMD3(v[3], v[4], v[5]))
    }
    private func report(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            output.string = String(decoding: data, as: UTF8.self)
        }
    }
    @objc private func inspectFK() {
        guard !busy else { return }
        do {
            let chain = try chain()
            let names = chain.movingJoints.map(\.name)
            guard seedField.stringValue.split(separator: ",", omittingEmptySubsequences: false).count == names.count else {
                throw ROBKinematicsError.invalid("Seed order (\(names.count) values): \(names.joined(separator: ", "))")
            }
            let q = try values(seedField, count: names.count)
            let value = try chain.forward(q, tipFromTool: pose(toolField))
            let origin = ROBGeometryOrigin.from(value)
            targetField.stringValue = (origin.xyzMeters + origin.rpyRadians).map { String(format: "%.9f", $0) }.joined(separator: ",")
            report(["mode": "kinematics_only", "source_sha256": sourceHash, "base": chain.base, "tip": chain.tip,
                    "joint_order": names, "seed": q, "target_xyz_rpy": origin.xyzMeters + origin.rpyRadians,
                    "collision_checked": false, "hardware_command_sent": false])
        } catch { output.string = error.localizedDescription }
    }
    @objc private func solveIK() {
        guard !busy else { return }
        do {
            let chain = try chain(), seed = try values(seedField, count: chain.movingJoints.count)
            let target = try pose(targetField), tool = try pose(toolField), hash = sourceHash
            var options = ROBSerialChain.Options()
            options.positionOnly = positionOnly.state == .on
            options.maximumDisplacementFromSeed = try values(changeField, count: 1)[0]
            options.maximumSeconds = 1
            let settings = options, token = UUID(); generation = token; busy = true
            output.string = "Solving the selected URDF chain…"
            worker.async { [weak self] in
                let result = Result { try chain.solve(targetInBase: target, seed: seed, tipFromTool: tool, options: settings) }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.busy = false
                    switch result {
                    case .failure(let error): self.output.string = error.localizedDescription
                    case .success(let solved):
                        self.report(["mode": "kinematics_only", "source_sha256": hash, "base": chain.base, "tip": chain.tip,
                                     "joint_order": chain.movingJoints.map(\.name), "positions": solved.positions,
                                     "converged": solved.converged, "reason": solved.reason, "iterations": solved.iterations,
                                     "position_error_m": solved.positionErrorMeters, "orientation_error_rad": solved.orientationErrorRadians,
                                     "position_only": settings.positionOnly, "collision_checked": false, "hardware_command_sent": false])
                    }
                }
            }
        } catch { output.string = error.localizedDescription }
    }
    @objc private func copyResult() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output.string, forType: .string)
    }
}
