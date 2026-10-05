import RemoteDictateCore

func testSetupReadiness() {
    let ready = SetupReadiness(installed: true, accessibility: true, inputReady: true, sourceCount: 1)
    expectTrue(ready.canFinish)
    var missing = ready; missing.accessibility = false; expectFalse(missing.canFinish)
    missing = ready; missing.inputReady = false; expectFalse(missing.canFinish)
    missing = ready; missing.sourceCount = 0; expectFalse(missing.canFinish)
    missing = ready; missing.installed = false; expectFalse(missing.canFinish)
}
