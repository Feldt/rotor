import Foundation

/// Pure rules for when and how Chrome follows a switch.
public enum ChromeFollow {
    public static let loginURL = URL(string: "https://claude.ai/login")!
    public static let quitTimeout: Double = 20

    /// The plan for a switch: nothing until Switch Chrome is on and its account is confirmed.
    public static func plan(_ state: StoreState) -> ChromePlan {
        guard state.chromeFollows, state.chromeAttributionConfirmed == true else { return .skip }
        switch state.chromeMode ?? .withClaude {
        case .withClaude: return .withClaude
        case .whenChromeQuits: return .whenNextQuits
        }
    }

    /// "Chrome tabs won't reopen": only when Chrome will be restarted and doesn't restore tabs.
    public static func tabsWarning(plan: ChromePlan, isChromeRunning: Bool, restoresTabs: Bool) -> Bool {
        plan == .withClaude && isChromeRunning && restoresTabs == false
    }

    /// First enable: the advisory guess for "Chrome is signed in as", if it names a known account.
    public static func guess(paths: Paths, accounts: [Account]) -> String? {
        guard let id = ExtensionSettings.accountUuid(in: paths.chromeExtensionSettings),
              accounts.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
