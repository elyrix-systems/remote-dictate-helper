import AppKit
import UniformTypeIdentifiers
import RemoteDictateCore

/// Shared app picker for first-run setup and Settings. Icons come from locally
/// installed apps; an uninstalled source uses the standard generic app symbol.
@MainActor
final class DictationSourcesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var sources: [DictationSource] { didSet { table.reloadData(); updateRemove() } }
    var onChange: (([DictationSource]) -> Void)?
    private let table = NSTableView()
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    init(sources: [DictationSource]) {
        self.sources = sources
        super.init(frame: .zero)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: .init("app")); column.width = 440; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.style = .plain
        table.rowHeight = 32; table.intercellSpacing = .zero; table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Dictation apps handled in Apple Screen Sharing")
        scroll.documentView = table
        let add = NSButton(title: "Add App…", target: self, action: #selector(addApp))
        remove.target = self; remove.action = #selector(removeApp)
        for button in [add, remove] { button.bezelStyle = .rounded; button.controlSize = .small }
        let buttons = NSStackView(views: [add, remove]); buttons.spacing = 8
        for view in [scroll, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.heightAnchor.constraint(equalToConstant: 102),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor), buttons.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateRemove()
    }
    required init?(coder: NSCoder) { nil }
    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DictationAppCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView(); cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon); cell.imageView = icon
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = sources[row].name
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sources[row].bundleIdentifier) {
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            cell.imageView?.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateRemove() }
    private func updateRemove() { remove.isEnabled = sources.indices.contains(table.selectedRow) }
    @objc private func addApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "Add Dictation App"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              identifier != Bundle.main.bundleIdentifier, identifier != "com.apple.ScreenSharing" else { return }
        if !sources.contains(where: { $0.bundleIdentifier == identifier }) {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            sources.append(DictationSource(bundleIdentifier: identifier, name: name))
        }
        table.reloadData(); onChange?(sources)
        if let row = sources.firstIndex(where: { $0.bundleIdentifier == identifier }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateRemove()
    }
    @objc private func removeApp() {
        guard sources.indices.contains(table.selectedRow) else { return }
        sources.remove(at: table.selectedRow); table.reloadData(); updateRemove(); onChange?(sources)
    }
}
