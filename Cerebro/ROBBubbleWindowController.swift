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
    @State private var message = "Relay ON values and shoulder geometry are not measured yet. Outputs start in dry run."
    @State private var live = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mount calibration").font(.title3.bold())
            Text("Tilt → shoulder pan · ch 6\nPan → shoulder tilt · ch 7\nFan / Red → elbow tilt · ch 8\nBubbles / Blue → wrist pan · ch 9")
                .font(.callout.monospaced())
            Text("Measure the camera-to-mount offset and rotation at a fixed neck pose. Optical axes: right, down, forward; meters and degrees. Confirm wiring only after testing the relay ON/OFF values.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $json).font(.system(.caption, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Save calibration") {
                    do {
                        try ROBBubbleRuntime.shared.saveCalibration(Data(json.utf8))
                        live = false; message = "Saved. Dry run; authorize again after enabling outputs."
                    } catch { message = error.localizedDescription }
                }
                Button("Capture neck pose") {
                    ROBBubbleRuntime.shared.captureNeckReference()
                    json = ROBBubbleRuntime.shared.calibrationJSON()
                    message = "Neck command reference captured. Enter measurements and save."
                }
            }
            Toggle("Enable verified live outputs", isOn: $live)
                .onChange(of: live) { _, enabled in
                    ROBBubbleRuntime.shared.setLiveOutputs(enabled)
                    live = ROBBubbleRuntime.shared.liveOutputs
                }
            Text(message).font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}
