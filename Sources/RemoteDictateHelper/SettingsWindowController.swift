import AppKit
import RemoteDictateCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    // Retain the existing preference so an upgrade does not repeat first use.
    static let completionKey = "setupCompletedV1"
    var settings: AppSettings {
        get { sourceSettings.value }
        set { sourceSettings.value = newValue; loadFields() }
    }
    private let sourceSettings: DictationSourceSettings
    private let inputIsReady: () -> Bool
    private let beforeOpeningSystemSettings: () -> Void
    private let launchAtLogin: LaunchAtLogin
    private let loginStatus = NSTextField(labelWithString: "")
    private lazy var sourcesView = DictationSourcesView(sources: settings.sources, onChange: { [weak self] sources in
        guard let self else { throw CancellationError() }
        try self.sourceSettings.updateSources(sources)
        self.refreshPermission()
    })
    private let permissionStatus = NSTextField(labelWithString: "Not granted")
    private let permissionButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    private let installed = !Bundle.main.bundleURL.path.hasPrefix("/Volumes/")
    private var timer: Timer?
    private var inputReady = false
    private var permissionRequest: Task<Void, Never>?

    init(settings: AppSettings, launchAtLogin: LaunchAtLogin, onSave: @escaping (AppSettings) throws -> Void,
         beforeOpeningSystemSettings: @escaping () -> Void,
         inputIsReady: @escaping () -> Bool) {
        self.sourceSettings = DictationSourceSettings(value: settings, persist: onSave)
        self.inputIsReady = inputIsReady
        self.beforeOpeningSystemSettings = beforeOpeningSystemSettings
        self.launchAtLogin = launchAtLogin
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remote Dictate Helper Settings"
        // One settings pane with a stable size; only the app list scrolls.
        window.contentMinSize = NSSize(width: 540, height: 450)
        window.contentMaxSize = window.contentMinSize
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent(); loadFields()
    }
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refreshPermission()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let scope = NSTextField(wrappingLabelWithString:
            "Works automatically in Apple Screen Sharing and Windows App.")
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scope.textColor = .secondaryLabelColor
        let permissionHeading = NSTextField(labelWithString: "Accessibility")
        permissionHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let permissionDetail = NSTextField(wrappingLabelWithString: installed
            ? "Allow the helper to intercept and send dictation paste in supported remote windows. Enable the permission, then return here."
            : "Move this app to Applications, eject the disk image and open the installed copy before granting permission.")
        permissionDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionDetail.textColor = .secondaryLabelColor
        permissionButton.target = self; permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded; permissionButton.isEnabled = installed
        permissionStatus.font = .systemFont(ofSize: 12, weight: .medium)
        let permissionRow = NSStackView(views: [permissionButton, permissionStatus])
        permissionRow.spacing = 12; permissionRow.alignment = .centerY
        let loginHeading = NSTextField(labelWithString: "Launch at login")
        loginHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let loginButton = NSButton(title: "Open Login Items…", target: self, action: #selector(openLoginItems))
        loginButton.bezelStyle = .rounded; loginButton.isEnabled = launchAtLogin.isInstalled
        loginStatus.font = .systemFont(ofSize: 12, weight: .medium)
        loginStatus.textColor = .secondaryLabelColor
        let loginRow = NSStackView(views: [loginButton, loginStatus])
        loginRow.spacing = 12; loginRow.alignment = .centerY
        let heading = NSTextField(labelWithString: "Dictation apps")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Use your usual recording shortcuts. In each app, enable clipboard paste and keep your previous clipboard.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor

        let privacy = NSTextField(labelWithString: "The helper does not record audio or upload your clipboard.")
        privacy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        privacy.textColor = .secondaryLabelColor
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let buildLabel = NSTextField(labelWithString: "Version \(version) · Build \(build)")
        buildLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        buildLabel.textColor = .secondaryLabelColor
        buildLabel.alignment = .right
        let spacer = NSView()
        let footer = NSStackView(views: [privacy, spacer, buildLabel])
        footer.spacing = 12; footer.alignment = .firstBaseline
        for label in [privacy, buildLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let body = NSStackView(views: [scope, permissionHeading, permissionDetail, permissionRow, loginHeading, loginRow,
                                       heading, explanation, sourcesView, footer])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        body.setCustomSpacing(18, after: scope)
        body.setCustomSpacing(4, after: permissionHeading)
        body.setCustomSpacing(18, after: permissionRow)
        body.setCustomSpacing(4, after: loginHeading)
        body.setCustomSpacing(18, after: loginRow)
        body.setCustomSpacing(4, after: heading)
        body.setCustomSpacing(16, after: sourcesView)
        body.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(body)

        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scope.widthAnchor.constraint(equalTo: body.widthAnchor),
            permissionDetail.widthAnchor.constraint(equalTo: body.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: body.widthAnchor),
            sourcesView.widthAnchor.constraint(equalTo: body.widthAnchor),
            footer.widthAnchor.constraint(equalTo: body.widthAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
    }
    private func loadFields() {
        guard isWindowLoaded else { return }
        sourcesView.sources = settings.sources
    }
    private func refreshPermission() {
        loginStatus.stringValue = launchAtLogin.statusDescription
        loginStatus.textColor = launchAtLogin.isEnabled ? .systemGreen : .secondaryLabelColor
        let access = AccessibilityPermission.state
        let trusted = access == .granted
        inputReady = trusted && inputIsReady()
        switch access {
        case .checking: permissionStatus.stringValue = "Checking…"
        case .unavailable: permissionStatus.stringValue = "Unable to check access"
        case .granted: permissionStatus.stringValue = "Allowed ✓"
        case .denied: permissionStatus.stringValue = "Not granted"
        }
        // Permission remains granted while input monitoring is safely paused in System Settings.
        permissionStatus.textColor = trusted ? .systemGreen : .secondaryLabelColor
        if !UserDefaults.standard.bool(forKey: Self.completionKey),
           SettingsReadiness(installed: installed, accessibility: trusted, inputReady: inputReady,
                             sourceCount: settings.sources.count).canCompleteInitialConfiguration {
            UserDefaults.standard.set(true, forKey: Self.completionKey)
        }
    }
    @objc private func requestPermission() {
        guard installed, permissionRequest == nil else { return }
        beforeOpeningSystemSettings()
        permissionButton.isEnabled = false
        permissionRequest = Task { [weak self] in
            await AccessibilityPermission.openSettings()
            guard let self else { return }
            self.permissionRequest = nil; self.permissionButton.isEnabled = true
            self.refreshPermission()
        }
    }
    @objc private func openLoginItems() {
        beforeOpeningSystemSettings()
        launchAtLogin.openSystemSettings()
    }
}
