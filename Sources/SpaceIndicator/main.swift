import AppKit

// Private CoreGraphics APIs — only way to read Space info on macOS
typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSGetActiveSpace")   func CGSGetActiveSpace(_: CGSConnectionID) -> Int
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_: CGSConnectionID) -> CFArray

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        refresh()
    }

    @objc func spaceDidChange() { refresh() }

    func refresh() {
        let cid = CGSMainConnectionID()
        let activeID = CGSGetActiveSpace(cid)
        let displays = CGSCopyManagedDisplaySpaces(cid) as! [[String: Any]]

        var index = 1
        outer: for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for (i, space) in spaces.enumerated() {
                if let id = space["id64"] as? Int, id == activeID {
                    index = i + 1
                    break outer
                }
            }
        }

        DispatchQueue.main.async {
            self.statusItem.button?.title = "\(index)"
        }
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
