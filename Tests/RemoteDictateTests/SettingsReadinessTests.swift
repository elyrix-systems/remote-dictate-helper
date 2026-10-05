import RemoteDictateCore

func testSettingsReadiness() {
    let ready = SettingsReadiness(installed: true, accessibility: true, inputReady: true, sourceCount: 1)
    expectTrue(ready.canCompleteInitialConfiguration)
    var missing = ready; missing.accessibility = false; expectFalse(missing.canCompleteInitialConfiguration)
    missing = ready; missing.inputReady = false; expectFalse(missing.canCompleteInitialConfiguration)
    missing = ready; missing.sourceCount = 0; expectFalse(missing.canCompleteInitialConfiguration)
    missing = ready; missing.installed = false; expectFalse(missing.canCompleteInitialConfiguration)
    // First launch and a lost grant open the same Settings window. Upgrades with
    // a retained completion preference and valid permission remain unobtrusive.
    expectTrue(SettingsReadiness.shouldOpenOnLaunch(completed: false, accessibility: false))
    expectTrue(SettingsReadiness.shouldOpenOnLaunch(completed: false, accessibility: true))
    expectTrue(SettingsReadiness.shouldOpenOnLaunch(completed: true, accessibility: false))
    expectFalse(SettingsReadiness.shouldOpenOnLaunch(completed: true, accessibility: true))
}
