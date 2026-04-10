import AppKit

let listWidth: CGFloat = 320
let logColumnWidth: CGFloat = 600
let rowHeight: CGFloat = 32
let dotSize: CGFloat = 8

// MARK: - Flipped View (Y=0 at top)

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Section Header

final class SectionHeaderView: NSView {
    override var isFlipped: Bool { true }

    private let showTopDivider: Bool

    init(title: String, rightText: String? = nil, showTopDivider: Bool = false) {
        self.showTopDivider = showTopDivider
        let height: CGFloat = showTopDivider ? 52 : 28
        super.init(frame: NSRect(x: 0, y: 0, width: listWidth, height: height))

        let topOffset: CGFloat = showTopDivider ? 24 : 0

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .tertiaryLabelColor
        label.frame.origin = NSPoint(x: 16, y: topOffset + 8)
        label.sizeToFit()
        addSubview(label)

        if let rightText {
            let right = NSTextField(labelWithString: rightText)
            right.font = .systemFont(ofSize: 10, weight: .regular)
            right.textColor = .tertiaryLabelColor
            right.alignment = .right
            right.sizeToFit()
            right.frame.origin = NSPoint(x: listWidth - right.frame.width - 16, y: topOffset + 8)
            addSubview(right)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lineColor = NSColor(white: 0.5, alpha: 0.3)

        let gradient = NSGradient(colors: [
            lineColor,
            lineColor.withAlphaComponent(0.0),
        ])!
        gradient.draw(in: NSRect(x: 16, y: bounds.height - 1, width: bounds.width - 32, height: 1), angle: 0)
    }
}

// MARK: - Subtle Row Separator

final class RowSeparatorView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: listWidth, height: 1))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.15).setFill()
        NSRect(x: 32, y: 0, width: bounds.width - 48, height: 0.5).fill()
    }
}

// MARK: - Entry Row

final class EntryRowView: NSView {
    let filename: String
    var onAction: (() -> Void)?
    var onHover: ((ScriptEntry?) -> Void)?

    let timeProvider: () -> String
    let entry: ScriptEntry

    private let dotColor: NSColor
    private let nameStr: String
    private let detailStr: String
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let timeLabel: NSTextField
    private let isRestarting: Bool
    private var pulsePhase: CGFloat = 0
    private var pulseTimer: Timer?

    init(entry: ScriptEntry, detail: String, timeProvider: @escaping () -> String,
         dotColor: NSColor, isRestarting: Bool = false) {
        self.entry = entry
        self.filename = entry.filename
        self.dotColor = dotColor
        self.nameStr = entry.displayName
        self.detailStr = detail
        self.timeProvider = timeProvider
        self.isRestarting = isRestarting

        timeLabel = NSTextField(labelWithString: timeProvider())
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right

        super.init(frame: NSRect(x: 0, y: 0, width: listWidth, height: rowHeight))

        timeLabel.frame = NSRect(x: listWidth - 68, y: (rowHeight - 15) / 2, width: 52, height: 15)
        addSubview(timeLabel)

        if isRestarting {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.pulsePhase += 0.07
                    if self.pulsePhase > .pi * 2 { self.pulsePhase -= .pi * 2 }
                    self.needsDisplay = true
                }
            }
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    override func removeFromSuperview() {
        stopPulse()
        super.removeFromSuperview()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshTime() { timeLabel.stringValue = timeProvider() }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true; needsDisplay = true
        onHover?(entry)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onAction?()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Hover highlight
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: b.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }

        // Dot with glow (pulses when restarting)
        let dotY = (b.height - dotSize) / 2
        let dotRect = NSRect(x: 16, y: dotY, width: dotSize, height: dotSize)
        let glowAlpha: CGFloat
        let glowBlur: CGFloat
        if isRestarting {
            let pulse = (sin(pulsePhase) + 1) / 2 // 0..1
            glowAlpha = 0.4 + pulse * 0.6
            glowBlur = 6 + pulse * 8
        } else {
            glowAlpha = 0.55
            glowBlur = 8
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glowBlur, color: dotColor.withAlphaComponent(glowAlpha).cgColor)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        ctx.restoreGState()
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let font = NSFont.systemFont(ofSize: 13)
        let nameX: CGFloat = 16 + dotSize + 10
        let nameMaxW = timeLabel.frame.origin.x - nameX - 4

        // Name
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let nameRect = NSRect(x: nameX, y: (b.height - font.pointSize - 4) / 2,
                              width: nameMaxW * 0.65, height: font.pointSize + 4)
        (nameStr as NSString).draw(with: nameRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: nameAttrs)

        // Detail
        if !detailStr.isEmpty {
            let drawnW = min((nameStr as NSString).size(withAttributes: nameAttrs).width, nameRect.width)
            let df = NSFont.systemFont(ofSize: 10)
            let da: [NSAttributedString.Key: Any] = [.font: df, .foregroundColor: NSColor.secondaryLabelColor]
            let dx = nameX + drawnW + 6
            let dw = timeLabel.frame.origin.x - dx - 4
            if dw > 20 {
                (detailStr as NSString).draw(with: NSRect(x: dx, y: (b.height - df.pointSize - 3) / 2, width: dw, height: df.pointSize + 3),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: da)
            }
        }
    }
}

// MARK: - Text view that won't oscillate inside a scroll view

// MARK: - Log Detail View

final class LogDetailView: NSView {
    private let pathBtn: ClickableLabel
    private let sizeLabel: ClickableLabel
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let emptyLabel: NSTextField
    private let toolbarH: CGFloat = 28
    private let inset: CGFloat = 8

    var onReveal: (() -> Void)?
    var currentFilename: String?
    var currentLogURL: URL?
    private var showGeneration = 0

    override init(frame: NSRect) {
        pathBtn = ClickableLabel()
        sizeLabel = ClickableLabel()
        textView = NSTextView()
        scrollView = NSScrollView()
        emptyLabel = NSTextField(labelWithString: "")

        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        let w = frame.width
        let h = frame.height
        let iw = w - inset * 2
        let ih = h - inset * 2

        // Clickable path label — opens Finder on click
        pathBtn.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathBtn.normalColor = .secondaryLabelColor
        pathBtn.lineBreakMode = .byTruncatingMiddle
        pathBtn.frame = NSRect(x: inset + 8, y: h - toolbarH - inset + 6, width: iw - 70, height: 16)
        pathBtn.onClick = { [weak self] in self?.onReveal?() }
        addSubview(pathBtn)

        // File size label — click to truncate log
        sizeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.normalColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.frame = NSRect(x: w - inset - 60, y: h - toolbarH - inset + 6, width: 52, height: 16)
        sizeLabel.onClick = { [weak self] in self?.truncateLog() }
        addSubview(sizeLabel)

        // Scroll + text — directly on the vibrancy background
        let textH = ih - toolbarH - 4
        scrollView.frame = NSRect(x: inset + 2, y: inset, width: iw - 4, height: textH)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let cs = scrollView.contentSize
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.frame = NSRect(origin: .zero, size: cs)
        textView.minSize = NSSize(width: 0, height: cs.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Fixed container width — panel never resizes, so no tracking needed.
        // Disabling tracking breaks the layout feedback loop that causes
        // "failed to converge" warnings.
        let containerWidth = cs.width - textView.textContainerInset.width * 2
        textView.textContainer?.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .secondaryLabelColor

        scrollView.documentView = textView
        addSubview(scrollView)

        // Use a thin scroller
        let thinScroller = ThinScroller()
        thinScroller.scrollerStyle = .overlay
        scrollView.verticalScroller = thinScroller

        // Empty state
        let emptyStyle = NSMutableParagraphStyle()
        emptyStyle.alignment = .center
        emptyLabel.attributedStringValue = NSAttributedString(
            string: "hover over a service\nto preview its log",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
                         .paragraphStyle: emptyStyle])
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.frame = NSRect(x: 20, y: (h - 40) / 2, width: w - 40, height: 40)
        addSubview(emptyLabel)

        showEmpty()
    }

    override func draw(_ dirtyRect: NSRect) {
        if !pathBtn.isHidden {
            let y = frame.height - toolbarH - inset
            let gradient = NSGradient(colors: [
                NSColor.separatorColor.withAlphaComponent(0.3),
                NSColor.separatorColor.withAlphaComponent(0.0),
            ])
            gradient?.draw(in: NSRect(x: inset + 8, y: y, width: frame.width - inset * 2 - 16, height: 1), angle: 0)
        }
    }

    private func formatFileSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func updateSizeLabel() {
        guard let url = currentLogURL else { sizeLabel.stringValue = ""; return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        sizeLabel.stringValue = formatFileSize(size)
    }

    func showLog(path: String, content: String, filename: String, logURL: URL) {
        let isNewEntry = currentFilename != filename
        currentFilename = filename
        currentLogURL = logURL

        if isNewEntry {
            showGeneration += 1
            let gen = showGeneration
            // Cancel any in-flight animation
            scrollView.animator().alphaValue = scrollView.alphaValue

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                MainActor.assumeIsolated { self.scrollView.animator().alphaValue = 0 }
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard self.showGeneration == gen else { return }
                    self.emptyLabel.isHidden = true
                    self.scrollView.isHidden = false
                    self.pathBtn.isHidden = false
                    self.sizeLabel.isHidden = false
                    self.pathBtn.stringValue = path
                    self.textView.string = content
                    self.updateSizeLabel()
                    self.needsDisplay = true
                    self.textView.scrollToEndOfDocument(nil)
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        MainActor.assumeIsolated { self.scrollView.animator().alphaValue = 1 }
                    }
                }
            })
        } else {
            updateContent(content)
        }
    }

    func updateContent(_ content: String) {
        guard content != textView.string else {
            updateSizeLabel()
            return
        }
        let atBottom = isScrolledToBottom
        textView.string = content
        updateSizeLabel()
        if atBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func truncateLog() {
        guard let url = currentLogURL,
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.truncateFile(atOffset: 0)
        try? handle.close()
        textView.string = "(empty log)"
        updateSizeLabel()
    }

    func showEmpty() {
        emptyLabel.isHidden = false
        scrollView.isHidden = true
        pathBtn.isHidden = true
        sizeLabel.isHidden = true
        currentFilename = nil
        currentLogURL = nil
        needsDisplay = true
    }

    func relayout(height: CGFloat) {
        let w = frame.width
        let iw = w - inset * 2
        let ih = height - inset * 2
        frame.size.height = height
        pathBtn.frame = NSRect(x: inset + 8, y: height - toolbarH - inset + 6, width: iw - 70, height: 16)
        sizeLabel.frame = NSRect(x: w - inset - 60, y: height - toolbarH - inset + 6, width: 52, height: 16)
        scrollView.frame = NSRect(x: inset + 2, y: inset, width: iw - 4, height: ih - toolbarH - 4)
        emptyLabel.frame = NSRect(x: 20, y: (height - 40) / 2, width: w - 40, height: 40)
    }

    private var isScrolledToBottom: Bool {
        let clip = scrollView.contentView
        let ch = scrollView.documentView?.frame.height ?? 0
        return clip.bounds.origin.y + clip.bounds.height >= ch - 20
    }
}

// MARK: - Clickable Label (underlines on hover, triggers action on click)

final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)?
    var normalColor: NSColor = .tertiaryLabelColor {
        didSet { textColor = normalColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isEditable = false
        drawsBackground = false
        textColor = normalColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}

// MARK: - Vertical Gradient Divider

final class GradientDividerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let lineColor = NSColor(white: 0.5, alpha: 0.3)
        let gradient = NSGradient(colors: [
            lineColor.withAlphaComponent(0.0),
            lineColor,
            lineColor,
            lineColor.withAlphaComponent(0.0),
        ])!
        gradient.draw(in: bounds, angle: 90)
    }
}

// MARK: - Section Divider (horizontal grayscale gradient between sections)

final class SectionDividerView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: listWidth, height: 16))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let y = round(bounds.midY) + 0.5
        let x0: CGFloat = 24, x1 = bounds.width - 24

        let gradient = CGGradient(colorsSpace: nil, colors: [
            NSColor.separatorColor.withAlphaComponent(0.0).cgColor,
            NSColor.separatorColor.withAlphaComponent(0.4).cgColor,
            NSColor.separatorColor.withAlphaComponent(0.0).cgColor,
        ] as CFArray, locations: [0, 0.5, 1])!

        ctx.saveGState()
        ctx.clip(to: CGRect(x: x0, y: y - 0.5, width: x1 - x0, height: 1))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
        ctx.restoreGState()
    }
}

// MARK: - Spacer

final class SpacerView: NSView {
    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: listWidth, height: height))
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Thin Scroller

final class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        scrollerStyle == .overlay ? super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle) : 6
    }
}
