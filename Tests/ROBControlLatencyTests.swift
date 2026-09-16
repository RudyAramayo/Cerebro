import AppKit
import Foundation

@main
@MainActor
private struct ROBControlLatencyTests {
    static func main() throws {
        var timing = ROBControlTiming()
        timing.record(.nan)
        timing.record(-1)
        precondition(timing.samples == 0)
        timing.record(12)
        timing.record(2)
        precondition(timing.lastMilliseconds == 2 && timing.peakMilliseconds == 12)

        let diagnostics = ROBControlLatencyDiagnostics()
        precondition(diagnostics.snapshot().input == nil)
        diagnostics.start()
        diagnostics.start() // Starting twice must not create a second probe stream.
        // Hold the main thread while the independent queue posts one probe.
        let deadline = Date().addingTimeInterval(2)
        while diagnostics.snapshot().mainQueue.peakMilliseconds < 50 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let blocked = diagnostics.snapshot()
        precondition(blocked.mainQueue.peakMilliseconds >= 200, "Failed to detect a main-thread stall")
        precondition(blocked.mainQueue.samples == 0, "Probe ran while main thread was blocked")
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        let recovered = diagnostics.snapshot()
        precondition(recovered.mainQueue.peakMilliseconds >= 200, "Stall peak was lost on recovery")
        precondition((1...3).contains(recovered.mainQueue.samples), "Probes accumulated during the stall")

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            diagnostics.recordCommandHandler(milliseconds: 1)
            diagnostics.recordSerialWrite(milliseconds: 0.2, succeeded: true)
            _ = diagnostics.snapshot()
        }
        precondition(diagnostics.snapshot().commandHandler.samples == 500)
        diagnostics.recordCommandHandler(milliseconds: 25)
        diagnostics.recordCommandHandler(milliseconds: 0.8)
        diagnostics.resetPeaks()
        precondition(diagnostics.snapshot().commandHandler.peakMilliseconds == 0.8)
        diagnostics.recordSerialWrite(milliseconds: 0, succeeded: false)
        precondition(diagnostics.snapshot().serialWriteSucceeded == false)
        diagnostics.recordSerialWrite(milliseconds: 0.2, succeeded: true)

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let windowController = ROBControlLatencyWindowController(diagnostics: diagnostics) {
            "Connection round trip (includes app scheduling):\nTest controller: 8.4 ms"
        }
        windowController.showWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let window = windowController.window!
        precondition(window.isVisible && window.title == "Control Latency")
        precondition(labels(in: window.contentView!).contains { $0.stringValue.contains("Waiting for controller input") })

        diagnostics.recordController(
            "Test controller", sequence: "42", left: CGPoint(x: 0.2, y: 0.8),
            right: CGPoint(x: -1000, y: -1000), brake: false, speed: 35,
            sentAtMilliseconds: Date().timeIntervalSince1970 * 1_000 - 18
        )
        let preview = diagnostics.snapshot().input!
        precondition(preview.sequence == "42" && preview.speed == 35)
        precondition(abs((preview.senderClockAgeMilliseconds ?? 0) - 18) < 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let root = window.contentView!
        root.layoutSubtreeIfNeeded()
        let fields = labels(in: root)
        precondition(fields.contains { $0.stringValue.contains("sequence 42") })
        precondition(fields.contains { $0.stringValue.contains("OS accepted bytes") })
        for field in fields {
            let frame = field.convert(field.bounds, to: root)
            precondition(frame.minY >= 0 && frame.maxY <= root.bounds.height, "Clipped diagnostics label")
        }
        if let path = CommandLine.arguments.dropFirst().first,
           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        windowController.close()
        print("Control latency tests passed: bounded stall probes, concurrent timing, input preview and window layout")
    }

    private static func labels(in root: NSView) -> [NSTextField] {
        (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(labels)
    }
}
