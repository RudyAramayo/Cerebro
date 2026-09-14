import AppKit

func argument(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

// This executable links geometry/AppKit only. It has no Cerebro application
// delegate, serial drivers, network bridge, or actuator clients.
if let destination = argument("--export-draft") {
    do {
        let profile = try argument("--profile").map { try ROBGeometryProfile.load(URL(fileURLWithPath: $0)) } ?? .draft()
        let vendor = try argument("--vendor").map { try ROBGeometryVendor(url: URL(fileURLWithPath: $0)) }
        try ROBGeometryURDF.export(profile, vendor: vendor, to: URL(fileURLWithPath: destination))
        print("Exported simulation-only calibration bundle: \(destination)")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

final class GeometryAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--pose-ik") {
            ROBArmIKWindowController.shared.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ROBRobotGeometryWindowController.shared
        do {
            if let path = argument("--profile") { try controller.installProfile(ROBGeometryProfile.load(URL(fileURLWithPath: path))) }
            if let path = argument("--vendor") { try controller.installVendor(URL(fileURLWithPath: path)) }
        } catch { fputs("Geometry load: \(error.localizedDescription)\n", stderr) }
        DispatchQueue.main.async {
            NSApp.unhide(nil)
            controller.showWindow(nil)
            controller.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
        if let path = argument("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                do { try controller.sceneSnapshot(to: URL(fileURLWithPath: path)) }
                catch { fputs("Snapshot: \(error.localizedDescription)\n", stderr); exit(1) }
                if CommandLine.arguments.contains("--exit-after-snapshot") { NSApp.terminate(nil) }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ROBRobotGeometryWindowController.shared.showWindow(nil)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = GeometryAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(), applicationItem = NSMenuItem(), applicationMenu = NSMenu()
applicationMenu.addItem(withTitle: "Quit ROB Geometry Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
let editItem = NSMenuItem(), editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu; menu.addItem(editItem); app.mainMenu = menu
withExtendedLifetime(delegate) { app.run() }
