import AppKit
import RemoteDictateCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    // Retain the existing preference so an upgrade does not repeat first use.
    static let completionKey = "setupCompletedV1"
    var settings: AppSettings { didSet { draft = settings; loadFields() } }
    private var draft: AppSettings
    private let onSave: (AppSettings) throws -> Void
    private let onPermissionGranted: () -> Bool
    private let sourcesView = DictationSourcesView(sources: [])
    private let permissionStatus = NSTextField(labelWithString: "Not granted")
    private let permissionButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    private let installed = !Bundle.main.bundleURL.path.hasPrefix("/Volumes/")
    private var timer: Timer?
    private var previousTrust = false
    private var inputReady = false

    init(settings: AppSettings, onSave: @escaping (AppSettings) throws -> Void,
         onPermissionGranted: @escaping () -> Bool) {
        self.settings = settings; self.draft = settings; self.onSave = onSave
        self.onPermissionGranted = onPermissionGranted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remote Dictate Helper Settings"
        // One settings pane with a stable size; only the app list scrolls.
        window.contentMinSize = NSSize(width: 540, height: 440)
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
        previousTrust = false
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
            "Works automatically in Apple Screen Sharing only.\nOther remote desktop apps have not been tested.")
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scope.textColor = .secondaryLabelColor
        let permissionHeading = NSTextField(labelWithString: "Accessibility")
        permissionHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let permissionDetail = NSTextField(wrappingLabelWithString: installed
            ? "Allow the helper to intercept dictation paste and use Screen Sharing’s clipboard menu. Enable the permission, then return here."
            : "Move this app to Applications, eject the disk image and open the installed copy before granting permission.")
        permissionDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionDetail.textColor = .secondaryLabelColor
        permissionButton.target = self; permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded; permissionButton.isEnabled = installed
        permissionStatus.font = .systemFont(ofSize: 12, weight: .medium)
        let permissionRow = NSStackView(views: [permissionButton, permissionStatus])
        permissionRow.spacing = 12; permissionRow.alignment = .centerY
        let heading = NSTextField(labelWithString: "Dictation apps")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Use your usual recording shortcuts. In each app, enable clipboard paste and keep your previous clipboard.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor

        let privacy = NSTextField(labelWithString: "The helper does not record audio or upload your clipboard.")
        privacy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        privacy.textColor = .secondaryLabelColor
        let body = NSStackView(views: [scope, permissionHeading, permissionDetail, permissionRow,
                                       heading, explanation, sourcesView, privacy])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        body.setCustomSpacing(18, after: scope)
        body.setCustomSpacing(4, after: permissionHeading)
        body.setCustomSpacing(18, after: permissionRow)
        body.setCustomSpacing(4, after: heading)
        body.setCustomSpacing(16, after: sourcesView)
        body.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(body)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        for button in [cancel, save] {
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        window?.defaultButtonCell = save.cell as? NSButtonCell
        let footer = NSStackView(views: [cancel, save]); footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(footer)

        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scope.widthAnchor.constraint(equalTo: body.widthAnchor),
            permissionDetail.widthAnchor.constraint(equalTo: body.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: body.widthAnchor),
            sourcesView.widthAnchor.constraint(equalTo: body.widthAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.topAnchor.constraint(greaterThanOrEqualTo: body.bottomAnchor, constant: 20)
        ])
    }
    private func loadFields() {
        guard isWindowLoaded else { return }
        sourcesView.sources = draft.sources
    }
    private func refreshPermission() {
        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        if trusted && !previousTrust { inputReady = onPermissionGranted() }
        if !trusted { inputReady = false }
        previousTrust = trusted
        permissionStatus.stringValue = trusted ? (inputReady ? "Allowed ✓" : "Reopen the helper") : "Not granted"
        permissionStatus.textColor = trusted && inputReady ? .systemGreen : .secondaryLabelColor
    }
    @objc private func requestPermission() {
        guard installed else { return }
        _ = AccessibilityPermission.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshPermission()
    }
    @objc private func save() {
        draft.sources = sourcesView.sources
        do { try onSave(draft) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Settings could not be saved"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        previousTrust = false; refreshPermission()
        if SettingsReadiness(installed: installed, accessibility: previousTrust, inputReady: inputReady,
                             sourceCount: draft.sources.count).canCompleteInitialConfiguration {
            UserDefaults.standard.set(true, forKey: Self.completionKey)
        }
        close()
    }
    @objc private func cancel() { close() }
}
