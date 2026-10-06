// Only injected effects: never request or change the test runner's permissions.
@MainActor
func testAccessibilitySettingsNavigation() {
    var trusted = false
    var requests = 0
    var openedPanes = 0
    let click = {
        AccessibilityPermission.openSettings(check: { trusted }, request: {
            requests += 1
        }, openPane: {
            openedPanes += 1
        })
    }

    click()
    expectEqual(requests, 1)
    expectEqual(openedPanes, 0, "The system access alert alone must own navigation")
    // Cancelling and clicking again must still allow requesting access.
    click()
    expectEqual(requests, 2)
    expectEqual(openedPanes, 0)

    trusted = true
    click()
    expectEqual(requests, 2, "An existing grant must not prompt again")
    expectEqual(openedPanes, 1)

    trusted = false
    AccessibilityPermission.openSettings(check: { trusted }, request: {
        requests += 1
        trusted = true
    }, openPane: {
        fail("Even a grant during the request must not trigger a second navigation")
    })
    expectEqual(requests, 3)
}
