import AppKit
import ClaudeAccountsCore
import SwiftUI

enum FolderMotion {
    static let fan = Animation.spring(duration: 0.42, bounce: 0.18)
    static let fold = Animation.spring(duration: 0.34, bounce: 0.05)
}

/// The accounts as a drawer of file folders. Stacked, each folder shows its tab (the name) and a
/// strip with its 5h and week meters; the front folder (the current account) shows everything.
/// Spread (pointer over the panel), every folder opens fully with its reset times and buttons.
struct FolderStack: View {
    var model: AppModel
    var spread: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let tabH: CGFloat = 20
    static let stripH: CGFloat = 26
    static let detailH: CGFloat = 30
    static let cardH: CGFloat = tabH + stripH + detailH + 4
    /// How far each folder sits below the one behind it.
    static let stackedStep: CGFloat = tabH + stripH + 2
    static let spreadStep: CGFloat = cardH + 6

    /// Back to front: the current account is the front folder.
    private var ordered: [Account] {
        let others = model.accounts.filter { $0.id != model.currentID }
        return others + model.accounts.filter { $0.id == model.currentID }
    }

    var body: some View {
        let items = ordered
        let step = spread ? Self.spreadStep : Self.stackedStep
        ZStack(alignment: .top) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                FolderCard(account: a, model: model, index: i,
                           isOpen: spread || i == items.count - 1)
                    .offset(y: CGFloat(i) * step)
                    .zIndex(Double(i))
                    .animation(reduceMotion ? nil : (spread ? FolderMotion.fan : FolderMotion.fold)
                        .delay(Double(spread ? i : items.count - 1 - i) * 0.025), value: spread)
            }
        }
        .frame(height: items.isEmpty ? 0 : CGFloat(items.count - 1) * step + Self.cardH, alignment: .top)
        .padding(.horizontal, 3)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15), value: items.map(\.id))
    }
}

struct FolderCard: View {
    var account: Account
    var model: AppModel
    var index: Int
    /// Fully visible: spread, or the front folder.
    var isOpen: Bool
    @State private var isHovered = false
    @State private var name = ""
    @FocusState private var isNaming: Bool

    static let tabW: CGFloat = 150
    /// Tabs step across like a real drawer of folders.
    private var tabX: CGFloat { 10 + CGFloat(index % 3) * 56 }
    private var tint: Color { accountTint(account) }
    private var isCurrent: Bool { account.id == model.currentID }
    private var usage: AccountUsage? { model.usage[account.id] }
    private var plan: RowPlan { model.rowPlan(for: account, expanded: isOpen) }
    private var shape: FolderShape { FolderShape(tabX: tabX, tabW: Self.tabW, tabH: FolderStack.tabH) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tab
            strip
                .frame(height: FolderStack.stripH)
                .padding(.horizontal, 12)
            detail
                .frame(height: FolderStack.detailH)
                .padding(.horizontal, 12)
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: FolderStack.cardH, alignment: .top)
        .background {
            ZStack {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                shape.fill(LinearGradient(colors: [tint.opacity(isHovered ? 0.42 : 0.34), tint.opacity(0.16)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: .black.opacity(0.22), radius: 5, y: -1)
        }
        .overlay { shape.stroke(tint.opacity(0.55), lineWidth: 0.75) }
        .contentShape(shape)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { isHovered = inside } }
        .opacity(model.isSwitching && model.activeAccountID != account.id ? 0.55 : 1)
        .contextMenu(if: plan.menu.isEmpty == false) {
            ForEach(plan.menu, id: \.self) { action in Button(title(action)) { perform(action) } }
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Tab

    private var tab: some View {
        HStack(spacing: 5) {
            if isCurrent {
                Circle().fill(tint).frame(width: 6, height: 6)
                    .shadow(color: tint.opacity(0.8), radius: 2)
                    .accessibilityHidden(true)
            }
            Text(account.needsLabel == true ? "New account" : account.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if plan.showsWindowIcon {
                Image(systemName: "macwindow").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: Self.tabW, height: FolderStack.tabH, alignment: .leading)
        .padding(.leading, tabX)
    }

    // MARK: Strip (always visible)

    @ViewBuilder private var strip: some View {
        if account.needsLabel == true {
            TextField("Name this account", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isNaming)
                .onSubmit { model.setLabel(account.id, name) }
                .onAppear { isNaming = isDemo == false }
        } else if let u = usage, u.needsRefresh == false, u.fiveHour != nil || u.weekly != nil {
            HStack(spacing: 12) {
                Meter(label: "5h", window: u.fiveHour, delay: Double(index) * 0.35)
                Meter(label: "Week", window: u.weekly, delay: Double(index) * 0.35 + 0.6)
            }
        } else {
            HStack {
                Text(noDataText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var noDataText: String {
        if model.showUsage == false { return "Usage off" }
        if usage?.needsRefresh == true { return "Switch to it once to refresh usage" }
        return "Usage loading…"
    }

    // MARK: Detail (open folders only)

    private var detail: some View {
        HStack(spacing: 6) {
            Text(resetText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing
        }
    }

    private var resetText: String {
        var parts: [String] = []
        if let r = usage?.fiveHour?.resetsAt { parts.append("Resets \(r.formatted(date: .omitted, time: .shortened))") }
        if let r = usage?.weekly?.resetsAt { parts.append("week \(r.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") }
        if let stale = model.staleAge(account.id) { parts.append(stale) }
        if parts.isEmpty, isCurrent { return "In Claude now" }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 4) {
            if plan.showsSpinner {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else if plan.buttons.isEmpty == false {
                ForEach(plan.buttons, id: \.self) { action in
                    Button(title(action)) { perform(action) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(plan.usesMiniButtons ? .mini : .small)
                        .font(.system(size: plan.usesMiniButtons ? 10 : 11, weight: .medium))
                        .fixedSize()
                        .disabled(model.isSwitching)
                }
            } else {
                switch model.health(account) {
                case .expiringSoon(let d):
                    Text("\(d)d").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.orange)
                case .expired:
                    Button("Sign In") { model.signInAgain(account) }
                        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                        .font(.system(size: 11, weight: .medium))
                default:
                    EmptyView()
                }
            }
            if plan.showsCheckmark {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).frame(width: 14)
            }
        }
    }

    private func title(_ action: RowAction) -> String {
        switch action {
        case .switchTo: account.desktop == nil || model.health(account) == .expired ? "Sign In" : "Switch"
        case .open: PanelCopy.openButton
        case .show: PanelCopy.showButton
        case .close: PanelCopy.closeButton
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

    private var helpText: String {
        switch model.health(account) {
        case .ok(let d), .expiringSoon(let d): "Login expires in \(d) days"
        case .expired: "Login expired. Sign in again"
        case .unknown: ""
        }
    }

    private var accessibilityText: String {
        var parts = [account.label]
        if isCurrent { parts.append("current") }
        if let w = usage?.fiveHour { parts.append("5 hours \(Int((w.utilization * 100).rounded())) percent") }
        if let w = usage?.weekly { parts.append("week \(Int((w.utilization * 100).rounded())) percent") }
        return parts.joined(separator: ", ")
    }
}

/// `5h ▰▰▰▱▱ 47%`, colored by level.
private struct Meter: View {
    var label: String
    var window: UsageWindow?
    var delay: Double

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            if let window {
                UsageBar(utilization: window.utilization, shimmerDelay: delay)
                    .frame(height: 6)
                    .opacity(window.stale ? 0.5 : 1)
                Text("\(Int((window.utilization * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(usageColor(window.utilization))
                    .contentTransition(.numericText())
                    .frame(width: 32, alignment: .trailing)
            } else {
                Capsule().fill(.quaternary).frame(height: 6)
                Text("–").font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            }
        }
    }
}

/// A folder: a body with a tab rising from its top edge, every corner rounded.
struct FolderShape: Shape {
    var tabX: CGFloat
    var tabW: CGFloat
    var tabH: CGFloat
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + tabH
        let x0 = rect.minX + tabX
        let slant: CGFloat = 7
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.maxY), radius),
            (CGPoint(x: rect.minX, y: top), radius),
            (CGPoint(x: x0, y: top), 4),
            (CGPoint(x: x0 + slant, y: rect.minY), 6),
            (CGPoint(x: x0 + tabW - slant, y: rect.minY), 6),
            (CGPoint(x: x0 + tabW, y: top), 4),
            (CGPoint(x: rect.maxX, y: top), radius),
            (CGPoint(x: rect.maxX, y: rect.maxY), radius),
        ]
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        for (i, (v, r)) in corners.enumerated() {
            p.addArc(tangent1End: v, tangent2End: corners[(i + 1) % corners.count].0, radius: r)
        }
        p.closeSubpath()
        return p
    }
}
