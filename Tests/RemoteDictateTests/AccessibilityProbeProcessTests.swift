import Foundation
import Darwin

func runAccessibilityProbeFixture() -> Bool {
    let args = CommandLine.arguments
    guard args.dropFirst().first == "--permission-probe-fixture" else { return false }
    guard args.count >= 3 else { exit(3) }
    switch args[2] {
    case "granted": exit(0)
    case "denied": exit(2)
    case "invalid": exit(3)
    case "crash": raise(SIGKILL); exit(3)
    case "deadline":
        AccessibilityProbeProcess.armExitDeadline(after: 0.04)
        sleep(60); exit(0)
    case "blocked":
        guard args.count == 4 else { exit(3) }
        try! String(getpid()).write(toFile: args[3], atomically: true, encoding: .utf8)
        sleep(60); exit(0)
    default: exit(3)
    }
}

@MainActor func testAccessibilityProbeProcess() async throws {
    let executable = Bundle.main.executableURL!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdh-access-probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ mode: String, extra: [String] = [], timeout: TimeInterval = 1) async -> AccessibilityAccessState {
        await Task.detached {
            AccessibilityProbeProcess.run(executable: executable,
                arguments: ["--permission-probe-fixture", mode] + extra, timeout: timeout)
        }.value
    }
    for (mode, expected) in [("granted", AccessibilityAccessState.granted), ("denied", .denied),
                             ("granted", .granted), ("invalid", .unavailable), ("crash", .unavailable)] {
        let result = await check(mode)
        expectEqual(result, expected)
    }
    let pidFile = directory.appendingPathComponent("pid")
    let began = ProcessInfo.processInfo.systemUptime
    let timeout = await check("blocked", extra: [pidFile.path], timeout: 0.5)
    expectEqual(timeout, .unavailable)
    expectTrue(ProcessInfo.processInfo.systemUptime - began < 2, "A stuck permission checker must be bounded")
    let pid = try expectUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    expectEqual(kill(pid, 0), -1, "Timed-out checker must no longer exist")
    expectEqual(errno, ESRCH)
    var status: Int32 = 0
    expectEqual(waitpid(pid, &status, WNOHANG), -1, "Owned checker must be reaped")
    expectEqual(errno, ECHILD)
    let next = await check("granted")
    expectEqual(next, .granted, "A timeout must not prevent a subsequent check")
    let selfDeadlineStarted = ProcessInfo.processInfo.systemUptime
    let selfDeadline = await check("deadline", timeout: 2)
    expectEqual(selfDeadline, .unavailable)
    expectTrue(ProcessInfo.processInfo.systemUptime - selfDeadlineStarted < 1,
               "Child must enforce its deadline without waiting for the parent's timeout")
    print("Accessibility subprocess: fresh results, invalid/crashed refusal, timeout, owned-child reaping and recovery; no TCC calls or prompts")
}
