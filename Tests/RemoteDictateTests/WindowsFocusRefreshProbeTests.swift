import AppKit

@MainActor
func testWindowsFocusRefreshProbe() async {
    @MainActor final class Fixture {
        var front: pid_t? = 42
        var key = false
        var stable = true
        var windowValid = true
        var advance = true
        var activationAllowed = true
        var time: TimeInterval = 0
        var shown = 0, returned = 0, closed = 0, ticks = 0
        var onPause: ((Int) -> Void)?
        var succeeded = false
        var logs: [String] = []
        func run() async {
            let environment = WindowsFocusRefreshProbe.Environment(helperPID: 9,
                front: { self.front }, ownsKeyWindow: { self.key },
                show: { self.shown += 1 },
                returnToTarget: { self.returned += 1; return self.activationAllowed },
                close: { self.closed += 1 }, now: { self.time }, pause: {
                    self.ticks += 1; self.time += 0.01
                    if self.advance {
                        self.front = self.returned == 0 ? 9 : 42
                        self.key = self.returned == 0
                    }
                    self.onPause?(self.ticks)
                    await Task.yield()
                })
            do {
                try await WindowsFocusRefreshProbe.perform(targetPID: 42, environment: environment,
                    validateStable: {
                        if !self.stable { throw WindowsClipboardProbe.Failure.changed }
                    }, validateTarget: {
                        if self.front != 42 || !self.windowValid { throw WindowsClipboardProbe.Failure.changed }
                    }, log: { self.logs.append($0) })
                succeeded = true
            } catch { succeeded = false }
        }
    }

    let success = Fixture(); await success.run()
    expectTrue(success.succeeded)
    expectEqual(success.shown, 1); expectEqual(success.returned, 1); expectEqual(success.closed, 1)
    expectEqual(success.front, 42)
    expectTrue(success.time < 0.1, "Readiness completes immediately; no fixed focus delay")
    expectTrue(success.logs.last?.contains("remoteReceipt=unverified") == true)

    for stage in [1, 2] {
        for change in ["other-app", "clipboard-or-input", "window"] {
            let f = Fixture()
            f.onPause = { tick in
                guard tick == stage else { return }
                switch change {
                case "other-app": f.front = 77
                case "clipboard-or-input": f.stable = false
                default: f.windowValid = false
                }
            }
            await f.run()
            expectFalse(f.succeeded, "Reject \(change) during focus phase \(stage)")
            expectEqual(f.closed, 1)
            if stage == 1 && change != "window" {
                expectEqual(f.returned, 0, "Do not steal focus back after changed context")
            }
        }
    }
    let otherHelperWindow = Fixture()
    otherHelperWindow.onPause = { tick in
        if tick == 2 { otherHelperWindow.front = 9; otherHelperWindow.key = false }
    }
    await otherHelperWindow.run()
    expectFalse(otherHelperWindow.succeeded)
    expectEqual(otherHelperWindow.returned, 1, "Never retry activation")
    expectEqual(otherHelperWindow.closed, 1)

    for lateReturn in [false, true] {
        let timeout = Fixture()
        if lateReturn { timeout.onPause = { tick in if tick == 2 { timeout.time = 1.01 } } }
        else { timeout.advance = false }
        await timeout.run()
        expectFalse(timeout.succeeded)
        expectEqual(timeout.closed, 1)
        expectTrue(timeout.time >= 1 && timeout.time < 1.1)
    }

    let refused = Fixture(); refused.activationAllowed = false
    await refused.run()
    expectFalse(refused.succeeded); expectEqual(refused.returned, 1); expectEqual(refused.closed, 1)

    let cancelled = Fixture()
    var task: Task<Void, Never>?
    cancelled.onPause = { _ in task?.cancel() }
    task = Task { await cancelled.run() }
    await task?.value
    expectFalse(cancelled.succeeded); expectEqual(cancelled.returned, 0); expectEqual(cancelled.closed, 1)
}
