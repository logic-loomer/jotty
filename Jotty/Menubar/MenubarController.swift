import AppKit

@MainActor
final class MenubarController {
    let statusItem: NSStatusItem
    var onCapture: (() -> Void)?
    var onSettings: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📝"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture…", action: #selector(captureClicked), keyEquivalent: "n").also { $0.target = self })
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",").also { $0.target = self })
        menu.addItem(NSMenuItem(title: "Quit Jotty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func captureClicked() { onCapture?() }
    @objc private func settingsClicked() { onSettings?() }
}

private extension NSObject {
    func also(_ block: (Self) -> Void) -> Self { block(self); return self }
}
