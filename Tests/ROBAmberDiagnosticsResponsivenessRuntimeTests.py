#!/usr/bin/env python3
"""Run production plot/CSV helpers without a gateway or robot connection."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''
extension ROBAmberTelemetryPlotView {
    fileprivate var fixtureReady: Bool { !preparingGeometry && pendingSamples == nil && geometry != nil }
    fileprivate var fixtureRange: ClosedRange<Double>? { geometry?.range }
    fileprivate var fixtureHasSamples: Bool { geometry?.hasSamples == true }
}

@main
struct DiagnosticsResponsivenessFixture {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        let samples = (0..<2400).map { index -> ROBAmberDiagnosticsSample in
            var positions = [Double](repeating: 0, count: 7)
            positions[0] = index == 11 ? 100 : index == 13 ? -90 : 0
            positions[6] = Double(index) / 1000
            return ROBAmberDiagnosticsSample(
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) / 20),
                receivedAtUptime: 100 + Double(index) / 20,
                sequence: UInt64(index + 1), sampleAgeMilliseconds: 5,
                controllerSampleAgeMilliseconds: 2,
                jointFeedbackAgeMilliseconds: [Double](repeating: 3, count: 7),
                gripperFeedbackAgeMilliseconds: 4, positionsRadians: positions,
                velocitiesRadiansPerSecond: [], currents: [Double](repeating: 0.25, count: 7),
                statuses: [Double](repeating: 2, count: 7), targetPositionsRadians: nil
            )
        }
        let geometry = ROBAmberPlotGeometry.make(samples: samples, metric: .position)
        expect(geometry.range.lowerBound < -90 && geometry.range.upperBound > 100,
               "Downsampling lost extrema from the range")
        var points: [CGPoint] = []
        geometry.paths[0].applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                points.append(element.pointee.points[0])
            }
        }
        expect(points.count <= 384, "Continuous plot exceeded its bounded drawing size")
        expect(points.first?.x == 0 && points.last?.x == 1, "Plot endpoints were discarded")
        expect(zip(points, points.dropFirst()).allSatisfy { $0.x <= $1.x },
               "Min/max selection reversed time order")
        let span = geometry.range.upperBound - geometry.range.lowerBound
        expect(points.contains { abs(Double($0.y) * span + geometry.range.lowerBound - 100) < 0.00001 },
               "Narrow positive spike was hidden")
        expect(points.contains { abs(Double($0.y) * span + geometry.range.lowerBound + 90) < 0.00001 },
               "Narrow negative spike was hidden")
        expect(geometry.paths.dropFirst(7).allSatisfy(\.isEmpty), "Missing targets became zero lines")
        let velocity = ROBAmberPlotGeometry.make(samples: samples, metric: .velocity)
        expect(velocity.paths.allSatisfy(\.isEmpty), "Unavailable velocity became a zero-speed line")
        let gap = ROBAmberPlotGeometry.path(points: [
            CGPoint(x: 0, y: 0), CGPoint(x: 0.001, y: 0.5), nil,
            CGPoint(x: 0.002, y: -0.5), CGPoint(x: 1, y: 0)
        ], range: -1...1)
        var moves = 0
        gap.applyWithBlock { if $0.pointee.type == .moveToPoint { moves += 1 } }
        expect(moves == 2, "A missing sample was bridged inside a time bucket")

        let plot = ROBAmberTelemetryPlotView(metric: .position)
        plot.samples = samples
        plot.samples = Array(samples.suffix(120))
        let plotDeadline = Date(timeIntervalSinceNow: 10)
        while !plot.fixtureReady && Date() < plotDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        expect(plot.fixtureReady && (plot.fixtureRange?.upperBound ?? .infinity) < 3,
               "An obsolete prepared plot replaced the newest request")
        plot.samples = []
        while !plot.fixtureReady && Date() < plotDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        expect(plot.fixtureReady && !plot.fixtureHasSamples, "Clearing history retained a stale plot")

        // Exercise the actual asynchronous exporter while the main run loop
        // continues processing a periodic operator/UI heartbeat.
        let history = ROBAmberDiagnosticsHistory()
        samples.forEach { history.append($0) }
        let snapshot: [ROBAmberDiagnosticsArm: [ROBAmberDiagnosticsSample]] = [
            .right: history.samples, .left: history.samples
        ]
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var ticks = 0
        var finished = false
        var exportError: Error?
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in ticks += 1 }
        RunLoop.main.add(timer, forMode: .default)
        let began = Date()
        ROBAmberDiagnosticsCSV.write(snapshot: snapshot, to: url) { result in
            expect(Thread.isMainThread, "Export completion must return to the UI queue")
            if case .failure(let error) = result { exportError = error }
            finished = true
        }
        history.clear()
        expect(history.samples.isEmpty, "Fixture failed to mutate the live history")
        let deadline = Date(timeIntervalSinceNow: 45)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        timer.invalidate()
        expect(finished, "Full-history export failed to complete")
        if let exportError { throw exportError }
        expect(ticks > 5, "CSV export blocked the main run loop")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        expect(lines.count == 33601, "Live history mutation corrupted the captured export")
        let header = lines[0].split(separator: ",").map(String.init)
        let row = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        expect(header.count == row.count && header.count == 17, "CSV schema changed")
        expect(row[1] == "2023-11-14T22:13:20.000Z", "Capture receipt time shifted during export")
        expect(row[6] == "" && row[7] == "" && row[8] == "", "Missing values became numeric claims")
        expect(lines.contains { $0.contains(",right,L10,26001,") }, "Physical right mapping was lost")
        expect(lines.contains { $0.contains(",left,R11,26002,") }, "Physical left mapping was lost")
        print("Diagnostics responsiveness fixtures passed; \(ticks) UI ticks during \(Date().timeIntervalSince(began)) s export")
    }
}
'''


def main():
    source = (ROOT / "Cerebro/ROBAmberDiagnosticsWindowController.swift").read_text()
    # Compile the actual helpers and NSView, with only unrelated enum stubs.
    prefix = source[:source.index("/// A pure 2D drawing reference")]
    safety_extension = source[source.index("private extension Collection {"):]
    bindings = (ROOT / "Cerebro/ROBAmberArmBinding.swift").read_text()
    stub = "enum ROBArmSide: String, CaseIterable { case left, right }\nenum ROBAmberGatewayState { case ready }\n"
    with tempfile.TemporaryDirectory(prefix="rob-amber-responsive-") as folder:
        folder = Path(folder)
        swift = folder / "Fixture.swift"
        binary = folder / "fixture"
        swift.write_text(stub + bindings + prefix + safety_extension + FIXTURE)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
            "-module-cache-path", str(folder / "module-cache"), str(swift), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary), str(folder / "telemetry.csv")], check=True, timeout=50)


if __name__ == "__main__":
    main()
