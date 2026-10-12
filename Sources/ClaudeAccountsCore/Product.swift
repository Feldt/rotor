import Foundation

/// What a person calls the app. Only visible names live here (menu bar, Settings, windows,
/// alerts, accessibility labels, CLI output, the installed bundle).
///
/// The app was called "Claude Accounts" until 2026-10-09. Everything macOS or the Keychain keys
/// on kept its old name on purpose, so renaming reset nothing: the bundle identifier, the data
/// folder, the LaunchAgent label, the defaults domain, the `CLAUDE_ACCOUNTS_*` variables and the
/// Swift module names. SPEC.md, "Naming", has the full list and the reasons.
public enum Product {
    /// The app's display name.
    public static let name = "Rotor"
    /// The installed bundle in `~/Applications`.
    public static let bundleName = "Rotor.app"
    /// The command line tool. `claude-accounts` stays installed beside it as an alias.
    public static let cli = "rotor"
}
