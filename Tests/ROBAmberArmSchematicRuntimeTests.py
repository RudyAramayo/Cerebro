#!/usr/bin/env python3
"""Exercise and render the real diagnostics pose view, with no hardware IO."""

from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''
extension ROBAmberArmSchematicView {
    fileprivate var fixtureGeometry: [ROBAmberDiagnosticsArm: ROBAmberArmSchematicGeometry] { geometry }
    fileprivate var fixtureReady: Bool { modelLoadFinished }
}

@main
struct ArmSchematicFixture {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    private static func sample(_ positions: [Double]) -> ROBAmberDiagnosticsSample {
        ROBAmberDiagnosticsSample(receivedAt: Date(), receivedAtUptime: ProcessInfo.processInfo.systemUptime,
            sequence: 1, sampleAgeMilliseconds: 0, controllerSampleAgeMilliseconds: 0,
            jointFeedbackAgeMilliseconds: Array(repeating: 0, count: 7), gripperFeedbackAgeMilliseconds: 0,
            positionsRadians: positions, velocitiesRadiansPerSecond: [], currents: [], statuses: [],
            targetPositionsRadians: nil)
    }

    static func main() throws {
        _ = NSApplication.shared
        let view = ROBAmberArmSchematicView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
        let deadline = Date(timeIntervalSinceNow: 10)
        while !view.fixtureReady && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        expect(view.fixtureGeometry.count == 2, "Bundled side-specific geometry failed to load")
        let zero = Array(repeating: 0.0, count: 7)
        for arm in ROBAmberDiagnosticsArm.allCases {
            let geometry = view.fixtureGeometry[arm]!
            let hanging = geometry.points(vendorPositions: zero)!
            expect(hanging.count == 8, "Need seven joints and the tool endpoint")
            expect(hanging.last!.z < hanging[0].z - 0.20,
                   "Zero feedback must hang below the shoulder, not point straight up")
            expect(arm == .left ? hanging[0].y > 0 : hanging[0].y < 0,
                   "Physical shoulder placement has the wrong side")
            let model = geometry.model
            expect(model.physicalSide == arm.rawValue, "Physical arm identity was swapped")
            let modelZero = model.positions(vendorLeft: zero)
            expect(abs(modelZero[model.armJointPrefix + "2"]!) > 2,
                   "Raw vendor zero was mistaken for the straight URDF zero")
            expect(arm == .left ? modelZero["left_joint2"]! < 0 : modelZero["right_joint2"]! > 0,
                   "Hanging offsets were mirrored incorrectly")
            let raised = geometry.points(vendorPositions: model.armUprightPrior)!
            expect(raised.last!.z > raised[0].z + 0.20, "A raised model pose was forced to stay hanging")
            expect(simd_distance(hanging.last!, raised.last!) > 0.50, "Feedback did not articulate the arm")
            let frames = model.frames(model.positions(vendorLeft: model.recyclingFrontTarget))
            let target = geometry.points(vendorPositions: model.recyclingFrontTarget)!
            let tool = frames[model.toolLink]!.columns.3
            expect(simd_distance(target.last!, SIMD3(tool.x, tool.y, tool.z)) < 1e-10,
                   "Diagnostics and ghost disagree on a nonzero target")

            let mount = ROBAmberArmMount(translationMeters: [0.12, 0.31, 0.85], rotationRPYRadians: [0.1, -0.2, 0.3])
            let relocated = geometry.points(vendorPositions: zero, measuredMount: mount)!
            let canonical = model.frames(modelZero)[arm.rawValue + "_base_link"]!
            for (original, actual) in zip(hanging, relocated) {
                let expected = mount.transform * simd_inverse(canonical) * SIMD4(original, 1)
                expect(simd_distance(actual, SIMD3(expected.x, expected.y, expected.z)) < 1e-10,
                       "An explicit measured mount was discarded or applied twice")
            }
            expect(geometry.points(vendorPositions: []) == nil, "Missing feedback became a measured zero pose")
            expect(geometry.points(vendorPositions: Array(repeating: .nan, count: 7)) == nil,
                   "Invalid feedback became pose lines")
            expect(geometry.points(vendorPositions: Array(repeating: .infinity, count: 7)) == nil,
                   "Infinite feedback became pose lines")
            var beyondLimit = zero; beyondLimit[1] = 3.0
            let atLimit = geometry.points(vendorPositions: [0, 2.3213, 0, 0, 0, 0, 0])!
            expect(simd_distance(geometry.points(vendorPositions: beyondLimit)!.last!, atLimit.last!) > 0.05,
                   "Out-of-range feedback was silently clamped in the picture")
            print("\(arm.rawValue): hanging tool is \(hanging[0].z - hanging.last!.z) m below J1")
        }

        // Synthetic frames only. This executable links no gateway or controller.
        let image = NSImage(size: NSSize(width: 840, height: 940))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 840, height: 940).fill()
        let labels = ["Zero encoder feedback — both arms hanging",
                      "Different joint feedback — orange target uses the same reference",
                      "No telemetry — gray photo reference only"]
        for row in 0..<3 {
            view.leftSample = row == 2 ? nil : sample(row == 0 ? zero : [-0.3, 0.7, 0, 0.1, 0, 0, 0])
            view.rightSample = row == 2 ? nil : sample(row == 0 ? zero : [0.6, -0.8, 0, -0.2, 0, 0, 0])
            view.leftTarget = row == 1 ? zero : nil
            view.rightTarget = row == 1 ? zero : nil
            let y = CGFloat(2 - row) * 300 + 20
            (labels[row] as NSString).draw(at: NSPoint(x: 20, y: y + 268), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: 20, yBy: y); transform.concat()
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Amber pose geometry and inert rendering fixtures passed")
    }
}
'''


def main():
    output = Path(sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/rob-amber-arm-schematic.png")
    source = (ROOT / "Cerebro/ROBAmberDiagnosticsWindowController.swift").read_text()
    # Compile the unchanged production helpers/view, excluding the live window
    # controller and all transports. File-private state stays in this fixture.
    prefix = source[:source.index("@objcMembers public final class ROBAmberDiagnosticsWindowController")]
    suffix = source[source.index("private extension Collection {"):]
    bindings = (ROOT / "Cerebro/ROBAmberArmBinding.swift").read_text()
    stub = "enum ROBArmSide: String, CaseIterable { case left, right }\nenum ROBAmberGatewayState { case ready }\n"
    with tempfile.TemporaryDirectory(prefix="rob-amber-pose-") as folder:
        folder = Path(folder)
        app = folder / "PoseFixture.app/Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "Resources").mkdir()
        (app / "Resources/ShadowPlanner").symlink_to(ROOT / "Cerebro/Resources/ShadowPlanner")
        (app / "Info.plist").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.orbitusrobotics.amber-pose-fixture</string>
<key>CFBundleExecutable</key><string>PoseFixture</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>''')
        fixture = folder / "Fixture.swift"
        fixture.write_text(stub + bindings + prefix + suffix + FIXTURE)
        sources = ["ROBArmRoutinePlan", "ROBArmJointLimits", "ROBGhostMotionPlan",
                   "ROBWorkspaceSearchPlan", "ROBWorkspaceCollisionPlan", "ROBAmberB1Kinematics"]
        binary = app / "MacOS/PoseFixture"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        *[str(ROOT / f"Cerebro/{name}.swift") for name in sources], str(fixture),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(output)], check=True, timeout=30)


if __name__ == "__main__":
    main()
