@testable import SwiftHTF
import XCTest

@MainActor
final class PromptPlugTests: XCTestCase {
    // MARK: - 基础回路

    func testRequestConfirmRoundTrip() async {
        let prompt = PromptPlug()
        let stream = prompt.events()

        let listener = Task { @MainActor [prompt] in
            for await req in stream {
                if case .confirm = req.kind {
                    prompt.resolve(id: req.id, response: .confirm(true))
                }
            }
        }

        let answer = await prompt.requestConfirm("放好治具？")
        XCTAssertTrue(answer)
        XCTAssertTrue(prompt.pending.isEmpty)
        listener.cancel()
    }

    func testRequestTextRoundTrip() async {
        let prompt = PromptPlug()
        let stream = prompt.events()

        let listener = Task { @MainActor [prompt] in
            for await req in stream {
                if case .text = req.kind {
                    prompt.resolve(id: req.id, response: .text("SN-1234"))
                }
            }
        }

        let sn = await prompt.requestText("请扫码", placeholder: "SN")
        XCTAssertEqual(sn, "SN-1234")
        listener.cancel()
    }

    func testRequestChoiceRoundTrip() async {
        let prompt = PromptPlug()
        let stream = prompt.events()

        let listener = Task { @MainActor [prompt] in
            for await req in stream {
                if case .choice = req.kind {
                    prompt.resolve(id: req.id, response: .choice(2))
                }
            }
        }

        let idx = await prompt.requestChoice("选择档位", options: ["低", "中", "高"])
        XCTAssertEqual(idx, 2)
        listener.cancel()
    }

    // MARK: - 取消语义

    func testResolveWithCancelledMakesConfirmFalse() async {
        let prompt = PromptPlug()
        let stream = prompt.events()

        let listener = Task { @MainActor [prompt] in
            for await req in stream {
                prompt.cancel(id: req.id)
            }
        }

        let answer = await prompt.requestConfirm("继续？")
        XCTAssertFalse(answer)
        listener.cancel()
    }

    func testTearDownCancelsPendingRequests() async {
        let prompt = PromptPlug()
        // 订阅但不应答，让请求卡在 pending
        let stream = prompt.events()
        let drain = Task { for await _ in stream {} }

        async let answer = prompt.requestConfirm("hang?")

        // 给请求一点时间进入 pending
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(prompt.pending.count, 1)

        await prompt.tearDown()
        let result = await answer
        XCTAssertFalse(result, "tearDown 应让 pending 请求全部以 .cancelled 收尾")
        XCTAssertTrue(prompt.pending.isEmpty)
        drain.cancel()
    }

    func testTaskCancellationPropagates() async {
        let prompt = PromptPlug()
        let stream = prompt.events()
        let drain = Task { for await _ in stream {} }

        let phaseTask = Task { @MainActor [prompt] in
            await prompt.requestConfirm("blocked")
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        phaseTask.cancel()
        let answer = await phaseTask.value
        XCTAssertFalse(answer)
        // pending 也应被清空
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(prompt.pending.isEmpty)
        drain.cancel()
    }

    // MARK: - 订阅时序

    func testLateSubscriberReceivesPending() async {
        let prompt = PromptPlug()

        // 没有订阅者，先发起请求 — 会挂起在 pending 中
        let answerTask = Task { @MainActor [prompt] in
            await prompt.requestConfirm("迟到的订阅者")
        }

        // 等请求落入 pending
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(prompt.pending.count, 1)

        // 此时再订阅，应能收到补发
        let stream = prompt.events()
        let listener = Task { @MainActor [prompt] in
            for await req in stream {
                prompt.resolve(id: req.id, response: .confirm(true))
            }
        }

        let answer = await answerTask.value
        XCTAssertTrue(answer)
        listener.cancel()
    }

    func testMultipleSubscribersAllReceive() async {
        let prompt = PromptPlug()

        actor Box { var hits = 0; func inc() {
            hits += 1
        }; func value() -> Int {
            hits
        } }
        let box = Box()

        let s1 = prompt.events()
        let s2 = prompt.events()

        let l1 = Task { for await _ in s1 {
            await box.inc()
        } }
        let l2 = Task { for await _ in s2 {
            await box.inc()
        } }

        // 让订阅就绪后再发请求
        try? await Task.sleep(nanoseconds: 30_000_000)

        // 异步触发 + 立刻应答
        Task { @MainActor [prompt] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let req = prompt.pending.first {
                prompt.resolve(id: req.id, response: .confirm(true))
            }
        }
        _ = await prompt.requestConfirm("fanout")

        try? await Task.sleep(nanoseconds: 100_000_000)
        let hits = await box.value()
        XCTAssertEqual(hits, 2, "两个订阅者都应收到同一请求")
        l1.cancel(); l2.cancel()
    }

    // MARK: - 与 TestExecutor 集成

    func testPromptInsidePhaseUsingExecutor() async {
        let plan = TestPlan(name: "with_prompt") {
            Phase(name: "ask") { @MainActor ctx in
                let prompt = ctx.getPlug(PromptPlug.self)
                let ok = await prompt.requestConfirm("ready?")
                ctx.measure("operator_confirm", ok)
                return ok ? .continue : .stop
            }
        }
        let executor = TestExecutor(plan: plan)
        await executor.register(PromptPlug.self)

        // 先订阅 — events() 在 plug 实例化（setupAll）后才有意义，
        // 这里我们用 testStarted 事件作为同步点：测试启动后通过工厂的 plug 句柄订阅。
        // 简化做法：起一个监听任务，等到 setup 完成再做断言不可行；
        // 改用 Task.detached 在 execute 启动后短延迟内拿到 plug 实例。
        //
        // 由于 PlugManager 在 setupAll 内才构造 plug，外部测试拿不到引用。
        // 所以我们走"另起一个 Task 持续轮询直到能从 ctx 拿 plug"路径不可行。
        // 改：在执行时通过 outputCallback 不能介入，改成：
        // 让 phase 自己读环境（测试环境变量）— 简化路径用辅助 plug 工厂注入。
        let answerHolder = AnswerHolder()
        await executor.register(PromptPlug.self, factory: {
            let p = PromptPlug()
            answerHolder.set(p)
            return p
        })

        // 启动执行；同时起监听任务等 plug 就绪后订阅 + 应答
        async let recordTask = executor.execute(serialNumber: "SN-T")

        let listener = Task { @MainActor in
            // 轮询拿到 plug 实例
            var plug: PromptPlug?
            for _ in 0 ..< 200 {
                if let p = answerHolder.get() { plug = p; break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard let plug else { return }
            for await req in plug.events() {
                plug.resolve(id: req.id, response: .confirm(true))
            }
        }

        let record = await recordTask
        listener.cancel()

        XCTAssertEqual(record.outcome, .pass)
        XCTAssertEqual(record.phases.first?.measurements["operator_confirm"]?.value.asBool, true)
    }
}

// MARK: - 测试辅助

/// 用于测试时持有 plug 引用；锁式实现，可在 `@Sendable` 工厂闭包里同步写入。
private final class AnswerHolder: @unchecked Sendable {
    private var plug: PromptPlug?
    private let lock = NSLock()
    func set(_ p: PromptPlug) {
        lock.lock(); defer { lock.unlock() }
        plug = p
    }

    func get() -> PromptPlug? {
        lock.lock(); defer { lock.unlock() }
        return plug
    }
}
