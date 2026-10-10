import ApplicationServices
import Foundation
import Darwin

/// A fresh copy of our signed executable avoids process-local trust caches.
/// This branch runs before NSApplication, taps, clipboard access or login items.
enum AccessibilityProbeProcess {
    static let checkArgument = "--accessibility-check"
    static let requestArgument = "--accessibility-request"

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let mode = args.dropFirst().first,
              [checkArgument, requestArgument].contains(mode) else { return false }
        guard args.count == 2 else { exit(3) }
        armExitDeadline()
        let trusted: Bool
        if mode == requestArgument {
            let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else { trusted = AXIsProcessTrusted() }
        exit(trusted ? 0 : 2)
    }

    /// The parent normally reaps us at 750 ms. This independent deadline also
    /// bounds a blocked TCC call if the menu app exits while the check is active.
    static func armExitDeadline(after timeout: TimeInterval = 1) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { _exit(3) }
    }

    /// Only called on dedicated worker queues. No pipe payload or inherited
    /// app descriptors; timeout kills/reaps only the exact child we spawned.
    static func run(executable: URL = Bundle.main.executableURL!,
                    arguments: [String] = [checkArgument], timeout: TimeInterval = 0.75) -> AccessibilityAccessState {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (fd, flags) in [(STDIN_FILENO, O_RDONLY), (STDOUT_FILENO, O_WRONLY), (STDERR_FILENO, O_WRONLY)] {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", flags, 0) == 0 else { return .unavailable }
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return .unavailable }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard launched == 0 else { return .unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                guard status & 0x7f == 0 else { return .unavailable }
                switch (status >> 8) & 0xff {
                case 0: return .granted
                case 2: return .denied
                default: return .unavailable
                }
            }
            if result == -1 && errno != EINTR { return .unavailable }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
                return .unavailable
            }
            usleep(5_000)
        }
    }
}
