/// AutocompleteWindowController.swift
/// Disco — system-wide emoji autocomplete
///
/// The floating emoji picker popup that appears when the user types the trigger
/// character. Implemented as a borderless, non-activating NSPanel so it floats
/// above all other windows without stealing keyboard focus from the host app.
///
/// Layout (bottom to top):
///   [ alias label ]   — monospaced shortcode, e.g. ":tada:"
///   [ hairline sep ]
///   [ emoji grid  ]   — NSCollectionView, 10 columns, 38×38pt cells
///
/// Selection model:
///   - selectedIndex tracks the highlighted cell
///   - Arrow keys call moveUp()/moveDown() from AppDelegate
///   - Hover over a cell updates selection in real time
///   - Click or Enter/Tab calls selectCurrent(), which fires onSelect

import Cocoa

// MARK: - Window Controller

final class AutocompleteWindowController: NSWindowController {

    /// Called when the user confirms a selection (Enter, Tab, or click).
    var onSelect: ((EmojiEntry) -> Void)?

    /// Called when the popup should be dismissed without a selection (Escape,
    /// or clicking outside — though outside-click is handled by the panel's
    /// .transient behaviour via AppDelegate's cancelCapture).
    var onCancel: (() -> Void)?

    private let collectionView = NSCollectionView()
    private let aliasLabel     = NSTextField(labelWithString: "")
    private var emoji: [EmojiEntry] = []
    private var selectedIndex = 0

    // MARK: Layout constants
    // Adjust cellSize and cols together to resize the grid.
    // popupLimit in EmojiDatabase should ideally equal cols × some integer rows.
    private let cellSize: CGFloat    = 38
    private let cols                 = 10
    private let padding: CGFloat     = 8
    private let labelHeight: CGFloat = 22
    private let separatorH: CGFloat  = 1

    init() {
        // NSPanel with .nonactivatingPanel keeps keyboard focus in the host app.
        // .fullSizeContentView + .borderless removes the title bar chrome entirely.
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level           = .popUpMenu    // above all regular windows
        panel.isOpaque        = false
        panel.backgroundColor = .clear
        panel.hasShadow       = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // NSVisualEffectView provides the system blur/vibrancy behind the popup.
        // .menu material matches the look of system menus and popovers.
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material         = .menu
        blur.blendingMode     = .behindWindow
        blur.state            = .active
        blur.wantsLayer       = true
        blur.layer?.cornerRadius  = 10
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)

        // Alias label — shows the shortcode of the currently highlighted emoji.
        aliasLabel.font      = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        aliasLabel.textColor = .secondaryLabelColor
        aliasLabel.alignment = .center
        aliasLabel.frame     = NSRect(x: 0, y: 0, width: 0, height: labelHeight)
        blur.addSubview(aliasLabel)

        // Hairline separator between the alias label and the emoji grid.
        let sep = NSBox()
        sep.boxType = .separator
        blur.addSubview(sep)

        // Flow layout — fixed item size, no spacing, padding applied as section insets.
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize               = NSSize(width: cellSize, height: cellSize)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing     = 0
        layout.sectionInset           = NSEdgeInsets(top: padding, left: padding,
                                                     bottom: padding, right: padding)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller   = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground       = false

        collectionView.collectionViewLayout = layout
        collectionView.delegate             = self
        collectionView.dataSource           = self
        collectionView.backgroundColors     = [.clear]
        collectionView.isSelectable         = true
        collectionView.register(EmojiCell.self,
                                forItemWithIdentifier: .init("EmojiCell"))

        scrollView.documentView = collectionView
        blur.addSubview(scrollView)

        // Associated objects are used to retrieve the scrollView and separator
        // during layout updates without storing them as ivars on the controller.
        // This keeps the panel's content view self-contained.
        objc_setAssociatedObject(blur, &AssocKeys.scrollView, scrollView, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(blur, &AssocKeys.separator,  sep,        .OBJC_ASSOCIATION_RETAIN)
    }

    private enum AssocKeys {
        static var scrollView = 0
        static var separator  = 1
    }

    // MARK: - Show / Hide

    /// Updates content and makes the popup visible near `point` (screen coordinates,
    /// bottom-left origin). Typically called every keystroke while capturing.
    func show(emoji newEmoji: [EmojiEntry], near point: NSPoint) {
        emoji = newEmoji
        selectedIndex = 0
        updateWindowSize()
        collectionView.reloadData()
        highlightCell(at: 0)
        updateAliasLabel()
        positionWindow(near: point)
        if !(window?.isVisible ?? false) { window?.orderFront(nil) }
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - Layout

    /// Recalculates and applies window size based on the current emoji count.
    /// The window is always exactly wide enough for `cols` columns and tall enough
    /// for the required number of rows plus the alias label and separator.
    private func updateWindowSize() {
        guard let blur = window?.contentView?.subviews.first as? NSVisualEffectView else { return }
        let scrollView = objc_getAssociatedObject(blur, &AssocKeys.scrollView) as? NSScrollView
        let sep        = objc_getAssociatedObject(blur, &AssocKeys.separator)  as? NSBox

        let count  = emoji.count
        let rows   = max(1, Int(ceil(Double(count) / Double(cols))))
        let gridW  = CGFloat(cols) * cellSize + padding * 2
        let gridH  = CGFloat(rows) * cellSize + padding * 2
        let totalH = gridH + separatorH + labelHeight
        let totalW = gridW

        window?.setContentSize(NSSize(width: totalW, height: totalH))

        scrollView?.frame    = NSRect(x: 0, y: labelHeight + separatorH, width: totalW, height: gridH)
        sep?.frame           = NSRect(x: 0, y: labelHeight,              width: totalW, height: separatorH)
        aliasLabel.frame     = NSRect(x: 0, y: 0,                        width: totalW, height: labelHeight)
        collectionView.frame = NSRect(x: 0, y: 0,                        width: totalW, height: gridH)
    }

    /// Positions the popup below the caret. Nudges it left or right if it would
    /// overflow the screen, and flips it above the caret if it would go below
    /// the bottom edge of the visible screen area.
    private func positionWindow(near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
              ?? NSScreen.main else { return }
        let wf = window!.frame
        var x = point.x
        var y = point.y - wf.height - 4
        let sf = screen.visibleFrame
        if x + wf.width > sf.maxX { x = sf.maxX - wf.width }
        if x < sf.minX            { x = sf.minX }
        if y < sf.minY            { y = point.y + 20 }  // flip: show above the caret
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Selection

    /// Inserts the currently highlighted emoji and fires `onSelect`.
    func selectCurrent() {
        guard selectedIndex < emoji.count else { return }
        let entry = emoji[selectedIndex]
        hide()
        onSelect?(entry)
    }

    func moveDown() {
        moveTo(min(selectedIndex + 1, emoji.count - 1))
    }

    func moveUp() {
        moveTo(max(selectedIndex - 1, 0))
    }

    private func moveTo(_ idx: Int) {
        guard idx != selectedIndex else { return }
        let old = selectedIndex
        selectedIndex = idx
        // Reload only the two affected cells rather than the whole collection.
        collectionView.reloadItems(at: [.init(item: old, section: 0),
                                        .init(item: idx, section: 0)])
        collectionView.scrollToItems(at: [.init(item: idx, section: 0)],
                                     scrollPosition: .nearestHorizontalEdge)
        updateAliasLabel()
    }

    private func highlightCell(at idx: Int) {
        guard idx < emoji.count else { return }
        collectionView.reloadItems(at: [.init(item: idx, section: 0)])
        updateAliasLabel()
    }

    private func updateAliasLabel() {
        guard selectedIndex < emoji.count else { aliasLabel.stringValue = ""; return }
        aliasLabel.stringValue = ":\(emoji[selectedIndex].primaryAlias):"
    }
}

// MARK: - NSCollectionViewDataSource / Delegate

extension AutocompleteWindowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        emoji.count
    }

    func collectionView(_ cv: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: .init("EmojiCell"), for: indexPath) as! EmojiCell
        cell.configure(emoji: emoji[indexPath.item].emoji,
                       selected: indexPath.item == selectedIndex)
        cell.onTap = { [weak self] in
            guard let self else { return }
            self.selectedIndex = indexPath.item
            self.selectCurrent()
        }
        cell.onHover = { [weak self] in
            guard let self else { return }
            self.moveTo(indexPath.item)
        }
        return cell
    }
}

// MARK: - EmojiCell

/// A single cell in the popup grid. Displays one emoji character and responds to
/// hover (for mouse-driven selection) and click (for mouse-driven commit).
final class EmojiCell: NSCollectionViewItem {
    var onTap: (() -> Void)?
    var onHover: (() -> Void)?

    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        view = HoverView(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        view.wantsLayer = true
        view.layer?.cornerRadius = 6

        label.font             = NSFont.systemFont(ofSize: 22)
        label.alignment        = .center
        label.frame            = view.bounds
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        view.addGestureRecognizer(click)

        (view as? HoverView)?.onHover = { [weak self] in self?.onHover?() }
    }

    func configure(emoji: String, selected: Bool) {
        label.stringValue = emoji
        view.layer?.backgroundColor = selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.75).cgColor
            : .clear
    }

    @objc private func tapped() { onTap?() }
}

// MARK: - HoverView

/// An NSView subclass that fires a callback when the mouse enters its bounds.
/// Used to implement hover-to-highlight in the emoji grid without polling.
private final class HoverView: NSView {
    var onHover: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
}
