@testable import SwiftHTF
import XCTest

/// 全局 abort：`AbortRegistry` + `TestExecutor.cancel()` + `bindToAbortRegistry`。
///
/// SIGINT 路径不在单测里发实信号（会影响整个测试进程），仅验证安装器幂等。
final class AbortRegistryTests: XCTestCase {
    // MARK: - register / unregister 基本计数

    func testRegisterUnregisterRoundTrip() async {
        let reg = AbortRegistry()
        var n = await reg.registeredCount
        XCTAssertEqual(n, 0)
        let token = await reg.register {}
        n = await reg.registeredCount
        XCTAssertEqual(n, 1)
        await reg.unregister(token)
        n = await reg.registeredCount
        XCTAssertEqual(n, 0)
    }

    // MARK: - abortAll 扇出到所有 handler

    func testAbortAllInvokesAllHandlers() async {
        let reg = AbortRegistry()
        let counter = HandlerCallCounter()
        _ = await reg.register { await counter.tick() }
        _ = await reg.register { await counter.tick() }
        _ = await reg.register { await counter.tick() }
        await reg.abortAll()
        // abortAll 内部用 detached Task，给 handler 留一点时间执行
        try? await Task.sleep(nanoseconds: 50_000_000)
        let n = await counter.value
        XCTAssertEqual(n, 3)
    }

    // MARK: - bindToAbortRegistry 把 executor 接进总线

    func testBindToRegistryCancelsExecutor() async {
        let reg = AbortRegistry()
        let plan = TestPlan(name: "cancel") {
            Phase(name: "long") { @MainActor _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return .continue
            }
        }
        let executor = TestExecutor(plan: plan)
        let token = await executor.bindToAbortRegistry(reg)
        let session = await executor.startSession(serialNumber: "SN")
        // 让 phase 开始跑
        try? await Task.sleep(nanoseconds: 50_000_000)
        await reg.abortAll()
        let record = await session.record()
        XCTAssertEqual(record.outcome, .aborted)
        await reg.unregister(token)
    }

    // MARK: - SIGINT 安装器幂等性

    func testInstallSIGINTHandlerIsIdempotent() {
        // 重复调用不应抛 / 不应 crash
        TestExecutor.installSIGINTHandler()
        TestExecutor.installSIGINTHandler()
        TestExecutor.installSIGINTHandler()
    }
}

/// 多 handler 并发 tick 的计数器（避免 Int 直接的并发写）。
private actor HandlerCallCounter {
    private(set) var value: Int = 0
    func tick() {
        value += 1
    }
}
