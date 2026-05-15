/// BrowserWindowController.swift
/// Disco — system-wide emoji autocomplete
///
/// The full emoji browser window, opened via the menu bar 🪩 → Browse Emoji…
///
/// Layout:
///   [ search field ]
///   ─────────────────────────────────
///   [ category list ] | [ emoji grid ]
///   ─────────────────────────────────
///   [ emoji preview  |  alias  |  Copy  Insert ]
///
/// The window is resizable with a minimum size of 560×420. Size and position are
/// persisted via NSWindow's built-in frame autosave mechanism (key: "DiscoBrowser").
///
/// Interaction model:
///   - Single-click a cell → previews in the bottom bar
///   - Double-click a cell → inserts and closes the window
///   - Insert button or Enter → inserts and closes
///   - Copy button → copies to clipboard, flashes "Copied!" feedback
///   - Closing the window hides it rather than deallocating (windowShouldClose
///     returns false), so reopening it is fast and preserves category/scroll state.

import Cocoa

final class BrowserWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user inserts an emoji (double-click, Insert button, or Enter).
    /// The closure is set by AppDelegate and handles the actual text injection.
    var onInsert: ((EmojiEntry) -> Void)?

    private let searchField    = NSSearchField()
    private let categoryTable  = NSTableView()
    private let collectionView = NSCollectionView()
    private let previewEmoji   = NSTextField(labelWithString: "")
    private let previewAlias   = NSTextField(labelWithString: "")
    private let copyBtn        = NSButton(title: "Copy",   target: nil, action: nil)
    private let insertBtn      = NSButton(title: "Insert", target: nil, action: nil)

    private var categories: [String] = []
    private var displayEmoji: [EmojiEntry] = []
    private var selectedEntry: EmojiEntry?
    private var activeCategory = "All"
    private var searchQuery    = ""

    // MARK: - Init

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title   = "Disco — Emoji Browser 🪩"
        win.minSize = NSSize(width: 560, height: 420)

        // Persist window frame across launches. center() only fires when there's
        // no saved frame (i.e. the very first launch).
        win.setFrameAutosaveName("DiscoBrowser")
        if win.frame.origin == .zero { win.center() }

        super.init(window: win)
        win.delegate = self
        buildUI()
        loadCategories()
        filter()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI Construction

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true

        // ── Search bar ─────────────────────────────────────────────────────────
        searchField.placeholderString = "Search emoji…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        // sendsSearchStringImmediately filters on every keystroke without waiting
        // for the user to press Enter.
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        cv.addSubview(searchField)

        let topSep = makeSeparator()
        cv.addSubview(topSep)

        // ── Split view (category sidebar + emoji grid) ─────────────────────────
        let split = NSSplitView()
        split.isVertical   = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(split)

        // Category sidebar
        let sideScroll = NSScrollView()
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers  = true
        sideScroll.borderType          = .noBorder

        let catCol = NSTableColumn(identifier: .init("cat"))
        catCol.title = ""
        categoryTable.addTableColumn(catCol)
        categoryTable.headerView    = nil
        categoryTable.rowHeight     = 26
        categoryTable.focusRingType = .none
        categoryTable.delegate      = self
        categoryTable.dataSource    = self
        categoryTable.target        = self
        categoryTable.action        = #selector(categorySelected)
        sideScroll.documentView     = categoryTable
        sideScroll.frame.size.width = 150

        // Emoji grid
        let gridScroll = NSScrollView()
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers  = true
        gridScroll.drawsBackground     = false
        gridScroll.borderType          = .noBorder

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize               = NSSize(width: 44, height: 44)
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing     = 2
        layout.sectionInset           = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors     = [.clear]
        collectionView.isSelectable         = true
        collectionView.delegate             = self
        collectionView.dataSource           = self
        collectionView.register(BrowserCell.self,
                                forItemWithIdentifier: .init("BCell"))

        // NSCollectionViewDelegate doesn't have a didDoubleClick method, so we
        // attach a gesture recognizer directly to the collection view.
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(dbl)

        gridScroll.documentView = collectionView

        split.addArrangedSubview(sideScroll)
        split.addArrangedSubview(gridScroll)

        // ── Bottom preview bar ─────────────────────────────────────────────────
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(bottomBar)

        let botSep = makeSeparator()
        cv.addSubview(botSep)

        previewEmoji.font      = NSFont.systemFont(ofSize: 38)
        previewEmoji.alignment = .center
        previewEmoji.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(previewEmoji)

        previewAlias.font        = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        previewAlias.textColor   = .secondaryLabelColor
        previewAlias.stringValue = "Select an emoji"
        previewAlias.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(previewAlias)

        copyBtn.bezelStyle  = .rounded
        copyBtn.target      = self
        copyBtn.action      = #selector(copySelected)
        copyBtn.isEnabled   = false
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(copyBtn)

        // keyEquivalent = "\r" makes Enter trigger Insert when the button is enabled.
        insertBtn.bezelStyle    = .rounded
        insertBtn.keyEquivalent = "\r"
        insertBtn.target        = self
        insertBtn.action        = #selector(insertSelected)
        insertBtn.isEnabled     = false
        insertBtn.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(insertBtn)

        // ── Auto Layout ────────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),

            topSep.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            topSep.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            topSep.heightAnchor.constraint(equalToConstant: 1),

            split.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: botSep.topAnchor),

            botSep.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            botSep.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            botSep.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            botSep.heightAnchor.constraint(equalToConstant: 1),

            bottomBar.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 68),

            previewEmoji.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            previewEmoji.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            previewEmoji.widthAnchor.constraint(equalToConstant: 52),

            previewAlias.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            previewAlias.leadingAnchor.constraint(equalTo: previewEmoji.trailingAnchor, constant: 6),
            previewAlias.trailingAnchor.constraint(equalTo: copyBtn.leadingAnchor, constant: -12),

            insertBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            insertBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            insertBtn.widthAnchor.constraint(equalToConstant: 72),

            copyBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            copyBtn.trailingAnchor.constraint(equalTo: insertBtn.leadingAnchor, constant: -8),
            copyBtn.widthAnchor.constraint(equalToConstant: 72),
        ])

        // Set the sidebar divider position after layout has resolved.
        DispatchQueue.main.async { split.setPosition(150, ofDividerAt: 0) }
    }

    private func makeSeparator() -> NSBox {
        let s = NSBox()
        s.boxType = .separator
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    // MARK: - Data

    private func loadCategories() {
        categories = ["All", "Frequently Used"] + EmojiDatabase.shared.categories
        categoryTable.reloadData()
        categoryTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    /// Rebuilds `displayEmoji` based on the current search query and active category,
    /// then reloads the collection view.
    private func filter() {
        let db = EmojiDatabase.shared
        if !searchQuery.isEmpty {
            // Search across the full database, not just the current category.
            displayEmoji = db.search(query: searchQuery, limit: 200)
        } else {
            switch activeCategory {
            case "All":              displayEmoji = db.allEmoji
            case "Frequently Used": displayEmoji = db.popular(limit: 60)
            default:                displayEmoji = db.emoji(forCategory: activeCategory)
            }
        }
        collectionView.reloadData()
        if !displayEmoji.isEmpty {
            collectionView.scrollToItems(at: [.init(item: 0, section: 0)], scrollPosition: .top)
        }
    }

    private func selectEntry(_ entry: EmojiEntry) {
        selectedEntry = entry
        previewEmoji.stringValue = entry.emoji
        previewAlias.stringValue = ":\(entry.primaryAlias):"
        copyBtn.isEnabled   = true
        insertBtn.isEnabled = true
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        searchQuery = searchField.stringValue
        filter()
    }

    @objc private func categorySelected() {
        let row = categoryTable.selectedRow
        guard row >= 0, row < categories.count else { return }
        activeCategory = categories[row]
        searchField.stringValue = ""
        searchQuery = ""
        filter()
    }

    @objc private func copySelected() {
        guard let e = selectedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.emoji, forType: .string)
        EmojiDatabase.shared.recordUsage(e)
        // Brief "Copied!" label feedback, then restore.
        copyBtn.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyBtn.title = "Copy"
        }
    }

    @objc private func insertSelected() {
        guard let e = selectedEntry else { return }
        onInsert?(e)
        window?.orderOut(nil)
    }

    /// Handles double-click on the collection view. NSCollectionViewDelegate
    /// provides no built-in double-click hook, so we hit-test the gesture location
    /// against the collection view's item index paths manually.
    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              indexPath.item < displayEmoji.count else { return }
        selectEntry(displayEmoji[indexPath.item])
        insertSelected()
    }

    /// Hide rather than close so the window retains its state (scroll position,
    /// selected category, search query) for the next time it's opened.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window?.orderOut(nil)
        return false
    }
}

// MARK: - Category TableView

extension BrowserWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(labelWithString: categories[row])
        f.font = NSFont.systemFont(ofSize: 12)
        return f
    }
}

// MARK: - Emoji CollectionView

extension BrowserWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayEmoji.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: .init("BCell"), for: indexPath) as! BrowserCell
        cell.configure(with: displayEmoji[indexPath.item])
        return cell
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first else { return }
        selectEntry(displayEmoji[path.item])
    }
}

// MARK: - BrowserCell

/// A single cell in the browser grid. Larger than the popup cells (44×44pt, 26pt emoji)
/// and uses the system selection highlight via `isSelected` didSet rather than a custom
/// hover tracker.
final class BrowserCell: NSCollectionViewItem {
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        view.wantsLayer = true
        view.layer?.cornerRadius = 8

        label.font             = NSFont.systemFont(ofSize: 26)
        label.alignment        = .center
        label.frame            = view.bounds
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    }

    func configure(with entry: EmojiEntry) {
        label.stringValue = entry.emoji
        // Tooltip provides shortcode on hover without cluttering the grid.
        view.toolTip = ":\(entry.primaryAlias):"
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.7).cgColor
                : .clear
        }
    }
}
