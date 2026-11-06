import Foundation
import RemoteDictateCore

// Pure state-machine spike. No app activation, UI, clipboard or actual timers.
final class CompletionTests {
    @MainActor func testReadOnlyConfirmation() throws {
        for sendFailed in [false, true] {
            let completion = DeferredClipboardCompletion(automaticallyPoll: false)
            var observation = ClipboardSharingObservation.waitingForTarget
            var clock: TimeInterval = 0
            var results: [Result<Void, Error>] = []
            let original = ExplicitClipboardTransferError.restorationFailed(
                operation: sendFailed ? "Send refused" : nil, restoration: "Menu lost focus after enable")
            try completion.startConfirmation(after: original, observe: { observation }, now: { clock },
                onWaiting: { _ in }, onFinished: { results.append($0) })
            clock = 500
            for _ in 0..<10_000 { completion.poll() }
            expectTrue(results.isEmpty, "Background time is not evidence of disabled sharing")
            observation = .waitingForMenu; completion.poll()
            observation = .disabled; completion.poll()
            clock += 0.5; completion.poll()
            expectTrue(results.isEmpty)
            observation = .waitingForTarget; completion.poll()
            clock += 100
            observation = .disabled; completion.poll()
            expectTrue(results.isEmpty, "A fresh observable interval gets its own confirmation budget")
            observation = .enabled; completion.poll()
            expectEqual(results.count, 1)
            if sendFailed {
                guard case .failure(ExplicitClipboardTransferError.restoredClipboardSendFailed) = results[0] else {
                    fail("Sharing confirmation must not hide an earlier Send failure")
                }
            } else { try results[0].get() }
            for _ in 0..<10 { completion.poll() }
            expectEqual(results.count, 1)
        }
        let disabled = DeferredClipboardCompletion(automaticallyPoll: false)
        var clock: TimeInterval = 0, failures = 0
        let error = ExplicitClipboardTransferError.restorationFailed(operation: nil, restoration: "unconfirmed")
        try disabled.startConfirmation(after: error, observe: { .disabled }, now: { clock },
            onWaiting: { _ in }, onFinished: { result in
                guard case .failure(ClipboardCompletionError.sharingUnconfirmed) = result else {
                    fail("A reliably observed disabled state must remain an error")
                }
                failures += 1
            })
        clock = 1; disabled.poll(); disabled.poll()
        expectEqual(failures, 1)

        enum Changed: Error { case target }
        let changed = DeferredClipboardCompletion(automaticallyPoll: false)
        var changedResults = 0
        try changed.startConfirmation(after: error, observe: { throw Changed.target }, onWaiting: { _ in },
            onFinished: { result in
                guard case .failure(Changed.target) = result else { fail("Different connection must stop verification") }
                changedResults += 1
            })
        changed.poll(); expectEqual(changedResults, 1)
        expectThrows(try changed.startConfirmation(after: Changed.target, observe: { .enabled }, onWaiting: { _ in },
            onFinished: { _ in fail("Unrelated errors cannot become confirmation work") }))
        print("Sharing confirmation: read-only focus recovery, no repeated action, real disabled/target errors and earlier Send failure preserved")
    }

    @MainActor func testDeferredCompletion() throws {
        enum Failure: Error { case probe, action }
        let completion = DeferredClipboardCompletion(automaticallyPoll: false)
        var readiness = ClipboardCompletionReadiness.waitingForTarget
        var waiting: [ClipboardCompletionReadiness] = []
        var actions = 0
        var finishes = 0
        try completion.start(probe: { readiness }, complete: {
            precondition(!completion.hasPendingCompletion)
            actions += 1
        }, onWaiting: { waiting.append($0) }, onFinished: {
            try! $0.get()
            finishes += 1
        })
        precondition(completion.hasPendingCompletion && actions == 0 && finishes == 0)
        do {
            try completion.start(probe: { .ready }, complete: { fatalError("Replaced pending work") },
                                 onWaiting: { _ in }, onFinished: { _ in fatalError("Second start") })
            fatalError("Concurrent start must refuse")
        } catch ClipboardCompletionError.alreadyPending {}
        // No elapsed-time escape: arbitrarily many polls cannot perform work or
        // discard the obligation while the captured target is unavailable.
        for _ in 0..<10_000 { completion.poll() }
        precondition(waiting == [.waitingForTarget] && actions == 0 && finishes == 0)
        readiness = .waitingForMenu
        completion.poll()
        completion.poll()
        precondition(waiting == [.waitingForTarget, .waitingForMenu])
        readiness = .ready
        completion.poll()
        completion.poll()
        precondition(!completion.hasPendingCompletion && actions == 1 && finishes == 1)

        for failsInProbe in [true, false] {
            var failed = false
            let beforeActions = actions
            try completion.start(probe: {
                if failsInProbe { throw Failure.probe }
                return .ready
            }, complete: {
                actions += 1
                throw Failure.action
            }, onWaiting: { _ in fatalError("Already ready") }, onFinished: { result in
                guard case .failure = result else { fatalError("Failure was hidden") }
                precondition(!completion.hasPendingCompletion)
                failed = true
                finishes += 1
            })
            let beforeFinishes = finishes
            completion.poll()
            precondition(failed && actions == beforeActions + (failsInProbe ? 0 : 1))
            precondition(finishes == beforeFinishes, "Failed actions must never retry")
        }
        print("deferred completion tests passed: readiness, indefinite wait, busy refusal, exactly one attempt, errors; no external actions")
    }
}
