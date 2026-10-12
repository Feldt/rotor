import Foundation
import Synchronization

/// Where a usable bearer token for an account comes from.
public protocol UsageTokenSource: Sendable {
    func token(accountID: String, now: Date) -> TokenCache.Selection
    /// Whether `accountID` is the live account right now.
    func isCurrent(_ accountID: String) -> Bool
    /// A non-secret stamp of the account's saved token blob (size+mtime), to notice when it changes.
    func blobStamp(_ accountID: String) -> String?
    /// A non-secret stamp of the live config.json (mtime): Claude re-mints the live token by itself.
    func liveConfigStamp() -> String?
}

public extension UsageTokenSource {
    func isCurrent(_ accountID: String) -> Bool { false }
    func blobStamp(_ accountID: String) -> String? { nil }
    func liveConfigStamp() -> String? { nil }
}

/// Reads and decrypts Claude's oauth cache. Holds the derived key for the process lifetime only.
/// A Keychain denial is cached for the process: no re-prompt until `retryKeychain()`.
public final class KeychainTokenSource: UsageTokenSource, @unchecked Sendable {
    let paths: Paths
    let password: SafeStoragePassword
    let currentAccount: @Sendable () -> String?
    let isAddInProgress: @Sendable () -> Bool
    private let keyBox = Mutex<Data?>(nil)
    /// A cached Keychain failure (denied or missing), so ticks and panel opens never re-prompt.
    private let keyFailure = Mutex<TokenFailure?>(nil)

    public init(paths: Paths, password: SafeStoragePassword = KeychainPassword(),
                currentAccount: @escaping @Sendable () -> String?,
                isAddInProgress: @escaping @Sendable () -> Bool = { false }) {
        self.paths = paths
        self.password = password
        self.currentAccount = currentAccount
        self.isAddInProgress = isAddInProgress
    }

    public var isKeychainDenied: Bool { keyFailure.withLock { $0 } == .keychainDenied }

    /// Settings → Retry Keychain Access: allow one more prompt.
    public func retryKeychain() { keyFailure.withLock { $0 = nil } }

    func key() -> Result<Data, TokenFailure> {
        if let f = keyFailure.withLock({ $0 }) { return .failure(f) }
        return keyBox.withLock { stored -> Result<Data, TokenFailure> in
            if let stored { return .success(stored) }
            do {
                let pw = try password.password()
                let k = OSCrypt.deriveKey(password: pw)
                stored = k
                return .success(k)
            } catch KeychainError.missing {
                keyFailure.withLock { $0 = .keychainMissing }
                return .failure(.keychainMissing)
            } catch {
                keyFailure.withLock { $0 = .keychainDenied }
                return .failure(.keychainDenied)
            }
        }
    }

    public func isCurrent(_ accountID: String) -> Bool { currentAccount() == accountID }

    public func blobStamp(_ accountID: String) -> String? {
        let url = paths.slotOAuthCache(accountID)
        guard let size = FileOps.size(url), let mod = FileOps.modified(url) else { return nil }
        return "\(size)-\(Int(mod.timeIntervalSince1970))"
    }

    public func liveConfigStamp() -> String? {
        FileOps.modified(paths.liveConfig).map { String($0.timeIntervalSince1970) }
    }

    func encryptedCache(for accountID: String) -> String? {
        if currentAccount() == accountID {
            // During an add, the live config is mid-transition; don't read it.
            if isAddInProgress() { return nil }
            return ClaudeConfig.encryptedOAuthCache(paths.liveConfig)
        }
        let slot = paths.slotOAuthCache(accountID)
        guard FileOps.exists(slot), let data = try? Data(contentsOf: slot) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func token(accountID: String, now: Date) -> TokenCache.Selection {
        // Read the blob first: no blob, no Keychain prompt.
        guard let blob = encryptedCache(for: accountID) else { return .failed(.noCache) }
        let key: Data
        switch self.key() {
        case .failure(let f): return .failed(f)
        case .success(let k): key = k
        }
        // The app stores `encryptString(...).toString("base64")`: base64 of a "v10…" blob.
        guard let raw = Data(base64Encoded: blob.trimmingCharacters(in: .whitespacesAndNewlines)),
              let decrypted = try? OSCrypt.decrypt(raw, key: key) else { return .failed(.decryptFailed) }
        return TokenCache.select(decrypted, accountUuid: accountID, now: now)
    }
}

/// Fetches, caches and schedules per-account usage. Never writes Claude's files, never refreshes
/// tokens. Scheduling is by attempt with per-account exponential backoff; `needsRefresh` accounts
/// are left alone until a switch makes them current or their slot blob changes.
public final class UsageService: UsageProvider, @unchecked Sendable {
    public struct Config: Sendable {
        public var interval: TimeInterval = 15 * 60
        public var panelFresh: TimeInterval = 5 * 60
        public var panelRoundEvery: TimeInterval = 5 * 60
        public var spacing: TimeInterval = 5
        public var defaultBackoff: TimeInterval = 30 * 60
        public var maxRetryAfter: TimeInterval = 24 * 3600
        public var maxBackoff: TimeInterval = 6 * 3600
        public init() {}
    }

    let paths: Paths
    let http: HTTPClient
    public let tokens: UsageTokenSource
    let ticker: Ticker
    let config: Config
    let log: @Sendable (String) -> Void
    private let state = Mutex<[String: StoredUsage]>([:])
    private let lastFetchAt = Mutex<Date?>(nil)
    private let queue = Mutex<[String]>([])
    private let lastPanelRound = Mutex<Date?>(nil)
    /// Accounts to attempt next regardless of backoff (launch), still spaced and 429-respecting.
    private let forced = Mutex<[String]>([])
    let buildCommit: String?
    static let tokenQueue = DispatchQueue(label: "claude-accounts.keychain", qos: .utility)

    public init(paths: Paths, http: HTTPClient, tokens: UsageTokenSource, ticker: Ticker = SystemTicker(),
                config: Config = Config(), buildCommit: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.http = http
        self.tokens = tokens
        self.ticker = ticker
        self.config = config
        self.buildCommit = buildCommit
        self.log = log
        var loaded = Self.load(paths.usageFile)
        // Backoff recorded by a different build doesn't carry over: its failures may be bugs since fixed.
        if let buildCommit {
            var reset = false
            for (id, var rec) in loaded where rec.commit != buildCommit {
                rec.failures = 0
                rec.lastAttemptAt = nil
                rec.commit = buildCommit
                loaded[id] = rec
                reset = true
            }
            state.withLock { $0 = loaded }
            if reset { persist() }
        } else {
            state.withLock { $0 = loaded }
        }
    }

    /// At launch: attempt this account once, ahead of any backoff, unless it's in a 429 window.
    public func queueLaunch(_ id: String?, now: Date) {
        guard let id else { return }
        if let until = stored(id)?.retryUntil, now < until { return }
        forced.withLock { if $0.contains(id) == false { $0.insert(id, at: 0) } }
    }

    // MARK: Cache I/O

    static func load(_ url: URL) -> [String: StoredUsage] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([String: StoredUsage].self, from: data)) ?? [:]
    }

    func persist() {
        let snapshot = state.withLock { $0 }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(snapshot) else { return }
        try? FileOps.ensureDirectory(paths.storeRoot)
        try? FileOps.writeAtomically(data, to: paths.usageFile)
    }

    public func stored(_ id: String) -> StoredUsage? { state.withLock { $0[id] } }
    public func cachedSnapshot() -> [String: StoredUsage] { state.withLock { $0 } }

    public func usage(for accountID: String) async -> AccountUsage? {
        guard var s = stored(accountID) else { return nil }
        s.usage.fiveHour?.stale = s.stale
        s.usage.weekly?.stale = s.stale
        return s.usage
    }

    private func update(_ id: String, now: Date, _ body: (inout StoredUsage) -> Void) {
        state.withLock { s in
            var cur = s[id] ?? StoredUsage(usage: AccountUsage(fiveHour: nil, weekly: nil), fetchedAt: .distantPast)
            body(&cur)
            cur.commit = buildCommit ?? cur.commit
            s[id] = cur
        }
        persist()
    }

    // MARK: Refresh

    @discardableResult
    public func refresh(_ accountID: String) async -> RefreshResult {
        let now = ticker.now()
        lastFetchAt.withLock { $0 = now }
        update(accountID, now: now) { $0.lastAttemptAt = now }
        // Token reads may block on a Keychain prompt: run them on a dedicated serial queue so they
        // never tie up Swift's cooperative pool (which the switch's verify and everything else share).
        let tokens = self.tokens
        let selection = await withCheckedContinuation { (c: CheckedContinuation<TokenCache.Selection, Never>) in
            Self.tokenQueue.async { c.resume(returning: tokens.token(accountID: accountID, now: now)) }
        }
        switch selection {
        case .failed(let reason):
            softFailure(accountID, now: now)
            log("usage \(accountID): no token (\(reason))")
            return .noToken(reason)
        case .expired(let minutes):
            markNeedsRefresh(accountID, now: now)
            log("usage \(accountID): token expired \(minutes) min ago; needs refresh")
            return .needsRefresh
        case .token(let bearer, _):
            do {
                let response = try await http.send(UsageAPI.request(bearer: bearer))
                return apply(response, for: accountID, now: now)
            } catch {
                softFailure(accountID, now: now)
                log("usage \(accountID): network error; kept cache stale")
                return .networkError
            }
        }
    }

    func apply(_ response: HTTPResponse, for id: String, now: Date) -> RefreshResult {
        switch response.status {
        case 200:
            guard let usage = UsageAPI.parse(response.body, now: now) else {
                // Unparseable 200: keep the previous good values, mark stale, back off.
                softFailure(id, now: now)
                log("usage \(id): 200 unparseable; kept cache stale")
                return .unparseable
            }
            update(id, now: now) { cur in
                cur.usage = usage
                cur.fetchedAt = now
                cur.stale = false
                cur.retryUntil = nil
                cur.failures = 0
                cur.refreshMarkedCurrent = nil
                cur.refreshMarkedStamp = nil
            }
            log("usage \(id): 200 at \(iso(now))")
            return .ok
        case 401, 403:
            markNeedsRefresh(id, now: now)
            log("usage \(id): \(response.status); needs refresh")
            return .needsRefresh
        case 429:
            let retry = retryAfter(response.headers["retry-after"], now: now)
            update(id, now: now) { $0.stale = true; $0.retryUntil = retry }
            log("usage \(id): 429; backing off until \(iso(retry))")
            return .rateLimited(until: retry)
        case 500...599:
            softFailure(id, now: now)
            log("usage \(id): \(response.status); backing off")
            return .httpError(response.status)
        default:
            softFailure(id, now: now)
            log("usage \(id): \(response.status); kept cache stale")
            return .httpError(response.status)
        }
    }

    func softFailure(_ id: String, now: Date) {
        update(id, now: now) { $0.stale = true; $0.failures += 1 }
    }

    func retryAfter(_ header: String?, now: Date) -> Date {
        if let header, let secs = Double(header.trimmingCharacters(in: .whitespaces)) {
            return now.addingTimeInterval(min(max(secs, 0), config.maxRetryAfter))
        }
        return now.addingTimeInterval(config.defaultBackoff)
    }

    func markNeedsRefresh(_ id: String, now: Date) {
        let current = tokens.isCurrent(id)
        let stamp = tokens.blobStamp(id)
        let live = tokens.liveConfigStamp()
        update(id, now: now) { cur in
            cur.usage.needsRefresh = true
            cur.stale = true
            cur.failures += 1
            cur.refreshMarkedCurrent = current
            cur.refreshMarkedStamp = stamp
            cur.refreshMarkedLiveStamp = live
        }
    }

    /// Exponential backoff after `failures` soft failures: 15, 30, 60 min … capped at 6 h.
    public func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return config.interval }
        let delay = config.interval * pow(2, Double(failures - 1))
        return min(delay, config.maxBackoff)
    }

    // MARK: Scheduling

    /// Whether `id` may be fetched at `now` (ignoring the global 5 s spacing).
    func eligible(_ id: String, _ s: StoredUsage?, now: Date) -> Bool {
        guard let s else { return true }
        if let until = s.retryUntil, now < until { return false }
        if s.usage.needsRefresh {
            if tokens.isCurrent(id) {
                // Claude re-mints the live token itself: retry at once when config.json changes,
                // otherwise on the normal per-account backoff below.
                if tokens.liveConfigStamp() != s.refreshMarkedLiveStamp { return true }
            } else {
                // Saved accounts: only once their slot blob changes (a switch saves a fresh one).
                if tokens.blobStamp(id) == s.refreshMarkedStamp { return false }
                return true
            }
        }
        guard let last = s.lastAttemptAt else { return true }
        return now.timeIntervalSince(last) >= backoff(failures: s.failures)
    }

    /// The next account to fetch at `now`, or nil. Queued (panel) accounts first, then the oldest
    /// due. Enforces 5 s spacing across all fetches.
    public func due(_ ids: [String], now: Date) -> String? {
        if let last = lastFetchAt.withLock({ $0 }), now.timeIntervalSince(last) < config.spacing { return nil }
        let snapshot = state.withLock { $0 }
        let launch = forced.withLock { q -> String? in
            while let first = q.first {
                q.removeFirst()
                if let until = snapshot[first]?.retryUntil, now < until { continue }
                if ids.contains(first) { return first }
            }
            return nil
        }
        if let launch { return launch }
        let queued = queue.withLock { q -> String? in
            while let first = q.first {
                q.removeFirst()
                if ids.contains(first), eligible(first, snapshot[first], now: now) { return first }
            }
            return nil
        }
        if let queued { return queued }
        let candidates = ids.filter { eligible($0, snapshot[$0], now: now) }
        return candidates.min { a, b in
            (snapshot[a]?.lastAttemptAt ?? .distantPast) < (snapshot[b]?.lastAttemptAt ?? .distantPast)
        }
    }

    /// A panel open queues accounts whose data is older than 5 min, at most one round per 5 min.
    /// Returns what was queued. Fetching still goes through `due` (spacing, backoff, needsRefresh).
    @discardableResult
    public func queuePanelRound(_ ids: [String], now: Date) -> [String] {
        let allowed = lastPanelRound.withLock { last -> Bool in
            if let last, now.timeIntervalSince(last) < config.panelRoundEvery { return false }
            last = now
            return true
        }
        guard allowed else { return [] }
        let snapshot = state.withLock { $0 }
        let stale = ids.filter { id in
            guard eligible(id, snapshot[id], now: now) else { return false }
            guard let s = snapshot[id] else { return true }
            return now.timeIntervalSince(s.fetchedAt) >= config.panelFresh
        }
        queue.withLock { q in for id in stale where q.contains(id) == false { q.append(id) } }
        return stale
    }

    func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

public enum RefreshResult: Sendable, Equatable {
    case ok, needsRefresh, networkError, unparseable
    case noToken(TokenFailure)
    case rateLimited(until: Date)
    case httpError(Int)
}

/// For the read-only CLI path: never produces a token (no Keychain access).
public struct NoTokenSource: UsageTokenSource {
    public init() {}
    public func token(accountID: String, now: Date) -> TokenCache.Selection { .failed(.noCache) }
}

/// Never sends anything; for read-only paths that must not touch the network.
public struct OfflineHTTPClient: HTTPClient {
    public init() {}
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw HTTPGuardError.hostNotAllowed }
}
