import AppKit

/// Finder’s search scope bar: “Search: This Mac | Macintosh HD | “Folder””, plus what to match.
/// It spans the area under the toolbar, with its controls in the bottom `barHeight` points.
final class SearchScopeBar: NSView {
    static let barHeight: CGFloat = 34

    var onSelectScope: ((SearchScope) -> Void)?
    var onSelectContents: ((Bool) -> Void)?

    private let label = NSTextField(labelWithString: "Search:")
    private let scopeStack = NSStackView()
    private let matchPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var scopes: [SearchScope] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        scopeStack.spacing = 4

        matchPopup.addItems(withTitles: ["Name & Contents", "Name Only"])
        matchPopup.bezelStyle = .accessoryBarAction
        matchPopup.controlSize = .small
        matchPopup.font = .systemFont(ofSize: 12)
        matchPopup.target = self
        matchPopup.action = #selector(matchChanged(_:))
        matchPopup.toolTip = "Match file names and contents (like Finder), or names only"

        for v in [label, scopeStack, matchPopup] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let row = bottomAnchor
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: row, constant: -SearchScopeBar.barHeight / 2),
            scopeStack.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            scopeStack.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            scopeStack.trailingAnchor.constraint(lessThanOrEqualTo: matchPopup.leadingAnchor, constant: -8),
            matchPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            matchPopup.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        scopeStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(scopes: [(scope: SearchScope, title: String)], selected: SearchScope, contents: Bool) {
        self.scopes = scopes.map(\.scope)
        scopeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, entry) in scopes.enumerated() {
            let button = NSButton(title: entry.title, target: self, action: #selector(scopeClicked(_:)))
            button.bezelStyle = .accessoryBar
            button.setButtonType(.pushOnPushOff)
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingMiddle
            button.tag = index
            button.state = entry.scope == selected ? .on : .off
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            scopeStack.addArrangedSubview(button)
        }
        matchPopup.selectItem(at: contents ? 0 : 1)
    }

    @objc private func scopeClicked(_ sender: NSButton) {
        for case let button as NSButton in scopeStack.arrangedSubviews { button.state = button === sender ? .on : .off }
        onSelectScope?(scopes[sender.tag])
    }

    @objc private func matchChanged(_ sender: NSPopUpButton) {
        onSelectContents?(sender.indexOfSelectedItem == 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : 0, width: bounds.width, height: 1).fill()
    }
}
