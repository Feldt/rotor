import AppKit
import Carbon.HIToolbox
import ClaudeAccountsCore
import SwiftUI

/// `panelStyle`: "menuBarExtra" (default; the system's glass window) or "panel" (borderless
/// NSPanel fallback drawing its own glass).
/// `defaults write local.rotor.claude-accounts panelStyle panel`
enum PanelStyle {
    static var current: PanelHost {
        let env = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_PANEL_STYLE"]
        let v = env ?? UserDefaults.standard.string(forKey: "panelStyle") ?? "menuBarExtra"
        return v == "panel" ? .panel : .menuBarExtra
    }
}

@main
struct ClaudeAccountsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var usesExtra = PanelStyle.current == .menuBarExtra

    var body: some Scene {
        MenuBarExtra(isInserted: $usesExtra) {
            ExtraPanel(model: delegate.model)
                .containerBackground(.clear, for: .window)
        } label: {
            MenuBarGlyph(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}

private struct ExtraPanel: View {
    var model: AppModel
    var body: some View {
        PanelView(model: model, host: .menuBarExtra) {
            NSApp.keyWindow?.close()
            SettingsWindow.show(model: model)
        }
    }
}

struct MenuBarGlyph: View {
    var model: AppModel
    var body: some View {
        Image(nsImage: StatusIcon.image(spinning: model.isSwitching, frame: SpinClock.shared.frame,
                                        badge: model.needsAttention))
            .accessibilityLabel(Product.name)
    }
}

/// The menu bar glyph: the app icon's two overlapping discs as 18 pt template outlines. While
/// switching, the discs slowly orbit; a small dot marks something needing attention.
@MainActor enum StatusIcon {
    static func image(spinning: Bool, frame: Int, badge: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let angle = spinning ? CGFloat(frame) * .pi / 12 : 0
            let c = CGPoint(x: 9, y: 9)
            let d: CGFloat = 2 * cos(angle) + 0
            let dy: CGFloat = spinning ? 2 * sin(angle) : 0
            let r: CGFloat = 4.8
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: CGRect(x: c.x - 2 - d * (spinning ? 1 : 0) - r, y: c.y - dy - r, width: 2 * r, height: 2 * r))
            ctx.strokeEllipse(in: CGRect(x: c.x + 2 + d * (spinning ? 1 : 0) - r, y: c.y + dy - r, width: 2 * r, height: 2 * r))
            if badge {
                let dot = CGRect(x: 13, y: 12.5, width: 4.5, height: 4.5)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: dot.insetBy(dx: -1.2, dy: -1.2))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: dot)
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = Product.name
        return img
    }
}

@MainActor @Observable final class SpinClock {
    static let shared = SpinClock()
    var frame = 0
    @ObservationIgnored private var timer: Timer?
    func run(_ on: Bool) {
        if on, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
                MainActor.assumeIsolated { SpinClock.shared.frame = (SpinClock.shared.frame + 1) % 24 }
            }
        } else if on == false {
            timer?.invalidate()
            timer = nil
            frame = 0
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let paths = Paths.fromEnvironment()
    let engine = SwitchEngine.system(paths: AppDelegate.paths)
    lazy var model = AppModel(engine: engine, usageProvider: makeUsage())

    /// The real usage service, unless the demo (fakes) or "Show Usage" off (none).
    private func makeUsage() -> UsageProvider {
        let env = ProcessInfo.processInfo.environment
        if env["CLAUDE_ACCOUNTS_DRY_CONTROLLER"] == "1", env["CLAUDE_ACCOUNTS_DEMO_STATE"] != nil {
            return FakeUsageProvider()
        }
        let paths = AppDelegate.paths
        let tokens = KeychainTokenSource(paths: paths, currentAccount: { [engine] in engine.currentAccount() },
                                         isAddInProgress: { [engine] in engine.store.state().pendingAddLabel != nil })
        return UsageService(paths: paths, http: SecureHTTPClient(), tokens: tokens,
                            buildCommit: Bundle.main.infoDictionary?["CAGitCommit"] as? String,
                            log: { msg in AccountStore(paths: paths).log(msg) })
    }
    private var statusPanel: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if PanelStyle.current == .panel {
            statusPanel = StatusPanelController(model: model)
        }
        observeSwitching()
        model.closePanel = { [weak self] in
            guard let self, self.model.isPanelOpen else { return }
            self.togglePanel()
        }
        model.startUsageScheduler()
        LoginItem.enableOnceByDefault(store: model.store)
        model.isOpenAtLogin = LoginItem.isEnabled
        HotKey.register { [weak self] in self?.togglePanel() }
        showDemoBackdrop()
        if ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_STATE"] == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { SettingsWindow.show(model: self.model) }
        } else if ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.togglePanel() }
        }
    }

    private var backdrop: NSWindow?

    /// Screenshots only (demo + dry-run controller): a system wallpaper behind the panel, so no
    /// personal screen content shows through the glass.
    private func showDemoBackdrop() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLAUDE_ACCOUNTS_DRY_CONTROLLER"] == "1", env["CLAUDE_ACCOUNTS_DEMO_STATE"] != nil,
              let screen = NSScreen.screens.first else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic")
        view.imageScaling = .scaleAxesIndependently
        w.contentView = view
        w.orderFront(nil)
        backdrop = w
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isSwitching ? .terminateCancel : .terminateNow
    }

    private func observeSwitching() {
        withObservationTracking {
            _ = model.isSwitching
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SpinClock.shared.run(self.model.isSwitching)
                    self.observeSwitching()
                }
            }
        }
    }

    func togglePanel() {
        if model.isPanelOpen == false { AppModel.OpenTiming.requestedAt = CFAbsoluteTimeGetCurrent() }
        if let statusPanel {
            statusPanel.toggle()
        } else {
            MenuBarExtraOpener.toggle()
        }
    }
}

/// Opens the MenuBarExtra window programmatically (for the hotkey): click its status item button.
@MainActor enum MenuBarExtraOpener {
    static func toggle() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBarWindow") {
            if let button = w.contentView?.firstSubview(of: NSStatusBarButton.self) {
                button.performClick(nil)
                return
            }
        }
    }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let s = self as? T { return s }
        for v in subviews { if let f = v.firstSubview(of: type) { return f } }
        return nil
    }
}

/// ⌥⌘A, via Carbon (no Accessibility permission needed).
@MainActor enum HotKey {
    nonisolated(unsafe) static var handler: (@MainActor () -> Void)?
    nonisolated(unsafe) static var ref: EventHotKeyRef?

    static func register(_ action: @escaping @MainActor () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handler?() } }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | optionKey),
                            EventHotKeyID(signature: OSType(0x4341_4343), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
