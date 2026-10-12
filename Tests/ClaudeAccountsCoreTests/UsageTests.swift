import Foundation
import Testing
@testable import ClaudeAccountsCore

@Suite("Usage")
struct UsageTests {
    @Test("levels: neutral, amber at 80 %, red at 95 %")
    func levels() {
        #expect(UsageLevel(0.79) == .normal)
        #expect(UsageLevel(0.80) == .high)
        #expect(UsageLevel(0.949) == .high)
        #expect(UsageLevel(0.95) == .critical)
        #expect(UsageWindow(utilization: 1.4, resetsAt: nil, fetchedAt: Date()).utilization == 1)
    }

    @Test("no provider means no data; the fake is deterministic per account")
    func providers() async {
        #expect(await NoUsageProvider().usage(for: "x") == nil)
        let now = Date()
        let a = await FakeUsageProvider(now: now).usage(for: FakeWorld.a)
        let b = await FakeUsageProvider(now: now).usage(for: FakeWorld.a)
        #expect(a == b)
        #expect(a?.fiveHour?.resetsAt.map { $0 > now } == true)
    }
}
