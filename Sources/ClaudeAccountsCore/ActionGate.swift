import Foundation
import Synchronization

/// One serial lock for every action that changes the main window or the extra windows: a switch, a
/// rollback, an add, opening or closing a window, a window's first sign-in, and the reopen after an
/// update. They all quit, launch or sign in Claude processes, so two of them at once can steal each
/// other's windows (a reopen launching a window while a switch has the main window half closed).
///
/// `run` queues first come, first served and runs when everything before it is done; a task cancelled
/// while it waits leaves the queue with `CancellationError`. `runIfIdle` is for background work that
/// must never queue behind or in front of something the person started: it runs only if nothing holds
/// the gate. A body must not call `run` again on the same gate (it would wait for itself); the engines
/// keep unlocked inner versions of every locked action for that.
public final class ActionGate: Sendable {
    private struct Waiter {
        var ticket: UInt64
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var isHeld = false
        var waiters: [Waiter] = []
        var lastTicket: UInt64 = 0
        /// Tickets whose task was cancelled before its continuation was queued.
        var cancelledEarly: Set<UInt64> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Something holds the gate.
    public var isBusy: Bool { state.withLock { $0.isHeld } }

    /// How many actions are queued behind the one that runs.
    public var waitingCount: Int { state.withLock { $0.waiters.count } }

    /// Runs `body` once every earlier action is done.
    public func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    /// Runs `body` only if the gate is free right now; nil when something holds it.
    public func runIfIdle<T: Sendable>(_ body: () async -> T) async -> T? {
        let isFree = state.withLock { s -> Bool in
            if s.isHeld { return false }
            s.isHeld = true
            return true
        }
        guard isFree else { return nil }
        defer { release() }
        return await body()
    }

    private func acquire() async throws {
        let ticket = state.withLock { s -> UInt64 in
            s.lastTicket += 1
            return s.lastTicket
        }
        defer { _ = state.withLock { $0.cancelledEarly.remove(ticket) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let verdict: Result<Void, any Error>? = state.withLock { s in
                    if s.cancelledEarly.remove(ticket) != nil { return .failure(CancellationError()) }
                    if s.isHeld == false {
                        s.isHeld = true
                        return .success(())
                    }
                    s.waiters.append(Waiter(ticket: ticket, continuation: continuation))
                    return nil
                }
                if let verdict { continuation.resume(with: verdict) }
            }
        } onCancel: {
            let queued: CheckedContinuation<Void, any Error>? = state.withLock { s in
                if let i = s.waiters.firstIndex(where: { $0.ticket == ticket }) { return s.waiters.remove(at: i).continuation }
                s.cancelledEarly.insert(ticket)
                return nil
            }
            queued?.resume(throwing: CancellationError())
        }
    }

    /// Hands the gate to the next waiter (it stays held), or frees it.
    private func release() {
        let next: CheckedContinuation<Void, any Error>? = state.withLock { s in
            if s.waiters.isEmpty {
                s.isHeld = false
                return nil
            }
            return s.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}
