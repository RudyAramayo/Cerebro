import AppKit
import Foundation

@main
@MainActor
private struct ROBSystemStatusWindowSmokeTests {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        var snapshotRequests = 0
        let controller = ROBSystemStatusWindowController {
            snapshotRequests += 1
            return ROBSystemStatusSnapshot(
                services: [
                    ROBSystemServiceCardSnapshot(
                        id: "smoke-service",
                        displayName: "Smoke Service",
                        category: .other,
                        state: .healthy,
                        detail: "Available",
                        metrics: [
                            .init(label: "RX", value: "12 KB/s"),
                            .init(label: "TX", value: "2 KB/s"),
                            .init(label: "Round trip", value: "8.4 ms"),
                        ]
                    )
                ],
                controllers: []
            )
        }

        controller.showWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let window = controller.window else {
            fatalError("Programmatic Services window was not created")
        }
        precondition(window.isVisible, "Programmatic Services window was not presented")
        precondition(
            window.title == "Cerebro Service Status",
            "Programmatic Services window has the wrong title"
        )
        precondition(snapshotRequests > 0, "Services window did not request its cached snapshot")

        window.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(of: window.contentView)
        guard let serviceRow = views.first(where: {
            String(describing: type(of: $0)) == "ROBSystemStatusCardView"
        }) else {
            fatalError("Services did not render a compact status row")
        }
        precondition(serviceRow.frame.width > 800, "Service row did not expand across the panel")
        let collapsedHeight = serviceRow.frame.height
        precondition(collapsedHeight <= 54, "Collapsed service row is still unnecessarily tall")

        guard let disclosure = views.compactMap({ $0 as? NSButton }).first(where: {
            $0.accessibilityLabel() == "Show details"
        }) else {
            fatalError("Service row has no accessible disclosure control")
        }
        disclosure.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(
            serviceRow.frame.height > collapsedHeight,
            "Expanding a service row did not reveal its detail and metrics"
        )

        controller.close()
        print("Programmatic Services window creation and presentation smoke test passed")
    }

    private static func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }
}
