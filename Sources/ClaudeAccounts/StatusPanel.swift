import AppKit
import ClaudeAccountsCore
import SwiftUI

/// The fallback host: an NSStatusItem plus a borderless, non-activating NSPanel whose SwiftUI
/// root draws Liquid Glass itself.
@MainActor final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: GlassPanel
    private var clickMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let host = NSHostingController(rootView: PanelView(model: model, host: .panel) {
            SettingsWindow.show(model: model)
        })
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        panel = GlassPanel(contentViewController: host)
        super.init()
        panel.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(Product.name)
        }
        updateButton()
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.position()
                self?.panel.invalidateShadow()
            }
        }
    }

    private func updateButton() {
        withObservationTracking {
            item.button?.image = StatusIcon.image(spinning: model.isSwitching, frame: SpinClock.shared.frame,
                                                  badge: model.needsAttention)
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.updateButton() } }
        }
    }

    @objc func togglePanel() { toggle() }

    func toggle() {
        if panel.isVisible { close() } else { open() }
    }

    func open() {
        model.refresh()
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.displayIfNeeded()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        item.button?.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.panel.orderOut(nil) }
        })
    }

    /// Top edge 6 pt under the status item, centred on it, kept on screen.
    private func position() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = anchor.minY - 6 - size.height
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Menus opened from the panel take key; don't close for those.
        if NSApp.keyWindow == nil || NSApp.keyWindow === panel { return }
        close()
    }
}

final class GlassPanel: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
