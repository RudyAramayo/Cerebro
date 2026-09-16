import AppKit
import SwiftUI

@MainActor @objcMembers final class ROBBubbleWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ROBBubbleWindowController()
    private let model = ROBBubbleConsoleModel()
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ROB • Bubble targeting computer"
        window.minSize = NSSize(width: 900, height: 640)
        super.init(window: window)
        window.delegate = self
        let runtime = ROBBubbleRuntime.shared
        model.allowsAuthorization = false
        model.send = { runtime.localCommand($0) }
        model.visibilityChanged = { runtime.setLocalPreview($0) }
        window.contentView = NSHostingView(rootView: HSplitView {
            ROBBubbleConsole(model: model).frame(minWidth: 550)
            ROBBubbleCalibrationEditor().frame(minWidth: 300, idealWidth: 360)
        })
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("ROBBubbleStatusChanged"), object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.model.consume(ROBBubbleRuntime.shared.snapshot(includeFrame: true)) }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.setVisible(true)
        window?.makeKeyAndOrderFront(sender)
    }
    func windowWillClose(_ notification: Notification) { model.setVisible(false) }
}

private struct ROBBubbleCalibrationEditor: View {
    @State private var json = ROBBubbleRuntime.shared.calibrationJSON()
    @State private var message = "Relays verified: 8000 ON / 4000 OFF. Local controls operate directly; camera aiming still needs geometry calibration."
    @State private var live = false
    @State private var liveMount = false
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            Text("Mount calibration").font(.title3.bold())
            Text("Tilt → shoulder pan · ch 6\nPan → shoulder tilt · ch 7\nFan / Red → elbow tilt · ch 8\nBubbles / Blue → wrist pan · ch 9")
                .font(.callout.monospaced())
            Text("Camera → bubble nozzle offset").font(.headline)
            offsetField("Right", key: \.mountX)
            offsetField("Below", key: \.mountY)
            offsetField("Forward", key: \.mountZ)
            Button("Load 3D model estimate for simulation") {
                do {
                    guard let url = Bundle.main.url(forResource: "rob-visual", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let estimate = try ROBBubbleModelEstimate(data: Data(contentsOf: url))
                    var value = try JSONDecoder().decode(ROBBubbleCalibration.self, from: Data(json.utf8))
                    value.mountX = estimate.right; value.mountY = estimate.below; value.mountZ = estimate.forward
                    value.yawDegrees = 0; value.pitchDegrees = 0; value.rollDegrees = 0
                    value.geometryConfirmed = false; value.neckReference = []
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    json = String(decoding: try encoder.encode(value), as: UTF8.self)
                    message = "Model estimate loaded for review; save to simulate it. Uses the right shoulder and face-lens midpoint, not the added nozzle. Check against the Scaniverse measurement."
                } catch { message = error.localizedDescription }
            }
            Text("The model’s neck linkage and pulse-to-angle values are unmeasured. A moving head changes this transform; live camera aiming currently requires the measured reference pose.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Measure from the face camera lens to the nozzle pivot at the saved neck pose. Use negative values for left, above, or behind. The selected RGB pixel and its depth define the target; this offset corrects the nozzle’s pointing angle.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $json).font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Save calibration") {
                    do {
                        try ROBBubbleRuntime.shared.saveCalibration(Data(json.utf8))
                        live = false; liveMount = false
                        message = "Saved. Cerebro controls work directly. Remote controllers must enable Tilt/Pan or authorize bubbles."
                    } catch { message = error.localizedDescription }
                }
                Button("Capture neck pose") {
                    guard var value = try? JSONDecoder().decode(ROBBubbleCalibration.self, from: Data(json.utf8)) else {
                        message = "Fix the calibration JSON before capturing the neck pose."; return
                    }
                    ROBBubbleRuntime.shared.captureNeckReference()
                    value.neckReference = ROBBubbleRuntime.shared.calibration.neckReference
                    value.geometryConfirmed = false
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(value) { json = String(decoding: data, as: UTF8.self) }
                    message = value.neckReference.count == 3
                        ? "Neck command reference captured. Measurements preserved; verify geometry and save."
                        : "Neck position is unknown. Connect Maestro and establish its pose before capturing."
                }
            }
            Toggle("Enable live Tilt/Pan movement", isOn: $liveMount)
                .onChange(of: liveMount) { _, enabled in
                    guard enabled != ROBBubbleRuntime.shared.liveMountOutputs else { return }
                    ROBBubbleRuntime.shared.setLiveMountOutputs(enabled)
                    liveMount = ROBBubbleRuntime.shared.liveMountOutputs
                }
            Toggle("Enable verified live fan / blower", isOn: $live)
                .onChange(of: live) { _, enabled in
                    guard enabled != ROBBubbleRuntime.shared.liveOutputs else { return }
                    ROBBubbleRuntime.shared.setLiveOutputs(enabled)
                    live = ROBBubbleRuntime.shared.liveOutputs
                }
            Text("Local buttons and sliders enable their outputs directly. Remote controllers authorize their own session. After Maestro connection, motors cool for 60 seconds; Tilt/Pan remains available.")
                .font(.caption).foregroundStyle(.secondary)
            Text(message).font(.caption).foregroundStyle(.secondary)
          }.padding(16)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ROBBubbleStatusChanged"))) { _ in
            liveMount = ROBBubbleRuntime.shared.liveMountOutputs
            live = ROBBubbleRuntime.shared.liveOutputs
        }
    }

    private func offsetField(_ label: String, key: WritableKeyPath<ROBBubbleCalibration, Double>) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            TextField(label, value: Binding(
                get: {
                    let value = (try? JSONDecoder().decode(ROBBubbleCalibration.self, from: Data(json.utf8)))
                        ?? ROBBubbleRuntime.shared.calibration
                    return value[keyPath: key] * 100
                },
                set: { centimeters in
                    guard var value = try? JSONDecoder().decode(ROBBubbleCalibration.self, from: Data(json.utf8)) else {
                        message = "Fix the calibration JSON before editing the offset."; return
                    }
                    value[keyPath: key] = centimeters / 100
                    // A changed measurement requires renewed geometry confirmation.
                    value.geometryConfirmed = false
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { json = text }
                }
            ), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 90)
            Text("cm").foregroundStyle(.secondary)
        }
    }
}
