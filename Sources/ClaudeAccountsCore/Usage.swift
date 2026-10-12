import Foundation

/// One rate-limit window (5-hour or weekly) for an account.
public struct UsageWindow: Sendable, Equatable, Codable {
    /// 0–1.
    public var utilization: Double
    public var resetsAt: Date?
    public var fetchedAt: Date
    /// True when this came from a cache older than the provider trusts.
    public var stale: Bool

    public init(utilization: Double, resetsAt: Date?, fetchedAt: Date, stale: Bool = false) {
        self.utilization = min(max(utilization, 0), 1)
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
        self.stale = stale
    }

    public var level: UsageLevel { UsageLevel(utilization) }
}

public struct AccountUsage: Sendable, Equatable, Codable {
    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    /// The token is expired or the server returned 401/403: a switch (which refreshes) is needed.
    public var needsRefresh: Bool

    public init(fiveHour: UsageWindow?, weekly: UsageWindow?, needsRefresh: Bool = false) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.needsRefresh = needsRefresh
    }
}

public enum UsageLevel: Sendable, Equatable {
    case normal, high, critical

    /// Amber at 80 %, red at 95 %.
    public init(_ utilization: Double) {
        self = utilization >= 0.95 ? .critical : utilization >= 0.8 ? .high : .normal
    }
}

/// Where per-account usage comes from. The real source is still being researched; until then the
/// app uses `NoUsageProvider` (no rings, no bars) and the demo uses `FakeUsageProvider`.
public protocol UsageProvider: Sendable {
    func usage(for accountID: String) async -> AccountUsage?
}

/// A cached usage record per account, in `usage.json`. Not secret: numbers and timestamps only.
public struct StoredUsage: Sendable, Equatable, Codable {
    public var usage: AccountUsage
    public var fetchedAt: Date
    public var stale: Bool
    /// Back off refreshing this account until here (429).
    public var retryUntil: Date?
    /// When the last attempt (any outcome) was made; scheduling is by attempt, not by fetch.
    public var lastAttemptAt: Date?
    /// Consecutive soft failures (5xx, network, missing token, unparseable 200), for backoff.
    public var failures: Int
    /// When `needsRefresh` was set: whether the account was current, and its slot blob stamp.
    public var refreshMarkedCurrent: Bool?
    public var refreshMarkedStamp: String?
    public var refreshMarkedLiveStamp: String?
    /// The app build (commit) that recorded this backoff state.
    public var commit: String?

    public init(usage: AccountUsage, fetchedAt: Date, stale: Bool = false, retryUntil: Date? = nil,
                lastAttemptAt: Date? = nil, failures: Int = 0) {
        self.usage = usage
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.retryUntil = retryUntil
        self.lastAttemptAt = lastAttemptAt
        self.failures = failures
    }

    public func age(_ now: Date) -> TimeInterval { now.timeIntervalSince(fetchedAt) }
}

public struct NoUsageProvider: UsageProvider {
    public init() {}
    public func usage(for accountID: String) async -> AccountUsage? { nil }
}

/// Deterministic made-up numbers per account, for screenshots and UI work only.
public struct FakeUsageProvider: UsageProvider {
    public var now: Date
    public init(now: Date = Date()) { self.now = now }

    public func usage(for accountID: String) async -> AccountUsage? {
        let seed = accountID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let five = [0.42, 0.83, 0.97, 0.18, 0.64][seed % 5]
        let week = [0.61, 0.35, 0.88, 0.12, 0.5][(seed / 5) % 5]
        return AccountUsage(
            fiveHour: UsageWindow(utilization: five, resetsAt: now.addingTimeInterval(Double(1 + seed % 4) * 3600 + 1800), fetchedAt: now),
            weekly: UsageWindow(utilization: week, resetsAt: now.addingTimeInterval(Double(1 + seed % 6) * 86_400), fetchedAt: now))
    }
}
