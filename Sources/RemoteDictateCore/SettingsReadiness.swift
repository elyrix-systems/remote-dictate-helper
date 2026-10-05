/// Settings stay editable before permission is granted. Only a usable installed
/// configuration completes first use; permission loss reopens the same window.
public struct SettingsReadiness: Equatable, Sendable {
    public var installed: Bool
    public var accessibility: Bool
    public var inputReady: Bool
    public var sourceCount: Int
    public init(installed: Bool, accessibility: Bool, inputReady: Bool, sourceCount: Int) {
        self.installed = installed; self.accessibility = accessibility
        self.inputReady = inputReady; self.sourceCount = sourceCount
    }
    public var canCompleteInitialConfiguration: Bool { installed && accessibility && inputReady && sourceCount > 0 }
    public static func shouldOpenOnLaunch(completed: Bool, accessibility: Bool) -> Bool {
        !completed || !accessibility
    }
}
