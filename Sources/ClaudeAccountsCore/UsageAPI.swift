import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPGuardError: Error, Equatable { case hostNotAllowed, redirectRefused }

/// A session that never writes the bearer to disk: ephemeral, no URL cache, no cookies, no
/// cached responses, redirects refused, and only `https://api.anthropic.com` is reachable.
public final class SecureHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    public static let allowedHost = "api.anthropic.com"
    public let session: URLSession

    public static func makeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.httpCookieAcceptPolicy = .never
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 20
        return c
    }

    public override init() {
        let config = Self.makeConfiguration()
        // The session holds the delegate strongly; break the cycle by using a proxy.
        let proxy = RedirectRefuser()
        self.session = URLSession(configuration: config, delegate: proxy, delegateQueue: nil)
        super.init()
    }

    /// Only https to the allowed host.
    public static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == allowedHost
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard Self.isAllowed(request.url) else { throw HTTPGuardError.hostNotAllowed }
        var r = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        r.httpShouldHandleCookies = false
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        let http = response as? HTTPURLResponse
        // A redirect that slipped through would land on another URL; reject it.
        if let final = http?.url, Self.isAllowed(final) == false { throw HTTPGuardError.redirectRefused }
        var headers: [String: String] = [:]
        for (k, v) in (http?.allHeaderFields ?? [:]) {
            if let ks = k as? String, let vs = v as? String { headers[ks.lowercased()] = vs }
        }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

/// Refuses every redirect, so the bearer is never forwarded to another URL.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// `GET https://api.anthropic.com/api/oauth/usage` with the oauth bearer and beta header.
public enum UsageAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "ClaudeAccounts/1.0"

    public static func request(bearer: String) -> HTTPRequest {
        HTTPRequest(url: endpoint, headers: [
            "Authorization": "Bearer \(bearer)",
            "anthropic-beta": betaHeader,
            "User-Agent": userAgent,
            "Accept": "application/json",
        ])
    }

    /// Reads `five_hour` and `seven_day` (`utilization`, `resets_at`), ignoring the rest. Returns
    /// nil when the body isn't a usage object (so the caller keeps its previous good values).
    ///
    /// `utilization` is a 0–100 percent. Evidence from Claude.app 2.26454.0's asar
    /// (index.chunk-BQ6X9i-D.js): the desktop app renders it as
    /// `percentUsed: Tl(t.utilization)` with `function Tl(e){return Math.max(0,Math.min(100,Math.floor(e)))}`,
    /// i.e. clamped to 0–100 and floored with no ×100. So we divide by 100, with no 0–1 heuristic.
    public static func parse(_ body: Data, now: Date) -> AccountUsage? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let five = window(obj["five_hour"], now: now)
        let week = window(obj["seven_day"], now: now)
        guard five != nil || week != nil else { return nil }
        return AccountUsage(fiveHour: five, weekly: week)
    }

    static func window(_ any: Any?, now: Date) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        let raw = (d["utilization"] as? Double) ?? (d["utilization"] as? Int).map(Double.init)
        guard let raw else { return nil }
        let resets = (d["resets_at"] as? String).flatMap(parseDate)
        return UsageWindow(utilization: raw / 100, resetsAt: resets, fetchedAt: now)
    }

    /// ISO 8601 with fractional seconds, falling back to plain ISO 8601.
    public static func parseDate(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
