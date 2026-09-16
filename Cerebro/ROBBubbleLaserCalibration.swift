import AppKit
import SwiftUI

@MainActor final class ROBBubbleLaserCalibrationModel: ObservableObject {
    @Published var grid = ROBBubbleLaserGrid()
    @Published var passName = "Head forward"
    @Published var markedCorners: [[Double]] = []
    @Published var preview: NSImage?
    @Published var imageSize = CGSize(width: 1280, height: 720)
    @Published var result: ROBBubbleLaserResult?
    @Published var busy = false
    @Published var settled = false
    @Published var targetStep = 0
    @Published var sampleCount = 0
    @Published var message = "Place the mat upright in view, with ROB’s head forward. Keep the mat fixed throughout all head poses."
    @Published private(set) var reference: ROBBubbleRuntime.LaserFrame?
    @Published private(set) var analyzedFrame: ROBBubbleRuntime.LaserFrame?
    let sessionID = UUID()
    private var passID = UUID()
    private var passNumber = 1
    private var generation = UUID()
    private var savedFrameIDs: Set<UUID> = []
    private var output: (json: Data, overlay: Data, mask: Data)?
    private let queue = DispatchQueue(label: "com.orbitusrobotics.bubbles.laser", qos: .userInitiated)
    private var timer: Timer?
    private var active = false
    private let archiveRoot: URL?
    init(archiveRoot: URL? = nil) { self.archiveRoot = archiveRoot }
    var sessionURL: URL {
        let root = archiveRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cerebro/BubbleCalibration", isDirectory: true)
        return root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }
    var target: Int { grid.targets[min(targetStep, grid.targets.count - 1)] }
    var targetLabel: String { "Row \(target / grid.columns + 1), column \(target % grid.columns + 1)" }
    var recordProblem: String? {
        guard let result, let frame = analyzedFrame else { return "Capture and detect the laser first." }
        guard !savedFrameIDs.contains(frame.id) else { return "This image was already saved. Detect a new image for the next point." }
        return result.recordingProblem(grid: grid, target: target, settled: settled)
    }

    func setActive(_ value: Bool) {
        active = value
        ROBBubbleRuntime.shared.setLaserCaptureActive(value)
        timer?.invalidate(); timer = nil
        if value {
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.reference == nil, !self.busy,
                          let frame = ROBBubbleRuntime.shared.laserCalibrationFrame() else { return }
                    self.show(frame)
                }
            }
        } else {
            generation = UUID(); busy = false
        }
    }
    private func show(_ frame: ROBBubbleRuntime.LaserFrame) {
        preview = NSImage(data: frame.png)
        imageSize = CGSize(width: frame.width, height: frame.height)
    }
    func captureReference() {
        result = nil; analyzedFrame = nil; output = nil; settled = false
        guard let frame = ROBBubbleRuntime.shared.laserCalibrationFrame() else {
            message = "Waiting for fresh face-camera RGB and known neck / mount commands. Connect Maestro, establish the neck pose, and apply a manual Tilt/Pan target, then let it settle."; return
        }
        generation = UUID(); busy = false
        passID = UUID(); targetStep = 0
        reference = frame; markedCorners = []; result = nil; analyzedFrame = nil
        output = nil; settled = false; show(frame)
        message = "Reference captured. Click top-left, top-right, bottom-right, then bottom-left grid intersections around a rectangular patch."
    }
    func mark(_ point: CGPoint) {
        guard reference != nil, markedCorners.count < 4, !busy else { return }
        markedCorners.append([Double(point.x), Double(point.y)])
        result = nil; analyzedFrame = nil; output = nil; settled = false
        if markedCorners.count == 4 {
            message = "Check the intersection counts. Uncover the laser, align it using Tilt/Pan, let the servos settle, then Detect laser."
        }
    }
    func editGrid() {
        generation = UUID(); result = nil; analyzedFrame = nil; output = nil; settled = false; targetStep = 0
        if let reference { show(reference) }
    }
    func clearMarks() {
        markedCorners = []; editGrid()
    }
    func newPose() {
        generation = UUID(); passID = UUID(); passNumber += 1; passName = "Head pose \(passNumber)"
        reference = nil; markedCorners = []; result = nil; analyzedFrame = nil
        output = nil; settled = false; targetStep = 0; preview = nil
        message = "Keep the mat fixed. Move the neck slightly with the normal controls, let it settle, cover the laser, then capture a new reference. Mark the same four physical intersections."
    }
    func detect() {
        guard !busy, grid.valid, markedCorners.count == 4, let reference else { return }
        settled = false; result = nil; analyzedFrame = nil; output = nil
        guard let frame = ROBBubbleRuntime.shared.laserCalibrationFrame() else {
            message = "No fresh image with matching servo commands. Wait for the camera and servos to settle, then retry."; return
        }
        guard frame.neck == reference.neck, frame.width == reference.width, frame.height == reference.height else {
            message = "The head pose or camera size changed. Start a new head pose and capture a new laser-off reference."; return
        }
        guard let script = Bundle.main.url(forResource: "BubbleLaserCalibration", withExtension: "py") else {
            message = "The OpenCV calibration script is missing from this Cerebro build."; return
        }
        busy = true
        let token = UUID(); generation = token
        let settings = grid, corners = markedCorners
        message = "Finding red laser evidence in the captured frame…"
        queue.async { [weak self] in
            let outcome = Result { try Self.runDetector(script: script, frame: frame, reference: reference,
                                                       grid: settings, corners: corners) }
            DispatchQueue.main.async {
                guard let self, self.active, self.generation == token else { return }
                self.busy = false
                switch outcome {
                case .success(let output):
                    self.output = output
                    do {
                        let result = try JSONDecoder().decode(ROBBubbleLaserResult.self, from: output.json)
                        self.result = result; self.analyzedFrame = frame
                        self.preview = NSImage(data: output.overlay); self.imageSize = CGSize(width: frame.width, height: frame.height)
                        self.message = result.laser.detail
                    } catch { self.message = "Could not read detector output: \(error.localizedDescription)" }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func runDetector(script: URL, frame: ROBBubbleRuntime.LaserFrame,
        reference: ROBBubbleRuntime.LaserFrame, grid: ROBBubbleLaserGrid, corners: [[Double]]) throws
        -> (json: Data, overlay: Data, mask: Data) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("rob-laser-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        try frame.png.write(to: file("image.png"))
        try reference.png.write(to: file("off.png"))
        let quad = String(decoding: try JSONEncoder().encode(corners), as: UTF8.self)
        let args = [script.path, "--image", file("image.png").path, "--background", file("off.png").path,
                    "--cols", String(grid.columns), "--rows", String(grid.rows), "--spacing-mm", String(grid.spacingMM),
                    "--quad", quad, "--output", file("result.json").path,
                    "--annotated", file("overlay.png").path, "--mask", file("mask.png").path]
        let process = try ROBPythonRuntime.shared.newTask(withArguments: args)
        fm.createFile(atPath: file("python.log").path, contents: nil)
        let log = try FileHandle(forWritingTo: file("python.log"))
        defer { try? log.close() }
        process.standardOutput = log; process.standardError = log
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw failure("OpenCV timed out. Check Cerebro’s Python environment and try again.")
        }
        let json = try? Data(contentsOf: file("result.json"))
        guard process.terminationStatus == 0, let json else {
            let detail = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String
            let logText = (try? String(contentsOf: file("python.log"), encoding: .utf8)) ?? ""
            throw failure(detail ?? "OpenCV could not run. Check the selected Python interpreter and opencv-python dependency. \(logText.suffix(800))")
        }
        return (json, try Data(contentsOf: file("overlay.png")), try Data(contentsOf: file("mask.png")))
    }
    nonisolated private static func failure(_ message: String) -> Error {
        NSError(domain: "ROB laser calibration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func record() {
        guard !busy, recordProblem == nil, let frame = analyzedFrame, let reference,
              let result, let point = result.laser.point, let output,
              let error = result.targetErrorMM(grid: grid, target: target) else { return }
        var depths: [Double] = []
        if let depth = frame.depth {
            for y in Int(point.y.rounded())-2...Int(point.y.rounded())+2 {
                for x in Int(point.x.rounded())-2...Int(point.x.rounded())+2 {
                    if let mm = depth.distanceMillimeters(x: x, y: y) { depths.append(Double(mm)) }
                }
            }
        }
        depths.sort()
        let observation = ROBBubbleLaserObservation(sessionID: sessionID, passID: passID, passName: passName,
            frameID: frame.id, referenceFrameID: reference.id, capturedAt: frame.capturedDate,
            referenceCapturedAt: reference.capturedDate, recordedAt: Date(), grid: grid,
            markedCornersPixels: markedCorners, targetColumn: target % grid.columns + 1,
            targetRow: target / grid.columns + 1, targetErrorMM: error, laser: point,
            pan: frame.pan, tilt: frame.tilt, panChannel: frame.panChannel, tiltChannel: frame.tiltChannel,
            neck: frame.neck, rgbWidth: frame.width, rgbHeight: frame.height,
            intrinsicsFXFYCXCY: frame.intrinsics, laserDepthMM: depths.isEmpty ? nil : depths[depths.count / 2],
            operatorConfirmedSettled: settled)
        do {
            _ = try ROBBubbleLaserArchive.save(observation, in: sessionURL, image: frame.png,
                reference: reference.png, analysis: output.json, overlay: output.overlay, mask: output.mask)
            savedFrameIDs.insert(frame.id); sampleCount += 1; settled = false
            if targetStep + 1 < grid.targets.count {
                targetStep += 1
                message = "Sample saved. Align to \(targetLabel), then detect a fresh image."
            } else {
                message = "This pass is complete. Repeat a few points to check consistency, or start a new head pose while keeping the mat fixed."
            }
        } catch { message = "Could not save sample: \(error.localizedDescription)" }
    }
    func showFolder() {
        do {
            try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(sessionURL)
        } catch { message = error.localizedDescription }
    }
}

@MainActor final class ROBBubbleLaserCalibrationWindow: NSWindowController, NSWindowDelegate {
    static let shared = ROBBubbleLaserCalibrationWindow()
    private let model = ROBBubbleLaserCalibrationModel()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 790),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ROB • Grid & laser calibration"
        window.minSize = NSSize(width: 980, height: 700)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ROBBubbleLaserCalibrationView(model: model))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); model.setActive(true); window?.makeKeyAndOrderFront(sender)
    }
    func windowWillClose(_ notification: Notification) { model.setActive(false) }
}

struct ROBBubbleLaserCalibrationView: View {
    @ObservedObject var model: ROBBubbleLaserCalibrationModel
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Calibrate with your cutting mat").font(.title2.bold())
                Text("Mark a rectangular patch of 1-inch squares. Keep the mat and ROB’s base fixed; use the same four physical intersections for each head pose.")
                    .foregroundStyle(.secondary)
                canvas.frame(minHeight: 350)
                HStack {
                    Label(model.reference == nil ? "Face-camera preview" : "Frozen capture · top-left image origin", systemImage: "camera")
                    Spacer()
                    if let frame = model.analyzedFrame ?? model.reference {
                        Text("Pan \(String(frame.pan))  Tilt \(String(frame.tilt))").monospacedDigit()
                    }
                }.font(.caption)
                if let frame = model.analyzedFrame ?? model.reference {
                    Text("Neck commands: \(frame.neck.map(String.init).joined(separator: " / ")) · values are commanded pulses, not encoders")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.message).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("1  Define the grid").font(.headline)
                    Stepper("Columns: \(model.grid.columns)", value: $model.grid.columns, in: 2...30)
                    Stepper("Rows: \(model.grid.rows)", value: $model.grid.rows, in: 2...30)
                    HStack {
                        Text("Spacing (mm)")
                        TextField("Spacing", value: $model.grid.spacingMM, format: .number).frame(width: 70)
                    }
                    Text("Count intersections, including both edges. 9 × 6 intersections span 8 × 5 squares. One inch = 25.4 mm.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Capture laser-off reference") { model.captureReference() }
                    Text("Cover or switch off the laser first. Then click TL → TR → BR → BL on the image. \(model.markedCorners.count)/4 marked.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear corner marks") { model.clearMarks() }.disabled(model.reference == nil)
                    Divider()
                    Text("2  Align and capture").font(.headline)
                    TextField("Head pose name", text: $model.passName)
                    Picker("Target", selection: $model.targetStep) {
                        ForEach(Array(model.grid.targets.enumerated()), id: \.offset) { step, index in
                            Text("Row \(index / model.grid.columns + 1), column \(index % model.grid.columns + 1)").tag(step)
                        }
                    }
                    Text("Uncover the laser. Use your normal Tilt/Pan controls to align the dot, then wait for the servos to settle.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.busy ? "Detecting…" : "Detect laser") { model.detect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.reference == nil || model.markedCorners.count != 4 || !model.grid.valid)
                    if let error = model.result?.targetErrorMM(grid: model.grid, target: model.target) {
                        Text(String(format: "Distance to target: %.1f mm", error)).monospacedDigit()
                    }
                    Toggle("Dot checked; servos were settled", isOn: $model.settled)
                        .disabled(model.analyzedFrame == nil)
                    Button("Save point & next target") { model.record() }.disabled(model.recordProblem != nil)
                    if let problem = model.recordProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("3  Repeat with the head turned").font(.headline)
                    Button("New head pose") { model.newPose() }
                    Text("Move the neck slightly, capture a new laser-off reference, and mark the same patch. Each saved point includes its neck commands.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(model.sampleCount) points saved").font(.headline)
                    Button("Show saved observations") { model.showFolder() }
                    Text("These observations prepare a measured aiming calibration. Saving points does not enable automatic aiming.")
                        .font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).disabled(model.busy)
            }.frame(width: 310)
        }.padding(20)
        .onChange(of: model.grid) { _, _ in model.editGrid() }
        .onChange(of: model.targetStep) { _, _ in model.settled = false }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / model.imageSize.width, geometry.size.height / model.imageSize.height)
            let size = CGSize(width: model.imageSize.width * scale, height: model.imageSize.height * scale)
            let origin = CGPoint(x: (geometry.size.width - size.width) / 2, y: (geometry.size.height - size.height) / 2)
            ZStack {
                Color.black
                if let preview = model.preview {
                    Image(nsImage: preview).resizable().frame(width: size.width, height: size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    Canvas { context, _ in
                        func location(_ point: [Double]) -> CGPoint {
                            CGPoint(x: origin.x + point[0] * scale, y: origin.y + point[1] * scale)
                        }
                        for (index, corner) in model.markedCorners.enumerated() {
                            let p = location(corner)
                            context.stroke(Path(ellipseIn: CGRect(x: p.x-7, y: p.y-7, width: 14, height: 14)), with: .color(.cyan), lineWidth: 2)
                            context.draw(Text(["TL", "TR", "BR", "BL"][index]).font(.caption.bold()).foregroundColor(.cyan),
                                         at: CGPoint(x: p.x, y: p.y-18))
                        }
                        if let points = model.result?.board.corners, points.indices.contains(model.target), points[model.target].count == 2 {
                            let p = location(points[model.target])
                            context.stroke(Path(ellipseIn: CGRect(x: p.x-16, y: p.y-16, width: 32, height: 32)), with: .color(.yellow), lineWidth: 3)
                            context.draw(Text("TARGET").font(.caption.bold()).foregroundColor(.yellow), at: CGPoint(x: p.x, y: p.y+28))
                        }
                    }
                } else {
                    Text("Waiting for face-camera RGB and established servo commands…")
                        .foregroundStyle(.white).padding(30)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let x = (value.location.x - origin.x) / scale, y = (value.location.y - origin.y) / scale
                if x >= 0, y >= 0, x < model.imageSize.width, y < model.imageSize.height {
                    model.mark(CGPoint(x: x, y: y))
                }
            })
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
