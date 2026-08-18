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
                        detail: "Available"
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

        controller.close()
        print("Programmatic Services window creation and presentation smoke test passed")
    }
}
