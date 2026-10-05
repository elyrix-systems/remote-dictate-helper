/// Setup never grants permission or assumes that a remote field received text.
public struct SetupReadiness: Equatable, Sendable {
    public var installed: Bool
    public var accessibility: Bool
    public var inputReady: Bool
    public var sourceCount: Int
    public init(installed: Bool, accessibility: Bool, inputReady: Bool, sourceCount: Int) {
        self.installed = installed; self.accessibility = accessibility
        self.inputReady = inputReady; self.sourceCount = sourceCount
    }
    public var canFinish: Bool { installed && accessibility && inputReady && sourceCount > 0 }
}
