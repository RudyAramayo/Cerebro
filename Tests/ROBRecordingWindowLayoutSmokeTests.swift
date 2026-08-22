import AppKit
import Foundation

extension Notification.Name {
    static let robRecordingStateDidChange = Notification.Name("ROBRecordingStateDidChange")
}

struct ROBTrainingRecordingConfiguration {
    let faceCameraEnabled: Bool
    let bellyCameraEnabled: Bool
    let keyframesPerSecond: Double
}

struct ROBFootageRecordingConfiguration {
    let faceResolution: String?
    let bellyResolution: String?
    let insta360Resolution: String?
}

struct ROBRecordingStatusSnapshot {
    let trainingActive = false
    let footageActive = false
    let trainingDirectory: URL? = nil
    let footageDirectory: URL? = nil
    let trainingFrameCount: UInt64 = 0
    let lidarScanCount: UInt64 = 0
    let footageFrameCount: UInt64 = 0
}

final class ROBRecordingCoordinator: NSObject {
    static let shared = ROBRecordingCoordinator()

    func statusSnapshot() -> ROBRecordingStatusSnapshot { .init() }
    func stopTraining() {}
    func stopFootage() {}
    func startTraining(_ configuration: ROBTrainingRecordingConfiguration) throws {}
    func startFootage(_ configuration: ROBFootageRecordingConfiguration) throws {}
    func addOperatorLabel(_ label: String) {}
}

@main
@MainActor
private struct ROBRecordingWindowLayoutSmokeTests {
    static func main() throws {
        _ = NSApplication.shared
        let controller = ROBRecordingWindowController.shared
        guard let window = controller.window,
              let content = window.contentView else {
            throw Failure.failed("Recording controller did not create its window")
        }
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 660, height: 530))
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()

        let descendants = allSubviews(of: content)
        guard let scroll = descendants.compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView,
              document.frame.height > scroll.contentView.bounds.height else {
            throw Failure.failed("Recording controls are not protected by a scroll view")
        }
        let boxes = descendants.compactMap { $0 as? NSBox }
        guard boxes.count == 2,
              boxes.contains(where: { $0.title == "Traversability training corpus" && $0.frame.height >= 200 }),
              boxes.contains(where: { $0.title == "Camera footage (not training data)" && $0.frame.height >= 280 }) else {
            throw Failure.failed("Recording sections collapsed below their usable height")
        }

        for box in boxes {
            guard let stack = allSubviews(of: box).compactMap({ $0 as? NSStackView }).first else {
                throw Failure.failed("\(box.title) has no laid-out content stack")
            }
            let arranged = stack.arrangedSubviews
            guard arranged.allSatisfy({ $0.frame.height >= 14 }) else {
                let heights = arranged.map { String(format: "%.1f", $0.frame.height) }
                    .joined(separator: ", ")
                throw Failure.failed(
                    "\(box.title) contains vertically compressed controls (\(heights))"
                )
            }
            for firstIndex in arranged.indices {
                for secondIndex in arranged.indices where secondIndex > firstIndex {
                    if arranged[firstIndex].frame.intersects(arranged[secondIndex].frame) {
                        throw Failure.failed("\(box.title) contains overlapping rows")
                    }
                }
            }
        }

        let buttons = descendants.compactMap { $0 as? NSButton }
            .filter { !$0.title.isEmpty }
        guard buttons.allSatisfy({ $0.frame.width + 1 >= $0.intrinsicContentSize.width }) else {
            throw Failure.failed("A recording control button title is horizontally compressed")
        }

        controller.close()
        print("ROB recording window layout smoke tests passed")
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    private enum Failure: Error {
        case failed(String)
    }
}
