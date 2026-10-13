import AppKit
import ClaudeAccountsCore
import SwiftUI

/// How the panel is hosted. `.menuBarExtra` sits on the system's glass window; `.panel` is a
/// borderless NSPanel and draws the glass itself.
enum PanelHost { case menuBarExtra, panel }

/// Snappy, no overshoot (≈0.2 s).
enum Motion {
    static let expand = Animation.spring(duration: 0.2, bounce: 0)
}

enum Metrics {
    static let width: CGFloat = 300
    static let inset: CGFloat = 5
    /// Top and bottom inset of the list, like Control Center modules.
    static let listV: CGFloat = 10
    static let listTop: CGFloat = 14
    /// Inner padding of an expanded row.
    static let expandedPad: CGFloat = 10
    static let rowH: CGFloat = 9
    static let rowHeight: CGFloat = 30
    static let itemHeight: CGFloat = 24
    static let radius: CGFloat = 8
    static let panelRadius: CGFloat = 16
    static let avatar: CGFloat = 24
}

/// Demo screenshots never take keyboard focus (they'd catch whatever the user is typing).
let isDemo = ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_STATE"] != nil

private let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown]
func accountTint(_ a: Account) -> Color { palette[a.colorIndex % palette.count] }

/// Control Center-style panel: the account list, one optional status line, then menu items.
struct PanelView: View {
    var model: AppModel
    var host: PanelHost
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var collapseTask: Task<Void, Never>?

    /// The folders overlap until the pointer is over the panel. VoiceOver always gets them spread.
    private var isSpread: Bool {
        isHovering || NSWorkspace.shared.isVoiceOverEnabled
            || (isDemo && ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_SPREAD"] == "1")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                FolderStack(model: model, spread: isSpread)
                if model.addDraft.isOpen { AddRow(model: model) }
            }
            .padding(.horizontal, Metrics.inset)
            .padding(.top, Metrics.listTop)
            .padding(.bottom, Metrics.listV)

            if let text = statusText {
                StatusLineView(model: model, text: text)
                    .padding(.horizontal, Metrics.inset + Metrics.rowH)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }

            Divider().padding(.horizontal, Metrics.inset + Metrics.rowH)

            VStack(spacing: 0) {
                MenuItem("Add Account…") { model.addDraft.open() }
                    .disabled(model.isSwitching || model.addDraft.isOpen)
                if model.syncHealth != .ok {
                    MenuItem("Repair Chat Sync", symbol: "exclamationmark.triangle.fill", help: syncHelp) { model.repairSync() }
                }
                MenuItem("Settings…") { openSettings() }
                MenuItem("Quit") { NSApp.terminate(nil) }
                    .disabled(model.isSwitching)
            }
            .padding(Metrics.inset)
        }
        .frame(width: Metrics.width)
        .animation(reduceMotion ? nil : Motion.expand, value: model.activity)
        .animation(reduceMotion ? nil : Motion.expand, value: model.line)
        .animation(reduceMotion ? nil : Motion.expand, value: model.addDraft)
        .animation(reduceMotion ? nil : Motion.expand, value: model.expandedID)
        .modifier(HostBackground(host: host))
        .onHover { inside in
            collapseTask?.cancel()
            if inside {
                withAnimation(reduceMotion ? nil : FolderMotion.fan) { isHovering = true }
            } else {
                // A short grace period so brushing the edge doesn't snap the stack shut.
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard Task.isCancelled == false else { return }
                    withAnimation(reduceMotion ? nil : FolderMotion.fold) { isHovering = false }
                }
            }
        }
        .onAppear {
            model.isPanelOpen = true
            model.panelOpened()
            if let t = AppModel.OpenTiming.requestedAt,
               ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEBUG_TIMING"] == "1" {
                let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
                let main = AppModel.OpenTiming.mainThreadWork * 1000
                FileHandle.standardError.write(Data(String(format: "open-to-first-render %.1f ms (main-thread work on open %.2f ms)\n", ms, main).utf8))
                AppModel.OpenTiming.requestedAt = nil
            }
        }
        .onDisappear {
            model.isPanelOpen = false
            model.panelClosed()
        }
    }

    private var syncHelp: String {
        if case .broken(let why) = model.syncHealth { return why }
        return ""
    }

    private var statusText: String? {
        if let op = model.windowOp {
            switch op {
            case .opening: return PanelCopy.openingWindow
            case .closing: return PanelCopy.closingWindow
            case .reopening: return PanelCopy.reopeningWindow
            case .signingIn(_, let phase): return PanelCopy.signInStep(phase)
            }
        }
        if model.isSwitching {
            if model.activity?.accountID == "chrome" { return PanelCopy.restartingChrome }
            return model.activity.map { PanelCopy.step($0.phase) } ?? PanelCopy.switching
        }
        switch model.line {
        case nil: return nil
        case .notConfirmed: return PanelCopy.notConfirmed
        case .failed: return PanelCopy.switchFailed
        case .interrupted: return PanelCopy.restoreFailed
        case .signedInAsKnown(let label): return PanelCopy.signedInAgain(label)
        case .waitingForSignIn: return PanelCopy.waitingForSignIn
        case .chrome(let d):
            return d == EngineError.chromeSchemaChanged.description ? PanelCopy.chromeUpdate : PanelCopy.chromeNotSwitched
        case .chromePending: return PanelCopy.chromePending
        case .confirmRestartChrome: return PanelCopy.restartChrome
        case .chromeSignIn: return PanelCopy.signInChrome
        case .chromeTabsWarning: return PanelCopy.chromeTabs
        case .error(let title, _): return title
        case .info(let text): return text
        case .keychainDenied: return PanelCopy.keychainDenied
        case .confirmWindowSignIn: return PanelCopy.windowSignInConfirm
        }
    }
}

/// One account: avatar (with its 5-hour usage ring), label, and a single trailing mark. A click
/// expands it in place to show usage and, for other accounts, its buttons; a collapsed row has none.
struct AccountRow: View {
    var account: Account
    var model: AppModel
    @State private var isHovered = false
    @State private var name = ""
    @FocusState private var isNaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if account.needsLabel != true, let u = model.usage[account.id], u.needsRefresh == false,
               u.fiveHour != nil || u.weekly != nil {
                UsageBars(usage: u, stale: model.staleAge(account.id))
                    .padding(.leading, (isExpanded ? Metrics.expandedPad : Metrics.rowH) + Metrics.avatar + 8)
                    .padding(.trailing, isExpanded ? Metrics.expandedPad : Metrics.rowH)
                    .padding(.bottom, isExpanded ? 4 : 8)
            }
            if isExpanded {
                ExpandedUsage(account: account, model: model, subtitle: plan.isSubtitleInDetail ? plan.subtitle : nil)
                    .padding(.leading, Metrics.expandedPad + Metrics.avatar + 8)
                    .padding(.trailing, Metrics.expandedPad)
                    .padding(.bottom, Metrics.expandedPad)
                    .transition(.opacity)
            }
        }
        .contentShape(.rect(cornerRadius: Metrics.radius))
        .glassEffect(glass, in: .rect(cornerRadius: Metrics.radius))
        .onHover { inside in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { isHovered = inside }
        }
        .opacity(model.isSwitching && isActive == false ? 0.5 : 1)
        .animation(Motion.expand, value: isExpanded)
        .contextMenu(if: plan.menu.isEmpty == false) { rowMenu }
    }

    /// What this row shows right now (decided in Core, where it is tested).
    private var plan: RowPlan { model.rowPlan(for: account) }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Avatar(account: account, ring: model.usage[account.id]?.fiveHour,
                   needsRefresh: model.usage[account.id]?.needsRefresh == true)
            if account.needsLabel == true {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isNaming)
                    .onSubmit { model.setLabel(account.id, name) }
                    .onAppear { isNaming = isDemo == false }
            } else if plan.showsWindowIcon || nameSubtitle != nil {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        labelText
                        if plan.showsWindowIcon {
                            Image(systemName: "macwindow")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    if let nameSubtitle {
                        SubtitleLine(text: nameSubtitle)
                    }
                }
            } else {
                labelText
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, isExpanded ? Metrics.expandedPad : Metrics.rowH)
        .rowFrame(growing: nameSubtitle != nil)
        // Expanded: ~10 pt above the avatar ring (the 30 pt row already leaves 3 pt).
        .padding(.top, isExpanded ? Metrics.expandedPad - 3 : 0)
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(Motion.expand) { model.tap(account) }
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(plan.isOpenSomewhere ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(account.label)
        .accessibilityHint(isExpanded ? "Collapses" : "Shows usage")
        .accessibilityAction { model.tap(account) }
    }

    private var isActive: Bool { model.activeAccountID == account.id }
    private var isExpanded: Bool { model.expandedID == account.id }
    private var glass: Glass {
        if isExpanded { return .clear.tint(Color.primary.opacity(0.06)) }
        let hot = isHovered && model.isSwitching == false && account.needsLabel != true
        return hot ? .regular.interactive() : .identity
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: plan.usesMiniButtons ? 4 : 6) {
            if plan.showsSpinner {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else if plan.usesMiniButtons {
                ForEach(plan.buttons, id: \.self) { miniButton($0) }
                checkmark
            } else if plan.buttons.isEmpty == false {
                Button(switchTitle) { model.confirmSwitch(account) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(model.isSwitching)
                    .help("Quits and reopens Claude")
                    .transition(.opacity)
            } else {
                switch model.health(account) {
                case .expiringSoon(let d):
                    Text("\(d)d")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.orange)
                case .expired:
                    Button("Expired") { model.signInAgain(account) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .help("Sign In Again")
                default:
                    EmptyView()
                }
                checkmark
            }
        }
    }

    /// Shown for every account that is open somewhere: the main window's and each extra window's.
    @ViewBuilder private var checkmark: some View {
        if plan.showsCheckmark {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)
        }
    }

    /// The subtitle under the name; a row with buttons keeps it in the expanded part instead.
    private var nameSubtitle: String? { plan.isSubtitleInDetail ? nil : plan.subtitle }

    private var labelText: some View {
        Text(account.label)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// A mini button: tight padding, one line, never wraps the row.
    private func miniButton(_ action: RowAction) -> some View {
        Button(title(action)) { perform(action) }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .disabled(model.isSwitching)
            .help(help(action))
            .transition(.opacity)
    }

    /// Right-click: the same actions as the buttons, with or without expanding the row.
    @ViewBuilder private var rowMenu: some View {
        ForEach(plan.menu, id: \.self) { action in
            Button(title(action)) { perform(action) }
        }
    }

    private func title(_ action: RowAction) -> String {
        switch action {
        case .switchTo: switchTitle
        case .open: PanelCopy.openButton
        case .show: PanelCopy.showButton
        case .close: PanelCopy.closeButton
        }
    }

    private func help(_ action: RowAction) -> String {
        switch action {
        case .switchTo: "Quits and reopens Claude"
        case .open: "Opens this account next to your main window"
        case .show: "Brings this window to the front"
        case .close: "Closes only this window"
        }
    }

    private func perform(_ action: RowAction) {
        switch action {
        case .switchTo: model.confirmSwitch(account)
        case .open: model.openWindow(account)
        case .show: model.showWindow(account.id)
        case .close: model.closeWindow(account.id)
        }
    }

    private var switchTitle: String {
        account.desktop == nil || model.health(account) == .expired ? "Sign In" : "Switch"
    }

    private var helpText: String {
        switch model.health(account) {
        case .ok(let d), .expiringSoon(let d): "Login expires in \(d) days"
        case .expired: "Login expired. Click to sign in again"
        case .unknown: ""
        }
    }
}

extension View {
    /// A row is a fixed 30 pt, or taller when it carries a subtitle.
    @ViewBuilder func rowFrame(growing: Bool) -> some View {
        if growing { frame(minHeight: Metrics.rowHeight) } else { frame(height: Metrics.rowHeight) }
    }

    /// A right-click menu only when `isOn`; otherwise the view has no menu at all.
    @ViewBuilder func contextMenu<M: View>(if isOn: Bool, @ViewBuilder _ items: () -> M) -> some View {
        if isOn { contextMenu { items() } } else { self }
    }
}

/// A row's second line: "Main window" or "Open in its own window".
struct SubtitleLine: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// The expanded part of a row: one 11 pt line per usage window.
struct ExpandedUsage: View {
    var account: Account
    var model: AppModel
    /// "Open in its own window", when the row's buttons leave no room for it beside the name.
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subtitle { SubtitleLine(text: subtitle) }
            let u = model.usage[account.id]
            if u?.needsRefresh == true {
                Text("Open to Refresh")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Switching to this account refreshes its token")
            } else if u == nil {
                Text(model.showUsage ? "No Usage Data" : "Usage Off")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 0)
    }
}

/// `5h ━━━━━────── 18% · 11:45 AM`
struct UsageLine: View {
    var label: String
    var window: UsageWindow
    var weekly: Bool
    /// For the 5h line only: a short "2h ago" when the data is stale.
    var stale: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 30, alignment: .leading)
            UsageBar(utilization: window.utilization)
                .frame(height: 6)
                .opacity(window.stale ? 0.5 : 1)
            Text(value)
                .contentTransition(.numericText())
                .frame(width: 86, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weekly ? "Week" : "5 hours"), \(value)")
    }

    private var value: String {
        let pct = "\(Int((window.utilization * 100).rounded()))%"
        var parts = [pct]
        if let r = window.resetsAt {
            parts.append(weekly ? r.formatted(.dateTime.weekday(.abbreviated)) : r.formatted(date: .omitted, time: .shortened))
        }
        if let stale { parts.append(stale) }
        return parts.joined(separator: " · ")
    }
}

/// The always-visible usage under an account's name: 5h and Week bars.
struct UsageBars: View {
    var usage: AccountUsage
    var stale: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let w = usage.fiveHour { UsageLine(label: "5h", window: w, weekly: false, stale: stale) }
            if let w = usage.weekly { UsageLine(label: "Week", window: w, weekly: true, stale: nil) }
        }
    }
}

/// Green → yellow → orange → red as usage climbs.
func usageColor(_ u: Double) -> Color {
    switch u {
    case ..<0.5: .green
    case ..<0.8: .yellow
    case ..<0.95: .orange
    default: .red
    }
}

/// A capsule that fills from empty on appear, springs to new values, and carries a slow shimmer.
struct UsageBar: View {
    var utilization: Double
    var shimmerDelay: Double = 0
    @State private var shown: Double = 0
    @State private var phase: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let u = min(1, max(0, utilization))
            let w = max(6, geo.size.width * shown)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [usageColor(u).opacity(0.75), usageColor(u)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w)
                    .overlay {
                        if reduceMotion == false {
                            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: w * 0.35)
                                .offset(x: phase * w)
                                .blendMode(.plusLighter)
                        }
                    }
                    .clipShape(Capsule())
                    .shadow(color: usageColor(u).opacity(0.5), radius: 3)
            }
        }
        .onAppear {
            if reduceMotion { shown = utilization; return }
            withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(0.05)) { shown = utilization }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false).delay(shimmerDelay)) { phase = 1.1 }
        }
        .onChange(of: utilization) { _, v in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.2)) { shown = v }
        }
    }
}

func levelColor(_ l: UsageLevel) -> Color {
    switch l {
    case .normal: Color.primary.opacity(0.55)
    case .high: .orange
    case .critical: .red
    }
}

/// The inline row for Add Account…
struct AddRow: View {
    var model: AppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.avatar, height: Metrics.avatar)
                .background(.quaternary, in: .circle)
            TextField("Name", text: Binding(get: { model.addDraft.name }, set: { model.addDraft.name = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit { model.submitAdd() }
                .onExitCommand { model.cancelAddDraft() }
            Spacer(minLength: 0)
            Button { model.cancelAddDraft() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel adding an account")
        }
        .padding(.horizontal, Metrics.rowH)
        .frame(height: Metrics.rowHeight)
        .onAppear { isFocused = isDemo == false }
        .help("Claude reopens at its sign-in screen. Sign in once. Never press Sign Out")
    }
}

struct Avatar: View {
    var account: Account
    /// The 5-hour window, drawn as a thin ring inside the same 24 pt footprint. No data, no ring;
    /// the 18 pt circle stays put either way.
    var ring: UsageWindow? = nil
    var needsRefresh: Bool = false

    static let inner: CGFloat = 18
    static let ringWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Text(String(account.initials.prefix(1)))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(accountTint(account))
                .frame(width: Self.inner, height: Self.inner)
                .background(accountTint(account).opacity(0.18), in: .circle)
            if needsRefresh {
                Circle()
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: Self.ringWidth))
                    .padding(Self.ringWidth / 2)
            } else if let ring {
                // 18 pt circle + 1.5 pt gap + 1.5 pt ring = 24 pt.
                Circle()
                    .trim(from: 0, to: max(0.02, ring.utilization))
                    .stroke(levelColor(ring.level), style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.ringWidth / 2)
                    .opacity(ring.stale ? 0.45 : 1)
            }
        }
        .frame(width: Metrics.avatar, height: Metrics.avatar)
        .accessibilityHidden(true)
    }
}

/// A few words and at most one action.
struct StatusLineView: View {
    var model: AppModel
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(isProblem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                // A confirmation (the sign-in note plus running chats) is the one line allowed to grow.
                .lineLimit(model.line?.isConfirmation == true ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail)
            Spacer(minLength: 4)
            if let (title, action) = actionButton {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
                    .fixedSize()
            }
            if showsClose {
                Button { model.dismissLine() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }

    /// Errors with their own action (Roll Back, Restore Backup, Retry) also get a small ×.
    private var showsClose: Bool {
        guard model.isSwitching == false else { return false }
        switch model.line {
        case .notConfirmed, .failed, .interrupted, .keychainDenied, .confirmWindowSignIn: return true
        default: return false
        }
    }

    private var isProblem: Bool { model.isSwitching == false && model.line?.isProblem == true }

    private var detail: String {
        switch model.line {
        case .interrupted(_, let d), .chrome(let d): d
        case .error(_, let d): d
        case .confirmRestartChrome: "Tabs reopen only if Chrome's “Continue where you left off” is on"
        case .chromeTabsWarning: "Chrome restarts with Claude. Turn on “Continue where you left off” in Chrome to keep tabs"
        case .chromeSignIn: "Chrome reopened on claude.ai/login for this account; sign in once, it's saved from then on"
        case .confirmWindowSignIn: "Claude's sign-in comes back through a link that opens in your first Claude window, so the main window closes while you sign in"
        default: ""
        }
    }

    private var actionButton: (String, () -> Void)? {
        if model.isSwitching {
            return model.canCancelAction ? ("Cancel", { model.cancelSwitch() }) : nil
        }
        switch model.line {
        case .notConfirmed(let id), .failed(let id): return ("Roll Back", { model.rollback(id) })
        case .interrupted(let id, _): return ("Restore Backup", { model.rollback(id) })
        case .signedInAsKnown, .waitingForSignIn: return ("Cancel", { model.cancelAdd() })
        case .chrome, .error: return ("OK", { model.dismissLine() })
        case .info: return nil
        case .keychainDenied: return ("Retry", { model.retryKeychain() })
        case .chromePending: return ("Restart", { model.line = .confirmRestartChrome })
        case .confirmRestartChrome: return ("Restart", { model.restartChromeNow() })
        case .chromeSignIn: return nil
        case .chromeTabsWarning(let target): return ("Switch Anyway", { model.startSwitch(target) })
        case .confirmWindowSignIn(let id): return (PanelCopy.continueTitle, { model.continueWindowSignIn(id) })
        case nil: return nil
        }
    }
}

/// A menu-style item with the same highlight as account rows.
struct MenuItem: View {
    var title: String
    var symbol: String?
    var help: String
    var action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String? = nil, help: String = "", action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 4)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, Metrics.rowH)
        .frame(height: Metrics.itemHeight)
        .contentShape(.rect(cornerRadius: Metrics.radius))
        .glassEffect(isHovered && isEnabled ? .regular.interactive() : .identity, in: .rect(cornerRadius: Metrics.radius))
        .onHover { inside in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { isHovered = inside }
        }
        .onTapGesture { if isEnabled { action() } }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

private struct HostBackground: ViewModifier {
    var host: PanelHost
    func body(content: Content) -> some View {
        switch host {
        case .menuBarExtra: content
        case .panel: content.glassEffect(.regular, in: .rect(cornerRadius: Metrics.panelRadius))
        }
    }
}
