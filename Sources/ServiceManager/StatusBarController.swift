import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var visualEffect: NSVisualEffectView!
    private var leftColumn: FlippedView!
    private var logDetail: LogDetailView!
    private var divider: NSView!
    private var rowViews: [EntryRowView] = []
    private var tickTimer: Timer?
    private var tickCount = 0
    private var eventMonitor: Any?
    private var hoveredEntry: ScriptEntry?

    private let cornerRadius: CGFloat = 12
    private let minPanelHeight: CGFloat = 420
    private var panelGeneration = 0

    private var rightClickMenu: NSMenu!

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusBarClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Right-click context menu
        rightClickMenu = NSMenu()
        rightClickMenu.delegate = self
        rightClickMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: ""))
        rightClickMenu.items.first?.target = self

        createPanel()
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
        } else {
            togglePanel()
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: - Status Bar Icon

    private func makeIcon() -> NSImage {
        let s: CGFloat = 18
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let cx = s / 2, cy = s / 2, r: CGFloat = 6.5
            let lineW: CGFloat = 1.6

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineCap(.round)

            // Gap on the right side (3 o'clock / 0°), arc goes clockwise
            // Arrow at the bottom of the gap, pointing into the gap (upward on the right)
            let gapHalf: CGFloat = .pi / 6  // 30° half-gap
            let arcStart: CGFloat = -gapHalf          // -30° (bottom of gap)
            let arcEnd: CGFloat = gapHalf              // +30° (top of gap)

            // Draw the long way: from arcStart going clockwise to arcEnd
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                       startAngle: arcStart, endAngle: arcEnd, clockwise: true)
            ctx.strokePath()

            // Arrowhead: base sits on arcEnd, tip points clockwise into gap
            let baseAngle = arcEnd
            let arrowLen: CGFloat = 3.8
            let halfBase: CGFloat = lineW * 0.85

            let tangent = baseAngle - .pi / 2  // clockwise tangent
            let tipX = cx + r * cos(baseAngle) + arrowLen * cos(tangent)
            let tipY = cy + r * sin(baseAngle) + arrowLen * sin(tangent)
            let w1x = cx + (r + halfBase) * cos(baseAngle)
            let w1y = cy + (r + halfBase) * sin(baseAngle)
            let w2x = cx + (r - halfBase) * cos(baseAngle)
            let w2y = cy + (r - halfBase) * sin(baseAngle)

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.move(to: CGPoint(x: tipX, y: tipY))
            ctx.addLine(to: CGPoint(x: w1x, y: w1y))
            ctx.addLine(to: CGPoint(x: w2x, y: w2y))
            ctx.closePath()
            ctx.fillPath()

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Panel Setup

    private func createPanel() {
        let totalWidth = listWidth + 1 + logColumnWidth
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: totalWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        // Vibrancy blur background
        visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = cornerRadius
        visualEffect.layer?.masksToBounds = true
        panel.contentView?.addSubview(visualEffect)

        // Left column (service list)
        leftColumn = FlippedView()
        visualEffect.addSubview(leftColumn)

        // Divider — gradient fade matching horizontal separators
        divider = GradientDividerView()
        visualEffect.addSubview(divider)

        // Right column (log viewer)
        logDetail = LogDetailView(frame: NSRect(x: 0, y: 0, width: logColumnWidth, height: 300))
        visualEffect.addSubview(logDetail)
    }

    // MARK: - Show / Hide

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func rebuildIfVisible() {
        guard panel.isVisible else { return }
        rebuildLeft()
    }

    private func showPanel() {
        guard let button = statusItem.button, let bw = button.window else { return }

        panelGeneration += 1
        // Cancel any in-flight hide animation
        panel.animator().alphaValue = panel.alphaValue

        buildLeftContent()

        let totalWidth = listWidth + 1 + logColumnWidth
        let h = max(leftColumn.frame.height, minPanelHeight)

        // Layout
        visualEffect.frame = NSRect(x: 0, y: 0, width: totalWidth, height: h)
        leftColumn.frame = NSRect(x: 0, y: 0, width: listWidth, height: h)
        divider.frame = NSRect(x: listWidth, y: cornerRadius, width: 1, height: h - cornerRadius * 2)
        logDetail.frame = NSRect(x: listWidth + 1, y: 0, width: logColumnWidth, height: h)
        logDetail.relayout(height: h)

        // Position below status bar icon
        let br = bw.convertToScreen(button.convert(button.bounds, to: nil))
        var x = br.midX - totalWidth / 2
        let y = br.minY - h - 4

        if let screen = bw.screen ?? NSScreen.main {
            x = min(x, screen.visibleFrame.maxX - totalWidth - 8)
            x = max(x, screen.visibleFrame.minX + 8)
        }

        panel.setFrame(NSRect(x: x, y: y, width: totalWidth, height: h), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: totalWidth, height: h)

        // Show first entry's log by default
        if let first = rowViews.first {
            hoveredEntry = first.entry
            showLogForEntry(first.entry)
        }

        // Fade in
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            MainActor.assumeIsolated { self.panel.animator().alphaValue = 1 }
        }

        startTick()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func hidePanel() {
        panelGeneration += 1
        let gen = panelGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            MainActor.assumeIsolated { self.panel.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.panelGeneration == gen else { return }
                self.panel.orderOut(nil)
            }
        })

        stopTick()
        rowViews.removeAll()
        hoveredEntry = nil

        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    // MARK: - Build Left Column

    private func buildLeftContent() {
        leftColumn.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        var y: CGFloat = 8
        let supervisor = ServiceSupervisor.shared
        let runner = ScheduledTaskRunner.shared
        let services = supervisor.services.values.sorted { $0.entry.displayName < $1.entry.displayName }
        let tasks = runner.tasks.values.sorted { $0.entry.displayName < $1.entry.displayName }

        func addView(_ v: NSView) {
            v.frame.origin = NSPoint(x: 0, y: y)
            leftColumn.addSubview(v)
            y += v.frame.height
        }

        // Services
        if !services.isEmpty {
            addView(SectionHeaderView(title: "SERVICES", rightText: "uptime"))

            for svc in services {
                let color: NSColor
                var detail = ""
                var restarting = false
                switch svc.state {
                case .running:
                    color = .systemGreen
                    if let p = svc.process { detail = "pid \(p.processIdentifier)" }
                case .restarting:
                    color = .systemOrange
                    detail = svc.restartCount > 1 ? "retry #\(svc.restartCount)" : "restarting…"
                    restarting = true
                case .stopped:
                    color = .systemGray
                    detail = "stopped"
                }

                let startedAt = svc.startedAt
                let row = EntryRowView(
                    entry: svc.entry, detail: detail,
                    timeProvider: { [weak self] in
                        guard let self, let s = startedAt else { return "" }
                        return self.fmt(Int(-s.timeIntervalSinceNow))
                    },
                    dotColor: color, isRestarting: restarting)

                let fname = svc.entry.filename
                row.onHover = { [weak self] entry in
                    if let entry { self?.hoveredEntry = entry; self?.showLogForEntry(entry) }
                }
                row.onAction = { [weak self] in
                    ServiceSupervisor.shared.toggle(fname)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        self?.rebuildLeft()
                    }
                }
                addView(row)
                rowViews.append(row)
            }
        }

        // Tasks
        if !tasks.isEmpty {
            addView(SectionHeaderView(title: "SCHEDULED", rightText: "next", showTopDivider: !services.isEmpty))

            for task in tasks {
                let color: NSColor
                var detail = ""
                let sched = scheduleLabel(task.unit)
                switch task.status {
                case .neverRun: color = .systemGray; detail = sched
                case .success: color = .systemGreen; detail = sched
                case .failed(let c): color = .systemRed; detail = "exit \(c)"
                case .running:
                    color = .systemBlue
                    if let p = task.process { detail = "pid \(p.processIdentifier)" } else { detail = "running" }
                }

                let nextRun = task.nextRun
                let row = EntryRowView(
                    entry: task.entry, detail: detail,
                    timeProvider: { [weak self] in
                        guard let self else { return "" }
                        return self.fmt(max(Int(nextRun.timeIntervalSinceNow), 0))
                    },
                    dotColor: color)

                let fname = task.entry.filename
                row.onHover = { [weak self] entry in
                    if let entry { self?.hoveredEntry = entry; self?.showLogForEntry(entry) }
                }
                row.onAction = { [weak self] in
                    if task.isRunning {
                        ScheduledTaskRunner.shared.forceStop(fname)
                    } else {
                        ScheduledTaskRunner.shared.forceRun(fname)
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        self?.rebuildLeft()
                    }
                }
                addView(row)
                rowViews.append(row)
            }
        }

        y += 8
        leftColumn.frame.size = NSSize(width: listWidth, height: y)
    }

    private func rebuildLeft() {
        buildLeftContent()
        // Resize panel if height changed
        let h = max(leftColumn.frame.height, minPanelHeight)
        var f = panel.frame
        let dy = f.height - h
        f.origin.y += dy
        f.size.height = h
        panel.setFrame(f, display: true)
        panel.contentView?.frame.size.height = h
        visualEffect.frame.size.height = h
        leftColumn.frame.size.height = h
        divider.frame = NSRect(x: listWidth, y: cornerRadius, width: 1, height: h - cornerRadius * 2)
        logDetail.frame.size.height = h
        logDetail.relayout(height: h)

        // Re-show current log
        if let entry = hoveredEntry { showLogForEntry(entry) }
    }

    // MARK: - Log Detail

    private func showLogForEntry(_ entry: ScriptEntry) {
        let content = readLogTail(url: entry.logURL)
        let shortPath = entry.logURL.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        logDetail.onReveal = {
            NSWorkspace.shared.selectFile(entry.logURL.path, inFileViewerRootedAtPath: "")
        }
        logDetail.showLog(path: shortPath, content: content, filename: entry.filename, logURL: entry.logURL)
    }

    // MARK: - Tick Timer

    private func startTick() {
        stopTick(); tickCount = 0
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTick() { tickTimer?.invalidate(); tickTimer = nil }

    private func tick() {
        tickCount += 1
        for row in rowViews { row.refreshTime() }

        if tickCount % 2 == 0, let entry = hoveredEntry {
            logDetail.updateContent(readLogTail(url: entry.logURL))
        }
    }

    // MARK: - Helpers

    private func readLogTail(url: URL, maxLines: Int = 80) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "(no log output yet)" }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        guard size > 0 else { return "(empty log)" }
        handle.seek(toFileOffset: size - min(size, 16384))
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else { return "(unable to read)" }
        return content.components(separatedBy: "\n").suffix(maxLines)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleLabel(_ unit: ScheduleUnit) -> String {
        switch unit {
        case .minutes(let n): return "every \(n)m"
        case .hours(let n): return "every \(n)h"
        case .days(let n): return n == 1 ? "daily" : "every \(n)d"
        }
    }

    private func fmt(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return sec > 0 ? "\(m)m \(sec)s" : "\(m)m" }
        return "\(sec)s"
    }
}
