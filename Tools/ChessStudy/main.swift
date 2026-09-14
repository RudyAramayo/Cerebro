import AppKit

final class ChessStudyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        let controller = ROBChessStudyWindowController.shared
        if let index = CommandLine.arguments.firstIndex(of:"--fixture"), index+1 < CommandLine.arguments.count {
            try? controller.loadDemo(imageURL:URL(fileURLWithPath:CommandLine.arguments[index+1]),
                corners:[.init(x:0.1,y:0.1),.init(x:0.9,y:0.1),.init(x:0.9,y:0.9),.init(x:0.1,y:0.9)])
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = ChessStudyAppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
let menu = NSMenu()
let appItem = NSMenuItem(); let appMenu = NSMenu()
appMenu.addItem(withTitle:"Quit ROB Chess Study",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
appItem.submenu = appMenu; menu.addItem(appItem)
let editItem = NSMenuItem(); editItem.title = "Edit"
let edit = NSMenu(title:"Edit")
edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
editItem.submenu = edit; menu.addItem(editItem); application.mainMenu = menu
application.run()
