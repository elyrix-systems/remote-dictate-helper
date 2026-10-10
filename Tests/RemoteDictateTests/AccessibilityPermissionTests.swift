// Only injected effects: never request or change the test runner's permissions.
@MainActor
func testAccessibilitySettingsNavigation() async {
    var access: AccessibilityAccessState = .denied
    var requests = 0
    var openedPanes = 0
    let click = {
        await AccessibilityPermission.openSettings(check: { access }, request: {
            requests += 1
        }, openPane: {
            openedPanes += 1
        })
    }

    await click()
    expectEqual(requests, 1)
    expectEqual(openedPanes, 0, "The system access alert alone must own navigation")
    // Cancelling and clicking again must still allow requesting access.
    await click()
    expectEqual(requests, 2)
    expectEqual(openedPanes, 0)

    access = .granted
    await click()
    expectEqual(requests, 2, "An existing grant is managed in System Settings")
    expectEqual(openedPanes, 1)
    for unresolved in [AccessibilityAccessState.checking, .unavailable] {
        access = unresolved
        await click()
    }
    expectEqual(requests, 2); expectEqual(openedPanes, 1)

    access = .denied
    await AccessibilityPermission.openSettings(check: { access }, request: {
        requests += 1
        access = .granted
    }, openPane: {
        fail("Even a grant during the request must not trigger a second navigation")
    })
    expectEqual(requests, 3)
}
