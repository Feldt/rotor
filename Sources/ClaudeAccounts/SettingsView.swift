import ClaudeAccountsCore
import AppKit
import SwiftUI

struct SettingsView: View {
    var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Show Usage", isOn: Binding(get: { model.showUsage }, set: { model.setShowUsage($0) }))
                    .help("Reads the Keychain once and fetches usage from Anthropic. Off: no Keychain or network")
                if model.showUsage, model.keychainDenied {
                    LabeledContent("Keychain Denied") {
                        Button("Retry") { model.retryKeychain() }.controlSize(.small)
                    }
                    .help("Keychain access was denied; Retry asks once more")
                }
                Toggle("Switch Chrome", isOn: Binding(get: { model.state.chromeFollows }, set: { model.setChromeFollows($0) }))
                    .help("Chrome's claude.ai login follows the switch when Chrome next quits")
                if model.state.chromeFollows {
                    if model.state.chromeAttributionConfirmed == true {
                        Picker("Chrome Switches", selection: Binding(get: { model.state.chromeMode ?? .withClaude },
                                                                    set: { model.setChromeMode($0) })) {
                            Text("With Claude").tag(ChromeMode.withClaude)
                            Text("When Chrome Quits").tag(ChromeMode.whenChromeQuits)
                        }
                        .help("With Claude restarts Chrome together with Claude")
                    } else {
                        ChromeAttributionRow(model: model)
                    }
                }
                Toggle("Open at Login", isOn: Binding(get: { model.isOpenAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section {
                Toggle(PanelCopy.parallelWindows, isOn: Binding(get: { model.parallelEnabled }, set: { model.setParallelWindows($0) }))
                    .help("Each extra window needs one sign-in of its own. Windows never reopen at login")
            }
            Section {
                LabeledContent("Backups") {
                    Menu("Roll Back") {
                        let backups = Array(model.store.backups().prefix(8))
                        if backups.isEmpty { Text("None Yet") }
                        ForEach(backups, id: \.id) { b in
                            Button(title(b)) { model.rollback(b.id) }
                        }
                        Divider()
                        Button("Show in Finder") { model.showBackups() }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.isSwitching)
                }
                VersionRow(model: model, updater: model.updater)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 360)
        .onChange(of: rowCount) { SettingsWindow.fit(rows: rowCount) }
        .onAppear {
            model.refresh()
            model.updater.check()
            model.isOpenAtLogin = LoginItem.isEnabled
        }
    }

    /// Rows in the first section (it grows with Keychain retry and Chrome account), then 2 below.
    var rowCount: Int {
        3 + (model.showUsage && model.keychainDenied ? 1 : 0) + (model.state.chromeFollows ? 1 : 0)
    }

    private func title(_ b: BackupManifest) -> String {
        let label = b.fromAccount.flatMap { id in model.accounts.first { $0.id == id }?.shortLabel } ?? "Previous"
        return "\(label), \(b.createdAt.formatted(.relative(presentation: .named)))"
    }
}

/// One row: "Version abc1234" and a single trailing control.
struct VersionRow: View {
    var model: AppModel
    var updater: UpdateController

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            Text("Version \(updater.shortCommit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(updater.detailTooltip)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch updater.phase {
        case .building, .installing, .restarting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            }
        case .failed:
            HStack(spacing: 6) {
                Text(PanelCopy.updateFailed).foregroundStyle(.orange)
                Button("Log") { updater.showLog() }.buttonStyle(.link)
            }
        case .idle:
            if updater.needsUpdate {
                Button("Update") { updater.performUpdate() }
                    .controlSize(.small)
                    .disabled(model.updateBlockReason != nil)
                    .help(model.updateBlockReason ?? "Rebuild if needed and restart. macOS asks for Keychain access again after")
            } else {
                Text("Up to Date").foregroundStyle(.tertiary)
            }
        }
    }
}

/// The Settings window, hosted directly so it opens reliably from the panel and the hotkey.
@MainActor enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 360, height: height(rows: SettingsView(model: model).rowCount)))
            w.title = Product.name
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            if ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_STATE"] != nil, let screen = NSScreen.screens.first {
                // Demo screenshots: on the main display, above the wallpaper backdrop.
                w.level = .popUpMenu
                let f = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Grouped-form height: insets, three sections, ~38 pt per row. Set explicitly to avoid the
    /// hosting view's content-size feedback loop with a scrolling Form.
    static func height(rows: Int) -> CGFloat { 20 + CGFloat(rows) * 38 + 20 + parallelSection + 20 + 2 * 38 + 2 }

    /// The Parallel Windows section: one toggle row and a two-line footer.
    static let parallelSection: CGFloat = 38 + 34

    static func fit(rows: Int) {
        guard let w = window else { return }
        var f = w.frame
        let newContent = NSSize(width: 360, height: height(rows: rows))
        let newFrame = w.frameRect(forContentRect: NSRect(origin: .zero, size: newContent))
        f.origin.y += f.height - newFrame.height
        f.size = newFrame.size
        w.setFrame(f, display: true, animate: true)
    }
}

/// First enable: "Chrome is signed in as [guess ▾]" with Confirm. Nothing swaps Chrome before this.
struct ChromeAttributionRow: View {
    var model: AppModel
    @State private var choice: String = ""

    var body: some View {
        LabeledContent("Chrome is signed in as") {
            HStack(spacing: 6) {
                Picker("", selection: $choice) {
                    ForEach(model.accounts) { a in Text(a.shortLabel).tag(a.id) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Confirm") { if choice.isEmpty == false { model.confirmChromeAccount(choice) } }
                    .controlSize(.small)
                    .disabled(choice.isEmpty)
            }
        }
        .help("The account Claude in Chrome uses now. Chrome follows switches once confirmed")
        .onAppear {
            choice = model.chromeGuess ?? model.currentID ?? ""
            if model.chromeGuess == nil { model.loadChromeGuess() }
        }
        .onChange(of: model.chromeGuess) { if let g = model.chromeGuess { choice = g } }
    }
}
