import AppKit
import RemoteDictateCore

@MainActor
final class SettingsWindowController: NSWindowController {
    var settings: AppSettings { didSet { draft = settings; loadFields() } }
    private var draft: AppSettings
    private let onSave: (AppSettings) -> Void
    private let sourcesView = DictationSourcesView(sources: [])

    init(settings: AppSettings, onSave: @escaping (AppSettings) -> Void) {
        self.settings = settings; self.draft = settings; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 326),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remote Dictate Helper Settings"
        // One settings pane with a stable size; only the app list scrolls.
        window.contentMinSize = NSSize(width: 500, height: 326)
        window.contentMaxSize = window.contentMinSize
        window.center()
        super.init(window: window)
        buildContent(); loadFields()
    }
    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let scope = NSTextField(wrappingLabelWithString:
            "Works automatically in Apple Screen Sharing only.\nOther remote desktop apps have not been tested.")
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scope.textColor = .secondaryLabelColor
        let heading = NSTextField(labelWithString: "Dictation apps")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Use these apps' usual shortcuts to dictate into the remote Mac.")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor

        let body = NSStackView(views: [scope, heading, explanation, sourcesView])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        body.setCustomSpacing(18, after: scope)
        body.setCustomSpacing(4, after: heading)
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
    @objc private func save() { draft.sources = sourcesView.sources; onSave(draft); close() }
    @objc private func cancel() { close() }
}
