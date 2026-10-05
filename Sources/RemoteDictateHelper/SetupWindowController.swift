import AppKit
import RemoteDictateCore

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    static let completionKey = "setupCompletedV1"
    private let permissionStatus = NSTextField(labelWithString: "Not granted")
    private let permissionButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    private let finishButton = NSButton(title: "Start Using Remote Dictate Helper", target: nil, action: nil)
    private let sourcesView: DictationSourcesView
    private let onPermissionGranted: () -> Bool
    private var timer: Timer?
    private var previousTrust = false
    private var inputReady = false
    private let installed = !Bundle.main.bundleURL.path.hasPrefix("/Volumes/")

    init(sources: [DictationSource], onSourcesChanged: @escaping ([DictationSource]) -> Void,
         onPermissionGranted: @escaping () -> Bool) {
        sourcesView = DictationSourcesView(sources: sources)
        sourcesView.onChange = onSourcesChanged
        self.onPermissionGranted = onPermissionGranted
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 508),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Remote Dictate Helper"
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        buildContent(); window.center()
    }
    required init?(coder: NSCoder) { nil }
    func updateSources(_ sources: [DictationSource]) { sourcesView.sources = sources }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        previousTrust = false
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    private func section(_ number: String, title: String, detail: String, controls: [NSView]) -> NSView {
        let heading = label("\(number)   \(title)", size: 14, weight: .semibold)
        let body = label(detail); body.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, body] + controls)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    private func buildContent() {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])
        let title = label("Your voice. On the other Mac.", size: 22, weight: .semibold)
        let subtitle = label("Dictate locally. Paste through Apple Screen Sharing.")
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle]); titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 6
        let header = NSStackView(views: [icon, titleStack]); header.spacing = 16; header.alignment = .centerY

        permissionButton.target = self; permissionButton.action = #selector(requestPermission)
        permissionButton.bezelStyle = .rounded; permissionButton.isEnabled = installed
        permissionStatus.font = .systemFont(ofSize: 12, weight: .medium)
        let permissionRow = NSStackView(views: [permissionButton, permissionStatus]); permissionRow.spacing = 12
        let permissionDetail = installed
            ? "Allow the helper to intercept dictation paste and use Screen Sharing’s clipboard menu. Enable Remote Dictate Helper in Accessibility, then return here."
            : "First drag this app to Applications, eject the disk image and open the installed copy. Grant permission to that copy."
        let first = section("1", title: "Allow Accessibility", detail: permissionDetail, controls: [permissionRow])

        let second = section("2", title: "Choose your dictation apps", detail: "Use clipboard paste and keep your previous clipboard in the dictation app’s settings. Your recording shortcut stays the same.", controls: [sourcesView])
        sourcesView.widthAnchor.constraint(equalTo: second.widthAnchor).isActive = true

        let privacy = label("The helper does not record audio or upload your clipboard.", size: 12)
        privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, first, second, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        for view in [first, second] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        finishButton.target = self; finishButton.action = #selector(finish); finishButton.bezelStyle = .rounded; finishButton.keyEquivalent = "\r"
        finishButton.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(finishButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            finishButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            finishButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: finishButton.topAnchor, constant: -20)
        ])
    }
    private func refresh() {
        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        if trusted && !previousTrust { inputReady = onPermissionGranted() }
        if !trusted { inputReady = false }
        previousTrust = trusted
        permissionStatus.stringValue = trusted ? (inputReady ? "Allowed ✓" : "Reopen the helper") : "Not granted"
        permissionStatus.textColor = trusted && inputReady ? .systemGreen : .secondaryLabelColor
        finishButton.isEnabled = SetupReadiness(installed: installed, accessibility: trusted, inputReady: inputReady,
            sourceCount: sourcesView.sources.count).canFinish
    }
    @objc private func requestPermission() {
        guard installed else { return }
        _ = AccessibilityPermission.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }
    @objc private func finish() {
        refresh(); guard finishButton.isEnabled else { return }
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        close()
    }
}
