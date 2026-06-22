import AppKit
import IOKit

// MARK: - Private APIs

typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSGetActiveSpace")   func CGSGetActiveSpace(_: CGSConnectionID) -> Int
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_: CGSConnectionID) -> CFArray

@_silgen_name("IOHIDSetScrollAcceleration")
func IOHIDSetScrollAcceleration(_ connect: io_connect_t, _ acceleration: Double) -> kern_return_t

// MARK: - Scroll Acceleration

// IOHIDSystem connect type for reading/writing HID parameters
private let kIOHIDParamConnectType: UInt32 = 1
private let kDefaultScrollAcceleration: Double = 0.6875
private let kLinearScrollKey = "linearScroll"

@discardableResult
private func withHIDConnection<T>(_ body: (io_connect_t) -> T) -> T? {
    let service = IOServiceGetMatchingService(0, IOServiceMatching("IOHIDSystem"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = IO_OBJECT_NULL
    guard IOServiceOpen(service, mach_task_self_, kIOHIDParamConnectType, &connect) == KERN_SUCCESS else { return nil }
    defer { IOServiceClose(connect) }
    return body(connect)
}

private func setScrollLinear(_ linear: Bool) {
    withHIDConnection { connect in
        IOHIDSetScrollAcceleration(connect, linear ? -1 : kDefaultScrollAcceleration)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var linearScrollItem: NSMenuItem!

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)

        let menu = NSMenu()

        linearScrollItem = NSMenuItem(title: "Linear Scroll", action: #selector(toggleLinearScroll), keyEquivalent: "")
        linearScrollItem.target = self
        menu.addItem(linearScrollItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        // Default to enabled on first launch
        if UserDefaults.standard.object(forKey: kLinearScrollKey) == nil {
            UserDefaults.standard.set(true, forKey: kLinearScrollKey)
        }
        applyScrollSetting()
        refresh()
    }

    private func applyScrollSetting() {
        let enabled = UserDefaults.standard.bool(forKey: kLinearScrollKey)
        setScrollLinear(enabled)
        linearScrollItem.state = enabled ? .on : .off
    }

    @objc func toggleLinearScroll() {
        let newValue = !UserDefaults.standard.bool(forKey: kLinearScrollKey)
        UserDefaults.standard.set(newValue, forKey: kLinearScrollKey)
        applyScrollSetting()
    }

    @objc func spaceDidChange() { refresh() }

    func refresh() {
        let cid = CGSMainConnectionID()
        let displays = CGSCopyManagedDisplaySpaces(cid) as! [[String: Any]]

        var indices: [String] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]],
                  let currentSpace = display["Current Space"] as? [String: Any],
                  let currentID = currentSpace["id64"] as? Int else { continue }
            let index = (spaces.firstIndex { ($0["id64"] as? Int) == currentID } ?? 0) + 1
            indices.append("\(index)")
        }

        let title = indices.isEmpty ? "?" : indices.joined(separator: "·")
        DispatchQueue.main.async {
            self.statusItem.button?.title = title
        }
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
