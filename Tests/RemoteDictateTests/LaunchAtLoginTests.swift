import Foundation
import ServiceManagement

@MainActor
private final class LoginItemProbe: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var returnedStatus: SMAppService.Status = .enabled
    var failure: Error?
    func register() throws {
        registrations += 1
        status = returnedStatus
        if let failure { throw failure }
    }
}

@MainActor
func testLaunchAtLogin() throws {
    let suite = "rdh-login-tests.\(UUID().uuidString)"
    let defaults = try expectUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdh-login-paths")
    let apps = directory.appendingPathComponent("Applications")
    let app = apps.appendingPathComponent("Remote Dictate Helper.app")
    let service = LoginItemProbe()
    var log: [String] = []
    func controller(_ url: URL? = nil) -> LaunchAtLogin {
        LaunchAtLogin(service: service, defaults: defaults, bundleURL: url ?? app,
            applicationDirectories: [apps], report: { log.append($0) })
    }
    func reset(_ status: SMAppService.Status = .notRegistered) {
        defaults.removePersistentDomain(forName: suite)
        service.status = status; service.registrations = 0
        service.returnedStatus = .enabled; service.failure = nil; log.removeAll()
    }

    let initial = controller()
    expectFalse(initial.registerOnFirstLaunch())
    expectEqual(service.registrations, 1)
    expectEqual(initial.statusDescription, "On ✓")
    expectTrue(defaults.bool(forKey: LaunchAtLogin.registrationKey))
    // A new controller models another process or an updated app: same preference.
    expectFalse(controller().registerOnFirstLaunch())
    expectEqual(service.registrations, 1)
    for optedOut in [SMAppService.Status.notRegistered, .requiresApproval] {
        service.status = optedOut
        expectFalse(controller().registerOnFirstLaunch())
        expectEqual(service.registrations, 1, "Never undo a system opt-out on relaunch/update")
    }
    for existing in [SMAppService.Status.enabled, .requiresApproval] {
        reset(existing)
        expectEqual(controller().registerOnFirstLaunch(), existing == .requiresApproval)
        expectEqual(service.registrations, 0, "Do not duplicate an existing login item")
        expectTrue(defaults.bool(forKey: LaunchAtLogin.registrationKey))
    }
    // User approval remains required, even when registration reports a denial.
    reset(); service.returnedStatus = .requiresApproval
    service.failure = NSError(domain: "LoginProbe", code: 1)
    expectTrue(controller().registerOnFirstLaunch())
    expectTrue(defaults.bool(forKey: LaunchAtLogin.registrationKey))
    expectEqual(controller().statusDescription, "Allow in System Settings")
    expectFalse(controller().registerOnFirstLaunch())
    expectEqual(service.registrations, 1)

    // A genuine registration failure is visible and may retry on next launch.
    reset(); service.returnedStatus = .notRegistered
    service.failure = NSError(domain: "LoginProbe", code: 2)
    let failed = controller()
    expectTrue(failed.registerOnFirstLaunch())
    expectEqual(failed.statusDescription, "Could not enable")
    expectFalse(defaults.bool(forKey: LaunchAtLogin.registrationKey))
    expectTrue(log.contains("registration failed domain=LoginProbe code=2"))
    service.returnedStatus = .enabled; service.failure = nil
    expectFalse(controller().registerOnFirstLaunch())
    expectEqual(service.registrations, 2)
    reset(.notFound)
    expectFalse(controller().registerOnFirstLaunch())
    expectEqual(service.registrations, 1, "Register a never-seen main app as well")
    expectTrue(defaults.bool(forKey: LaunchAtLogin.registrationKey))
    reset(.notFound); service.returnedStatus = .notFound
    service.failure = NSError(domain: "LoginProbe", code: 3)
    expectTrue(controller().registerOnFirstLaunch())
    expectEqual(service.registrations, 1)
    expectFalse(defaults.bool(forKey: LaunchAtLogin.registrationKey))

    // Builds, mounted DMGs, sibling directories and raw executables must never
    // register themselves or consume the installed app's first-launch preference.
    for url in [directory.appendingPathComponent(".build/Helper.app"),
                URL(fileURLWithPath: "/Volumes/Preview/Helper.app"),
                directory.appendingPathComponent("Applications-other/Helper.app"),
                apps.appendingPathComponent("remote-dictate-helper")] {
        reset()
        expectFalse(controller(url).registerOnFirstLaunch())
        expectEqual(service.registrations, 0)
        expectFalse(defaults.bool(forKey: LaunchAtLogin.registrationKey))
    }
    expectTrue(LaunchAtLogin.isInstalledApp(apps.appendingPathComponent("Utilities/Helper.app"), in: [apps]))
    expectFalse(LaunchAtLogin.isInstalledApp(apps.appendingPathComponent("../Downloads/Helper.app"), in: [apps]))
    print("launch at login passed: first registration, relaunch/update, opt-out, approval/failure and installation guards; mocked service only")
}
