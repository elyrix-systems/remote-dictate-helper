import Foundation

// Pure state-machine spike. No app activation, UI, clipboard or actual timers.
final class CompletionTests {
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
