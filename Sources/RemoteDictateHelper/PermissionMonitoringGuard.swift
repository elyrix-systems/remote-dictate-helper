import AppKit

/// Retire taps before the user can revoke their permission in System Settings.
/// A disabled-tap callback arrives too late on affected macOS versions: even
/// successful invalidation did not restore physical input in the local trial.
@MainActor
final class PermissionMonitoringGuard {
    enum State: Equatable { case allowed, systemSettings, permissionMissing }
    static let settingsBundle = "com.apple.systempreferences"
    private let center: NotificationCenter
    private let front: () -> String?
    private let trusted: () -> Bool
    private let onChange: (State) -> Void
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var running = false
    private var awaitingSettings = false
    private(set) var state: State?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         front: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         trusted: @escaping () -> Bool = { AccessibilityPermission.isTrusted() },
         onChange: @escaping (State) -> Void) {
        self.center = center; self.front = front; self.trusted = trusted; self.onChange = onChange
    }

    // Recheck foreground at every creation entry point. A hidden helper Settings
    // timer or a settings save must not recreate taps behind System Settings.
    var mayInstallFilters: Bool {
        running && !awaitingSettings && state == .allowed && front() != Self.settingsBundle
    }

    func start(poll: Bool = true) {
        stop(); running = true
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let launching = note.name == NSWorkspace.willLaunchApplicationNotification
                let identifier = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if launching {
                        if identifier == Self.settingsBundle { self.prepareToOpenSettings() }
                    } else { self.awaitingSettings = false; self.refresh() }
                }
            })
        }
        if poll {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Active taps already check trust off the UI thread. Here
                    // only watch the paused UI, where no tap depends on progress.
                    guard let self, self.state != .allowed else { return }
                    self.refresh()
                }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        refresh()
    }

    func stop() {
        running = false; timer?.invalidate(); timer = nil
        observers.forEach { center.removeObserver($0) }; observers.removeAll()
        state = nil
        awaitingSettings = false
    }

    /// Called synchronously before our own button opens the permission pane.
    func prepareToOpenSettings() {
        guard running else { return }
        awaitingSettings = true
        update(.systemSettings)
    }

    func refresh() {
        guard running else { return }
        // Retire native taps before making a permission query on Settings entry.
        let inSettings = front() == Self.settingsBundle
        if inSettings { awaitingSettings = false }
        if inSettings || awaitingSettings {
            if state == .allowed || state == nil { update(.systemSettings) }
            update(trusted() ? .systemSettings : .permissionMissing)
        } else {
            update(trusted() ? .allowed : .permissionMissing)
        }
    }

    private func update(_ next: State) {
        guard state != next else { return }
        state = next; onChange(next)
    }
}
