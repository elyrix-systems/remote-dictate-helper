import AppKit
import RemoteDictateCore

@MainActor
final class WindowsAppPasteTests {
    @MainActor private final class Fixture {
        var target: pid_t? = 101
        var revision = 1
        var trusted = true
        var available = true
        var windowValid = true
        var sequence: UInt64 = 5
        var modifiers: UInt64 = 0
        var heldFn = false
        var onReadHardware: (() -> Void)?
        var events: [CGEvent] = []
        var results: [Result<Void, Error>] = []
        var pauses = 0
        var onPause: ((Int) throws -> Void)?
        var monitor: WindowsAppPasteMonitor!

        init(sources: [DictationSource] = AppSettings().sources) {
            let ready = ExplicitPasteShortcut(isolatedSoftwareCommand: true, interceptedPaste: true,
                isTrusted: { [unowned self] in trusted }, targetIsFrontmost: { [unowned self] in target == $0 },
                flags: { .maskCommand }, hardwareFlags: { [unowned self] in
                    onReadHardware?(); return heldFn ? .maskSecondaryFn : []
                }, post: { _ in fail("Readiness must not post input") })
            monitor = WindowsAppPasteMonitor(sources: sources,
                isAvailable: { [unowned self] in available }, targetPID: { [unowned self] in target },
                revision: { [unowned self] in revision }, isTrusted: { [unowned self] in trusted },
                captureWindow: { [unowned self] _ in
                    return { [unowned self] in
                        guard windowValid else { throw WindowsAppPasteError.targetChanged }
                    }
                }, readiness: ready,
                post: { [unowned self] in events.append($0) }, pause: { [unowned self] in
                    pauses += 1; try onPause?(pauses); await Task.yield()
                }, inputSequence: { [unowned self] in sequence }, modifierSequence: { [unowned self] in modifiers },
                onCompleted: { [unowned self] in results.append($0) })
        }

        func input() -> PasteInputEvent {
            PasteInputEvent(kind: .down, key: 9, command: true, pid: 202,
                fromDictation: true, sequence: sequence)
        }
        var keys: [Int64] { events.map { $0.getIntegerValueField(.keyboardEventKeycode) } }
        func wait() async throws {
            for _ in 0..<500 {
                if !monitor.isBusy { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            fail("Mock Windows App operation did not finish")
        }
        func checkRelease() {
            expectFalse(events.last!.flags.contains(.maskCommand))
            expectEqual(events.last!.flags.rawValue & 0x18, 0)
            expectFalse(keys.contains(51), "Never delete a remote character")
        }
    }

    func testAllConfiguredSources() async throws {
        for source in SourceInputHarness.sources {
            for suffix in ["", ".helper"] {
                for policy in ClipboardReturnPolicy.allCases {
                    var selected = source; selected.clipboardReturn = policy
                    let f = Fixture(sources: [selected])
                    let input = SourceInputHarness(sources: [selected], identifier: source.bundleIdentifier + suffix) {
                        if let sequence = $0.sequence { f.sequence = sequence }
                        return f.monitor.observe($0)
                    }
                    for _ in 0..<2 {
                        expectTrue(try input.paste(down: true), "Every selected source uses the same capture path")
                        expectTrue(try input.paste(down: false), "Pair each suppressed paste")
                        try await f.wait(); f.revision += 1
                    }
                    expectEqual(f.keys, [55,9,9,55,55,9,9,55])
                    expectEqual(f.results.count, 2)
                    for result in f.results { try result.get() }
                    f.checkRelease()
                }
            }
            var disabled = source; disabled.enabled = false
            for selection in [[], [disabled]] {
                let f = Fixture(sources: selection)
                let input = SourceInputHarness(sources: selection, identifier: source.bundleIdentifier) {
                    if let sequence = $0.sequence { f.sequence = sequence }
                    return f.monitor.observe($0)
                }
                expectFalse(try input.paste(down: true)); expectFalse(try input.paste(down: false))
                expectTrue(f.events.isEmpty); expectFalse(f.monitor.isBusy)
            }
        }
        print("Windows App source contract passed: Flow, superwhisper, Valis, custom app, helper IDs, both clipboard policies and removed/disabled sources; mocked input only")
    }

    func testRepeatedPasteAndScope() async throws {
        let f = Fixture()
        for _ in 0..<3 {
            expectTrue(f.monitor.observe(f.input()))
            expectFalse(f.monitor.observe(f.input()), "No overlap")
            try await f.wait()
            expectFalse(f.monitor.observe(f.input()), "No replay of the handled revision")
            f.revision += 1
        }
        expectEqual(f.keys, Array(repeating: [Int64(55),9,9,55], count: 3).flatMap { $0 })
        expectEqual(f.results.count, 3)
        for result in f.results { try result.get() }
        expectEqual(f.events.prefix(4).map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        for index in stride(from: 0, to: f.events.count, by: 4) {
            let group = Array(f.events[index..<index+4])
            expectTrue(group.prefix(3).allSatisfy { $0.flags.rawValue & 0x100108 == 0x100108 })
            let states = group.map { $0.getIntegerValueField(.eventSourceStateID) }
            expectEqual(Set(states).count, 1); expectTrue(states[0] > 1, "Use a private source")
        }
        f.checkRelease()
        expectEqual(f.revision, 4, "Helper must never write the clipboard")

        let ignored = Fixture()
        let events: [PasteInputEvent] = [
            .init(kind: .down, key: 9, command: true, pid: 0, fromDictation: false),
            .init(kind: .down, key: 9, command: true, pid: ProcessInfo.processInfo.processIdentifier, fromDictation: true),
            .init(kind: .down, key: 9, command: false, pid: 202, fromDictation: true),
            .init(kind: .down, key: 8, command: true, pid: 202, fromDictation: true),
            .init(kind: .up, key: 9, command: true, pid: 202, fromDictation: true),
            .init(kind: .down, key: 9, command: true, pid: 202, fromDictation: true, autorepeat: true)
        ]
        for event in events { expectFalse(ignored.monitor.observe(event)) }
        ignored.target = nil; expectFalse(ignored.monitor.observe(ignored.input()))
        ignored.target = 101; ignored.trusted = false; expectFalse(ignored.monitor.observe(ignored.input()))
        ignored.trusted = true; ignored.available = false; expectFalse(ignored.monitor.observe(ignored.input()))
        expectTrue(ignored.events.isEmpty)
    }

    func testChangedContextAndShutdown() async throws {
        for kind in 0..<5 {
            let f = Fixture()
            f.onPause = { _ in
                switch kind {
                case 0: f.target = nil
                case 1: f.windowValid = false
                case 2: f.sequence += 1
                case 3: f.modifiers += 1
                default: f.revision += 1
                }
            }
            expectTrue(f.monitor.observe(f.input())); try await f.wait()
            expectEqual(f.keys, [55,55], "Changed focus/input/clipboard cannot emit V")
            expectEqual(f.results.count, 1)
            expectThrows(try f.results[0].get())
            f.checkRelease()
            f.target = 101; f.windowValid = true
            await Task.yield()
            expectEqual(f.keys, [55,55], "Returning must not cause deferred paste")
        }
        let waiting = Fixture()
        var reads = 0
        waiting.onReadHardware = {
            reads += 1; waiting.heldFn = reads == 1
            if reads == 2 { waiting.modifiers += 1 }
        }
        expectTrue(waiting.monitor.observe(waiting.input())); try await waiting.wait()
        expectEqual(waiting.keys, [55,9,9,55], "Fn release before replay is permitted")

        let staleWhileWaiting = Fixture()
        staleWhileWaiting.heldFn = true
        staleWhileWaiting.onReadHardware = { staleWhileWaiting.revision += 1 }
        expectTrue(staleWhileWaiting.monitor.observe(staleWhileWaiting.input())); try await staleWhileWaiting.wait()
        expectTrue(staleWhileWaiting.events.isEmpty, "Clipboard expiry during modifier wait must stop input")

        for stopAfter in [1,2] {
            let f = Fixture()
            f.onPause = { count in if count == stopAfter { f.monitor.stop() } }
            expectTrue(f.monitor.observe(f.input())); try await f.wait()
            for _ in 0..<10 { await Task.yield() }
            expectEqual(f.keys, stopAfter == 1 ? [55,55] : [55,9,9,55])
            f.checkRelease()
            expectTrue(f.results.isEmpty, "Stopped generation must not overwrite app status")
            f.revision += 1; expectFalse(f.monitor.observe(f.input()))
        }
        let disabled = Fixture()
        disabled.onPause = { _ in disabled.monitor.filterDisabled() }
        expectTrue(disabled.monitor.observe(disabled.input())); try await disabled.wait()
        for _ in 0..<10 { await Task.yield() }
        expectEqual(disabled.keys, [55,55]); disabled.checkRelease()
        expectEqual(disabled.results.count, 1); expectThrows(try disabled.results[0].get())
        print("Windows App passed: repeated source pastes, no clipboard writes/deletion, target/input/revision guards, Fn release, cancellation/quit and disabled-tap cleanup; mocked input only")
    }

    func testPhysicalModifierTracking() throws {
        let tracked = PasteEventFilter(sources: [], onEvent: { _, _ in }, onDisabled: {}, trackPhysicalModifiers: true)
        let unchanged = PasteEventFilter(sources: [], onEvent: { _, _ in }, onDisabled: {})
        let event = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        expectFalse(tracked.handle(type: .flagsChanged, event: event))
        expectEqual(tracked.physicalModifierSequence, 1); expectEqual(tracked.inputSequence, 0)
        expectFalse(unchanged.handle(type: .flagsChanged, event: event))
        expectEqual(unchanged.physicalModifierSequence, 0, "Screen Sharing keeps its existing event scope")
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        expectFalse(tracked.handle(type: .flagsChanged, event: event))
        expectEqual(tracked.physicalModifierSequence, 1, "Our own replay cannot cancel itself")
        tracked.stop()
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        expectFalse(tracked.handle(type: .flagsChanged, event: event))
        expectEqual(tracked.physicalModifierSequence, 1)
    }
}
