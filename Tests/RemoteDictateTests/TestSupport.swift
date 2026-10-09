import AppKit

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
    fatalError(message, file: (file), line: line)
}
func expectTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { fail(message, file: file, line: line) } } catch { fail("\(message): \(error)", file: file, line: line) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "Expected false", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() { fail(message, file: file, line: line) } } catch { fail("\(message): \(error)", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "Values differ", file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() != rhs() { fail(message, file: file, line: line) } } catch { fail("\(message): \(error)", file: file, line: line) }
}
func expectNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "Expected nil", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { fail(message, file: file, line: line) } } catch { fail("\(message): \(error)", file: file, line: line) }
}
func expectNotNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "Expected value", file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { fail(message, file: file, line: line) } } catch { fail("\(message): \(error)", file: file, line: line) }
}
func expectUnwrap<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let result = try value() else { fail("Expected value", file: file, line: line) }; return result
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, _ message: String = "Expected refusal", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value() } catch { return }; fail(message, file: file, line: line)
}

@main
struct TestRunner {
    @MainActor static func main() async throws {
        if ClipboardReaderProcess.runIfRequested() || runClipboardProviderFixture() { return }
        try await testIsolatedClipboardReading()
        try await testAsyncCaptureAndExpiredDecision()
        if CommandLine.arguments.contains("--isolation-only") { return }
        testCaptureDecisionDeadline()
        try await testPasteFilterLiveness()
        try await testBlockedAdmissionLiveness()
        try await testLateAdmissionCannotReplay()
        testSettingsReadiness()
        testAccessibilitySettingsNavigation()
        try testLaunchAtLogin()
        try testOperationalLog()
        try testDiagnosticLogStorage()
        try testDiagnosticTextLogging()
        try testScreenSharingDiagnosticTextCapture()
        try testCaptureCancellationDiagnostics()
        try testSettingsPersistence()
        try testImmediateSourceSettings()
        let settings = SettingsTests(); try settings.testMigrationRemovesUnusedFields(); settings.testSourceScope()
        try CaptureTests().testCaptureLifecycle()
        let emptyReturn = EmptyClipboardReturnTests()
        try emptyReturn.testEmptyTextReturnAndExactRestoration()
        try emptyReturn.testEmptyReturnDoesNotAcceptUnknownContent()
        let release = ReleaseTests()
        try release.testReturnBeforePasteStartsFreshTransaction()
        try release.testTimeoutDistinguishesKeyReleaseFromClipboard()
        let interception = InterceptionTests()
        try await interception.testAllConfiguredSources()
        try interception.testSuppressionScopeAndRelease()
        try interception.testAppThatLeavesItsTranscript()
        interception.testSlowCapturePassesOriginalThrough()
        interception.testInterceptedReplayNeverDeletes()
        let clipboard = ClipboardTests()
        try clipboard.testRestorationOwnershipFormatsAndDeadlines()
        try clipboard.testEmptyOriginalAndReplayIsolation()
        try clipboard.testRichMultilingualPayload()
        try CompletionTests().testDeferredCompletion()
        try await InputTests().testNativeInput()
        let windows = WindowsAppPasteTests()
        try await windows.testAllConfiguredSources()
        try await windows.testRepeatedPasteAndScope()
        try await windows.testChangedContextAndShutdown()
        try await windows.testDiagnosticReasons()
        try await windows.testDiagnosticTextStages()
        try await windows.testClipboardPreparationGuards()
        try await windows.testExperimentalFocusRefreshGuards()
        try await testWindowsClipboardReader()
        await testWindowsFocusRefreshProbe()
        try await testWindowsClipboardProbe()
        try windows.testPhysicalModifierTracking()
        try testExplicitClipboardTransferRecovery()
        try testLegacyCoreCompatibility()
        print("All tests passed. Named clipboards and mocked input only; no app control or real keystrokes.")
    }
}

func testCaptureDecisionDeadline() {
    let late = PasteCaptureDecision(wait: 0)
    expectFalse(late.wait())
    expectFalse(late.resolve(true), "Expired capture must be inert")
    let accepted = PasteCaptureDecision()
    accepted.resolve(true)
    expectTrue(accepted.wait())
    let refused = PasteCaptureDecision()
    refused.resolve(false)
    expectFalse(refused.wait())
}

// Component fixtures own eager synthetic data and run on its owner thread.
// Isolation/provider liveness is separately tested through the real subprocess.
@MainActor func eagerTestClipboardAccess() -> ClipboardAccess {
    ClipboardAccess(immediateRead: { board in
        let revision = board.changeCount
        let snapshot = try LocalClipboardSnapshot.capture(board)
        let text = board.string(forType: .string)
        guard board.changeCount == revision else { throw LocalClipboardError.changed }
        return .init(revision: revision, snapshot: snapshot, text: text)
    })
}
