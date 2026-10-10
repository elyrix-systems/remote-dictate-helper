import AppKit

@MainActor func testPermissionSettingsGuard() {
    let center = NotificationCenter()
    var front: String? = "example.remote", trusted = true
    var filters = 0, creations = 0, stopped = 0, invalidations = 0
    var states: [PermissionMonitoringGuard.State] = []
    let guardrail = PermissionMonitoringGuard(center: center, front: { front }, trusted: { trusted }, invalidatePermission: {
        expectEqual(filters, 0, "Native teardown must precede permission refresh")
        invalidations += 1
    }) { state in
        states.append(state)
        if state == .allowed { filters = 2; creations += 1 }
        else { filters = 0; stopped += 1 }
    }
    func activate(_ app: String?) {
        front = app
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    guardrail.start(poll: false)
    expectTrue(guardrail.mayInstallFilters); expectEqual(filters, 2)
    // A fresh foreground check closes the hidden Settings timer/save entry point
    // even before the activation notification has reached the guard.
    front = PermissionMonitoringGuard.settingsBundle
    expectFalse(guardrail.mayInstallFilters)
    activate(front)
    expectEqual(filters, 0, "Disconnect before the user removes the grant")
    expectEqual(states.last, .systemSettings)
    for _ in 0..<1_000 { guardrail.refresh(); expectFalse(guardrail.mayInstallFilters) }
    expectEqual(creations, 1); expectEqual(stopped, 1)
    expectEqual(invalidations, 1, "Paused polling must not repeatedly invalidate the live result")
    trusted = false; guardrail.refresh()
    expectEqual(states.last, .permissionMissing); expectEqual(filters, 0)
    activate("example.remote")
    expectFalse(guardrail.mayInstallFilters, "Leaving Settings without permission cannot restart input")
    expectEqual(creations, 1)

    // Regrant in the system pane leaves taps absent until the user leaves it.
    activate(PermissionMonitoringGuard.settingsBundle)
    trusted = true; guardrail.refresh()
    expectEqual(states.last, .systemSettings); expectEqual(filters, 0)
    activate("example.remote")
    expectTrue(guardrail.mayInstallFilters); expectEqual(filters, 2); expectEqual(creations, 2)
    let beforeLocal = invalidations
    // Ordinary local/remote activation must not churn taps or interrupt dictation.
    activate("example.local"); activate("example.remote")
    expectEqual(creations, 2)
    expectEqual(invalidations, beforeLocal, "Ordinary focus changes must not interrupt permission checks")

    // Our own button disconnects synchronously before opening the pane. Polling
    // during its launch cannot accidentally recreate input taps.
    guardrail.prepareToOpenSettings()
    expectEqual(filters, 0); expectFalse(guardrail.mayInstallFilters)
    for _ in 0..<1_000 { guardrail.refresh(); expectFalse(guardrail.mayInstallFilters) }
    expectEqual(creations, 2)
    activate(PermissionMonitoringGuard.settingsBundle)
    activate("example.remote")
    expectEqual(creations, 3)
    guardrail.stop()
    let count = states.count
    activate(PermissionMonitoringGuard.settingsBundle); guardrail.refresh(); guardrail.prepareToOpenSettings()
    expectEqual(states.count, count, "Stopped observers cannot recreate monitoring")
    expectFalse(guardrail.mayInstallFilters)

    // Starting/reconfiguring while the permission pane is already open never
    // creates a tap; neither does granting access there in the background.
    guardrail.start(poll: false)
    expectEqual(states.last, .systemSettings); expectFalse(guardrail.mayInstallFilters)
    expectEqual(creations, 3)
    trusted = false; guardrail.refresh()
    expectEqual(states.last, .permissionMissing)
    guardrail.stop()
    print("Permission pane guard: teardown before revocation, no hidden rearming, trusted-only resume, startup and stop; mocked workspace/trust, no native input or TCC changes")
}
