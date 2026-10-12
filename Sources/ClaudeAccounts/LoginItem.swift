import ClaudeAccountsCore
import Foundation
import ServiceManagement

/// Open at Login via SMAppService (shows in System Settings → General → Login Items), with the
/// LaunchAgent as a fallback if registration throws.
@MainActor enum LoginItem {
    /// Only the installed copy may register; demo and build-folder binaries never do.
    static var isInstalledCopy: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_ACCOUNTS_DEMO_STATE"] == nil
            && Updater.samePath(Bundle.main.bundleURL.path(percentEncoded: false),
                                Updater.installedPath.path(percentEncoded: false))
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || LoginAgent.isInstalled
    }

    static func set(_ on: Bool) throws {
        if on {
            do {
                try SMAppService.mainApp.register()
            } catch {
                try LoginAgent.install(executable: Bundle.main.executablePath ?? "")
            }
        } else {
            try? SMAppService.mainApp.unregister()
            if LoginAgent.isInstalled { try LoginAgent.uninstall() }
        }
    }

    /// First launch of this version: turn it on once (by design) and remember that.
    static func enableOnceByDefault(store: AccountStore) {
        guard isInstalledCopy, store.state().loginItemDefaulted != true else { return }
        do {
            if isEnabled == false { try set(true) }
            try store.updateState { $0.loginItemDefaulted = true }
            store.log("open at login: enabled by default")
        } catch {
            store.log("open at login: couldn't enable (\(error))")
        }
    }
}
