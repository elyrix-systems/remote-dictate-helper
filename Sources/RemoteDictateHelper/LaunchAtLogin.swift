import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
}

@MainActor
private struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
}

/// Register the installed main app once, then let macOS own the user's choice.
/// No launch agent, extra executable, timer or automatic re-enabling on updates.
@MainActor
final class LaunchAtLogin {
    static let registrationKey = "automaticLoginRegistrationCompletedV1"
    private let service: any LoginItemService
    private let defaults: UserDefaults
    private let report: (String) -> Void
    let isInstalled: Bool
    private var registrationFailed = false

    init(service: (any LoginItemService)? = nil, defaults: UserDefaults = .standard,
         bundleURL: URL = Bundle.main.bundleURL,
         applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)],
         report: @escaping (String) -> Void = { _ in }) {
        self.service = service ?? SystemLoginItemService()
        self.defaults = defaults; self.report = report
        self.isInstalled = Self.isInstalledApp(bundleURL, in: applicationDirectories)
    }

    static func isInstalledApp(_ bundleURL: URL, in directories: [URL]) -> Bool {
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return bundle.pathExtension == "app" && directories.contains {
            bundle.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }
    }

    var statusDescription: String {
        guard isInstalled else { return "Move app to Applications" }
        switch service.status {
        case .enabled: return "On ✓"
        case .requiresApproval: return "Allow in System Settings"
        case .notRegistered: return registrationFailed ? "Could not enable" : "Off"
        case .notFound: return "Unavailable"
        @unknown default: return "Unavailable"
        }
    }

    /// Returns whether first-time setup needs the user's attention. A completed
    /// registration persists across updates; a later system opt-out is respected.
    @discardableResult
    func registerOnFirstLaunch() -> Bool {
        guard isInstalled else { report("skipped: app is outside Applications"); return false }
        guard !defaults.bool(forKey: Self.registrationKey) else {
            report("existing preference retained status=\(service.status.rawValue)")
            return false
        }
        // A never-seen main app can report notFound before its first register().
        // This does not authorize re-registering after a saved setup or denial.
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                registrationFailed = true
                let error = error as NSError
                report("registration failed domain=\(error.domain) code=\(error.code)")
            }
        }
        let status = service.status
        if status == .enabled || status == .requiresApproval {
            // Approval-required is also registered. Never re-register to bypass
            // a system denial, including when register() itself returned an error.
            defaults.set(true, forKey: Self.registrationKey)
        }
        report("status=\(status.rawValue)")
        return status != .enabled
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
