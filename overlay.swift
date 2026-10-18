import AppKit
import Foundation

// MARK: - Model

struct Tokens {
    var input = 0
    var output = 0
    var cacheRead = 0
    var total = 0
}

struct Child {
    var id = ""
    var label = ""
    var parent = ""
    var startedAt: Double = 0
    var elapsedMs: Double = 0
    var active = false
    var model = ""
    var effort = ""
    var tokens = Tokens()
}

struct Root {
    var id = ""
    var title = ""
    var cwd = ""
    var startedAt: Double = 0
    var elapsedMs: Double = 0
    var active = false
    var turn = 0
    var model = ""
    var effort = ""
    var tokens = Tokens()
    var source = ""
    var sourceLabel = ""
    var sourceConfidence = ""
    var titleSource = ""
    var taskPreview = ""
    var colorKey = 0
    var children: [Child] = []
}

// MARK: - Helpers

func num(_ value: Any?) -> Double {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) ?? 0 }
    return 0
}

func int(_ value: Any?) -> Int { Int(num(value)) }

func str(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return ""
}

func bool(_ value: Any?) -> Bool {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return false
}

func parseTokens(_ value: Any?) -> Tokens {
    var t = Tokens()
    guard let d = value as? [String: Any] else { return t }
    t.input = int(d["input"])
    t.output = int(d["output"])
    t.cacheRead = int(d["cacheRead"])
    t.total = int(d["total"])
    if t.total == 0 { t.total = t.input + t.output + t.cacheRead }
    return t
}

func parseChild(_ value: Any?) -> Child? {
    guard let d = value as? [String: Any] else { return nil }
    var c = Child()
    c.id = str(d["id"])
    c.label = str(d["label"])
    if c.label.isEmpty { c.label = str(d["title"]) }
    c.parent = str(d["parentSession"])
    c.startedAt = num(d["startedAt"])
    c.elapsedMs = num(d["elapsedMs"])
    c.active = bool(d["active"])
    c.model = str(d["model"])
    c.effort = str(d["reasoningEffort"])
    c.tokens = parseTokens(d["tokens"])
    return c
}

func parseRoot(_ value: Any?) -> Root? {
    guard let d = value as? [String: Any] else { return nil }
    var r = Root()
    r.id = str(d["id"])
    r.title = str(d["title"])
    r.cwd = str(d["cwd"])
    r.startedAt = num(d["startedAt"])
    r.elapsedMs = num(d["elapsedMs"])
    r.active = bool(d["active"])
    r.turn = int(d["turn"])
    r.model = str(d["model"])
    r.effort = str(d["reasoningEffort"])
    r.tokens = parseTokens(d["tokens"])
    r.source = str(d["source"])
    r.sourceLabel = str(d["sourceLabel"])
    r.sourceConfidence = str(d["sourceConfidence"])
    r.titleSource = str(d["titleSource"])
    r.taskPreview = str(d["taskPreview"])
    r.colorKey = int(d["colorKey"])
    if let kids = d["children"] as? [Any] {
        r.children = kids.compactMap(parseChild)
    }
    return r
}

func compact(_ value: Int) -> String {
    let n = Double(value)
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
    return "\(value)"
}

func duration(_ ms: Double) -> String {
    let total = max(0, Int(ms / 1000))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

func effortLabel(_ value: String) -> String {
    switch value.lowercased() {
    case "off": return "关"
    case "low": return "低"
    case "medium": return "中"
    case "high": return "高"
    case "max": return "最高"
    default: return value
    }
}

func truncate(_ value: String, _ limit: Int) -> String {
    if value.count <= limit { return value }
    return String(value.prefix(max(1, limit - 1))) + "…"
}

// MARK: - Bubble view

final class BubbleView: NSView {
    struct Chip {
        enum Style { case source, id, count, plain, effort, turn }
        let text: String
        let style: Style
        let colorIndex: Int
    }

    struct Row {
        enum Kind { case root, meta, task, child, empty, divider }
        let kind: Kind
        let text: String
        let secondary: String
        let time: String
        let indent: CGFloat
        let height: CGFloat
        let dot: Bool
        var colorIndex: Int = 0
        var chips: [Chip] = []
        var rootId: String = ""
        var childCount: Int = 0
    }

    var roots: [Root] = []
    var expanded = false
    var suppressHover = false
    var pulse: CGFloat = 1
    var scrollOffset: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var pendingDrag = false
    private var isDragging = false
    private var dragStartScreen = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var longPressTimer: Timer?
    private var toggleRootId: String?
    private var collapsedRoots: Set<String> = []
    private var hoverSuppressUntil = Date.distantPast
    private lazy var pinButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePin)
        button.toolTip = "钉住展开状态"
        return button
    }()

    private let pad: CGFloat = 12
    private let headerH: CGFloat = 30
    private let maxPanelHeight: CGFloat = 420
    private let footerH: CGFloat = 28

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
    }
    private var bg: NSColor { isDark ? NSColor(calibratedWhite: 0.10, alpha: 0.93) : NSColor(calibratedWhite: 0.99, alpha: 0.94) }
    private var fg: NSColor { isDark ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1) }
    private var muted: NSColor { isDark ? NSColor(calibratedWhite: 0.70, alpha: 1) : NSColor(calibratedWhite: 0.40, alpha: 1) }
    private var taskFg: NSColor { isDark ? NSColor(calibratedWhite: 0.82, alpha: 1) : NSColor(calibratedWhite: 0.28, alpha: 1) }
    private var border: NSColor { isDark ? NSColor(calibratedWhite: 1, alpha: 0.12) : NSColor(calibratedWhite: 0, alpha: 0.08) }
    private var accent: NSColor { NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1) }
    private let palette: [NSColor] = [.systemBlue, .systemOrange, .systemTeal, .systemPurple, .systemPink, .systemGreen]

    private func groupColor(_ index: Int) -> NSColor {
        palette[abs(index) % palette.count]
    }

    var isIdle: Bool { roots.isEmpty }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(pinButton)
        pinButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size: CGFloat = 18
        pinButton.frame = NSRect(x: bounds.width - 32, y: bounds.height - 24, width: size, height: size)
    }

    @objc private func togglePin() {
        guard let panel = window as? BubblePanel else { return }
        panel.pinned.toggle()
        hoverSuppressUntil = Date().addingTimeInterval(0.35)
        if panel.pinned {
            expanded = true
        } else {
            let local = convert(NSEvent.mouseLocation, from: nil)
            if !bounds.contains(local) { expanded = false }
        }
        panel.saveState()
        panel.resize(expanded: expanded)
        needsDisplay = true
    }

    private func updatePinButton() {
        pinButton.isHidden = !expanded
        pinButton.frame = NSRect(x: bounds.width - 32, y: bounds.height - 24, width: 18, height: 18)
        let symbol = (window as? BubblePanel)?.pinned == true ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "钉住")
        pinButton.contentTintColor = (window as? BubblePanel)?.pinned == true ? accent : muted
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if pinButton.frame.contains(point) { return }
        toggleRootId = rootId(at: point)
        pendingDrag = true
        isDragging = false
        dragStartScreen = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.pendingDrag, let panel = self.window as? BubblePanel else { return }
            self.isDragging = true
            panel.beginUserDrag()
            NSCursor.closedHand.set()
            self.needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pendingDrag, let panel = window as? BubblePanel else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartScreen.x
        let dy = now.y - dragStartScreen.y
        if !isDragging {
            if hypot(dx, dy) > 4 {
                longPressTimer?.invalidate()
                longPressTimer = nil
                pendingDrag = false
                toggleRootId = nil
            }
            return
        }
        panel.dragUserWindow(to: NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        if isDragging {
            (window as? BubblePanel)?.endUserDrag()
            NSCursor.arrow.set()
        } else if let rootId = toggleRootId, let panel = window as? BubblePanel {
            if collapsedRoots.contains(rootId) {
                collapsedRoots.remove(rootId)
            } else {
                collapsedRoots.insert(rootId)
            }
            hoverSuppressUntil = Date().addingTimeInterval(0.35)
            panel.resize(expanded: expanded)
            needsDisplay = true
        }
        isDragging = false
        pendingDrag = false
        toggleRootId = nil
    }

    func collapseFirstRootForDemo() {
        if let first = roots.first { collapsedRoots.insert(first.id) }
        needsDisplay = true
    }

    private func rootId(at point: NSPoint) -> String? {
        let rows = makeRows()
        var rowTop = headerH + 8 - scrollOffset
        for row in rows {
            if row.kind == .root, row.childCount > 0 {
                let rect = NSRect(x: 0, y: bounds.height - rowTop - row.height, width: bounds.width, height: row.height)
                if rect.contains(point) { return row.rootId }
            }
            rowTop += row.height
        }
        return nil
    }

    override func mouseEntered(with event: NSEvent) {
        if suppressHover || pendingDrag || isDragging { return }
        guard !expanded else { return }
        if (window as? BubblePanel)?.pinned == true { expanded = true; needsDisplay = true; return }
        expanded = true
        scrollOffset = 0
        needsDisplay = true
        (window as? BubblePanel)?.resize(expanded: true)
    }

    override func mouseExited(with event: NSEvent) {
        if suppressHover || Date() < hoverSuppressUntil || pendingDrag || isDragging { return }
        if (window as? BubblePanel)?.pinned == true { return }
        guard expanded else { return }
        expanded = false
        scrollOffset = 0
        needsDisplay = true
        (window as? BubblePanel)?.resize(expanded: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard expanded else { return }
        let rows = makeRows()
        let content = contentHeight(rows)
        let viewport = viewportHeight()
        let maxOffset = max(0, content - viewport)
        guard maxOffset > 0 else { return }
        scrollOffset = min(max(0, scrollOffset - event.scrollingDeltaY), maxOffset)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func y(_ top: CGFloat) -> CGFloat { bounds.height - top }

    private func drawText(_ text: String, x: CGFloat, top: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x, y: y(top) - size.height), withAttributes: attrs)
    }

    private func drawRight(_ text: String, right: CGFloat, top: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: right - size.width, y: y(top) - size.height), withAttributes: attrs)
    }

    private func attrs(size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> [NSAttributedString.Key: Any] {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return [.font: font, .foregroundColor: color]
    }

    private var activeChildren: [Child] {
        roots.flatMap { $0.children.filter { $0.active } }
    }

    private var maxElapsed: Double {
        let now = Date().timeIntervalSince1970 * 1000
        var maxValue: Double = 0
        for root in roots {
            maxValue = max(maxValue, root.active ? now - root.startedAt : root.elapsedMs)
            for child in root.children {
                maxValue = max(maxValue, child.active ? now - child.startedAt : child.elapsedMs)
            }
        }
        return maxValue
    }

    private func totalTokens() -> Tokens {
        var t = Tokens()
        for root in roots {
            t.input += root.tokens.input
            t.output += root.tokens.output
            t.cacheRead += root.tokens.cacheRead
            t.total += root.tokens.total
            for child in root.children {
                t.input += child.tokens.input
                t.output += child.tokens.output
                t.cacheRead += child.tokens.cacheRead
                t.total += child.tokens.total
            }
        }
        return t
    }

    func makeRows() -> [Row] {
        let now = Date().timeIntervalSince1970 * 1000
        if roots.isEmpty {
            return [Row(kind: .empty, text: "没有外部任务在运行", secondary: "等待外部 ACP / headless 调用", time: "", indent: 0, height: 36, dot: false)]
        }
        var rows: [Row] = []
        for (index, root) in roots.enumerated() {
            let color = root.colorKey
            let kids = root.children.filter { $0.active }
            let collapsed = collapsedRoots.contains(root.id)
            let rootElapsed = root.active ? now - root.startedAt : root.elapsedMs
            rows.append(Row(kind: .root, text: truncate(root.title, 22), secondary: "", time: duration(rootElapsed), indent: 0, height: 18, dot: false, colorIndex: color, rootId: root.id, childCount: kids.count))

            var chips: [Chip] = []
            var source = root.sourceLabel.isEmpty ? root.source : root.sourceLabel
            if root.sourceConfidence == "inferred", !source.isEmpty { source = "~" + source }
            if !source.isEmpty { chips.append(Chip(text: source, style: .source, colorIndex: color)) }
            if !root.id.isEmpty { chips.append(Chip(text: "#\(root.id.prefix(4))", style: .id, colorIndex: color)) }
            if !kids.isEmpty { chips.append(Chip(text: "\(kids.count) 子", style: .count, colorIndex: color)) }
            if !root.model.isEmpty { chips.append(Chip(text: root.model, style: .plain, colorIndex: color)) }
            if !root.effort.isEmpty { chips.append(Chip(text: "推理 \(effortLabel(root.effort))", style: .effort, colorIndex: color)) }
            if root.turn > 0 { chips.append(Chip(text: "T\(root.turn)", style: .turn, colorIndex: color)) }
            if !chips.isEmpty {
                rows.append(Row(kind: .meta, text: "", secondary: "", time: "", indent: 0, height: 16, dot: false, colorIndex: color, chips: chips))
            }

            if !root.taskPreview.isEmpty && root.taskPreview != root.title {
                rows.append(Row(kind: .task, text: truncate(root.taskPreview, 46), secondary: "", time: "", indent: 0, height: 16, dot: false, colorIndex: color))
            }

            if !collapsed {
                if kids.isEmpty {
                    rows.append(Row(kind: .empty, text: "无运行中的子 Agent", secondary: "", time: "", indent: 22, height: 16, dot: false, colorIndex: color))
                } else {
                    for child in kids {
                        let childElapsed = child.active ? now - child.startedAt : child.elapsedMs
                        let label = child.label.isEmpty ? child.id : child.label
                        let parent = child.parent.isEmpty ? "" : "← \(child.parent.prefix(8))"
                        rows.append(Row(kind: .child, text: truncate(label, 22), secondary: parent, time: duration(childElapsed), indent: 22, height: 17, dot: true, colorIndex: color))
                    }
                }
            }

            if index < roots.count - 1 {
                rows.append(Row(kind: .divider, text: "", secondary: "", time: "", indent: 0, height: 8, dot: false))
            }
        }
        return rows
    }

    func contentHeight(_ rows: [Row]) -> CGFloat {
        rows.reduce(0) { $0 + $1.height } + 10
    }

    func preferredHeight(expanded: Bool) -> CGFloat {
        guard expanded else { return 42 }
        let rows = makeRows()
        let natural = headerH + contentHeight(rows) + (isIdle ? 0 : footerH) + 14
        return min(maxPanelHeight, max(96, natural))
    }

    private func viewportHeight() -> CGFloat {
        max(0, bounds.height - (headerH + 8) - ((isIdle ? 0 : footerH) + 6))
    }

    private func bodyBottomY() -> CGFloat {
        (isIdle ? 0 : footerH) + 6
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        bg.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()

        let idle = isIdle
        let label = idle ? "空闲" : (roots.count == 1 ? "外部任务运行中" : "\(roots.count) 个外部任务")
        let badge = activeChildren.count > 0 ? "\(activeChildren.count) 子" : ""
        let headerTop: CGFloat = expanded ? 7 : 13
        let timeText = idle ? "—" : duration(maxElapsed)
        let timeAttrs = attrs(size: 11.5, weight: .semibold, color: fg, mono: true)
        let timeWidth = (timeText as NSString).size(withAttributes: timeAttrs).width

        let dotY: CGFloat = expanded ? bounds.height - 16 : (bounds.height - 7) / 2
        let dotRect = NSRect(x: pad, y: dotY, width: 7, height: 7)
        (idle ? muted.withAlphaComponent(0.55) : accent.withAlphaComponent(0.95 * pulse + 0.05)).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        drawText(truncate(label, 18), x: pad + 13, top: headerTop, attrs: attrs(size: 11.5, weight: .semibold, color: idle ? muted : fg))
        let timeRight = bounds.width - 14 - (expanded ? 22 : 0)
        drawRight(timeText, right: timeRight, top: headerTop, attrs: timeAttrs)
        updatePinButton()

        if !badge.isEmpty {
            let badgeAttrs = attrs(size: 9.5, weight: .semibold, color: muted)
            let size = (badge as NSString).size(withAttributes: badgeAttrs)
            let badgeRight = bounds.width - 14 - (expanded ? 22 : 0) - timeWidth - 8
            let badgeY = expanded ? bounds.height - 21 : (bounds.height - 14) / 2
            let badgeRect = NSRect(x: badgeRight - size.width - 8, y: badgeY, width: size.width + 8, height: 14)
            NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.08 : 0.06).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7).fill()
            drawText(badge, x: badgeRect.minX + 4, top: expanded ? 7.5 : 13.5, attrs: badgeAttrs)
        }

        guard expanded else {
            ctx.restoreGraphicsState()
            return
        }

        border.withAlphaComponent(0.7).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: pad, y: y(headerH)))
        sep.line(to: NSPoint(x: bounds.width - pad, y: y(headerH)))
        sep.lineWidth = 1
        sep.stroke()

        let rows = makeRows()
        let content = contentHeight(rows)
        let viewport = max(0, bounds.height - (headerH + 8) - ((idle ? 0 : footerH) + 6))
        let maxOffset = max(0, content - viewport)
        scrollOffset = min(max(0, scrollOffset), maxOffset)
        let bodyTop: CGFloat = headerH + 8
        let bodyBottom = bodyBottomY()

        ctx.saveGraphicsState()
        let clipHeight = max(0, bounds.height - bodyTop - bodyBottom)
        NSBezierPath(rect: NSRect(x: 0, y: bodyBottom, width: bounds.width, height: clipHeight)).addClip()

        var rowTop = bodyTop - scrollOffset
        for row in rows {
            if rowTop + row.height >= bodyTop && rowTop <= bodyTop + viewport {
                drawRow(row, top: rowTop)
            }
            rowTop += row.height
        }
        ctx.restoreGraphicsState()

        if !idle && content > viewport && maxOffset > 0 {
            drawScrollbar(content: content, viewport: viewport, bottom: bodyBottom)
        }

        if !idle {
            border.withAlphaComponent(0.7).setStroke()
            let footLine = NSBezierPath()
            footLine.move(to: NSPoint(x: pad, y: footerH - 6))
            footLine.line(to: NSPoint(x: bounds.width - pad, y: footerH - 6))
            footLine.lineWidth = 1
            footLine.stroke()

            let t = totalTokens()
            let footerAttrs = attrs(size: 10, weight: .regular, color: muted)
            ("Token \(compact(t.total))" as NSString).draw(at: NSPoint(x: pad, y: 8), withAttributes: footerAttrs)
            let detail = "入 \(compact(t.input))   出 \(compact(t.output))   缓存 \(compact(t.cacheRead))"
            let detailAttrs = attrs(size: 9.5, weight: .regular, color: muted, mono: true)
            let detailSize = (detail as NSString).size(withAttributes: detailAttrs)
            (detail as NSString).draw(at: NSPoint(x: bounds.width - pad - detailSize.width, y: 8), withAttributes: detailAttrs)
        }

        ctx.restoreGraphicsState()
    }

    private func drawChips(_ chips: [Chip], top: CGFloat) {
        var x = pad + 11
        let limit = bounds.width - pad - 8
        for chip in chips {
            let isMono = chip.style == .id || chip.style == .turn
            let font = isMono
                ? NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
                : NSFont.systemFont(ofSize: 9.5, weight: chip.style == .source ? .semibold : .regular)
            let fg: NSColor
            let bg: NSColor?
            switch chip.style {
            case .source:
                fg = groupColor(chip.colorIndex)
                bg = groupColor(chip.colorIndex).withAlphaComponent(isDark ? 0.22 : 0.14)
            case .id:
                fg = muted
                bg = NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.07 : 0.05)
            case .count:
                fg = accent
                bg = accent.withAlphaComponent(isDark ? 0.16 : 0.10)
            case .effort:
                fg = isDark ? NSColor.systemOrange : NSColor(calibratedRed: 0.65, green: 0.36, blue: 0.02, alpha: 1)
                bg = NSColor.systemOrange.withAlphaComponent(isDark ? 0.14 : 0.10)
            case .plain, .turn:
                fg = muted
                bg = nil
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let textSize = (chip.text as NSString).size(withAttributes: attrs)
            let padX: CGFloat = bg == nil ? 2 : 4
            let width = textSize.width + padX * 2
            guard x + width <= limit else { break }
            let height: CGFloat = 14
            let yPos = bounds.height - top - height + 1
            if let bg {
                bg.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: yPos, width: width, height: height), xRadius: 6, yRadius: 6).fill()
            }
            (chip.text as NSString).draw(
                at: NSPoint(x: x + padX, y: yPos + (height - textSize.height) / 2),
                withAttributes: attrs
            )
            x += width + 5
        }
    }

    private func drawRow(_ row: Row, top: CGFloat) {
        switch row.kind {
        case .root:
            let dotRect = NSRect(x: pad, y: bounds.height - top - 12, width: 6, height: 6)
            groupColor(row.colorIndex).withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            var titleX = pad + 11
            if row.childCount > 0 {
                let collapsed = collapsedRoots.contains(row.rootId)
                drawText(collapsed ? "▸" : "▾", x: pad + 10, top: top, attrs: attrs(size: 9, weight: .bold, color: muted))
                titleX = pad + 21
            }
            drawText(row.text, x: titleX, top: top, attrs: attrs(size: 11.5, weight: .semibold, color: fg))
            drawRight(row.time, right: bounds.width - pad, top: top, attrs: attrs(size: 11, weight: .semibold, color: fg, mono: true))
        case .meta:
            drawChips(row.chips, top: top)
        case .task:
            drawText("›", x: pad + 11, top: top, attrs: attrs(size: 11, weight: .bold, color: accent))
            drawText(row.text, x: pad + 21, top: top, attrs: attrs(size: 10, weight: .regular, color: taskFg))
        case .child:
            let dotRect = NSRect(x: pad + row.indent - 8, y: bounds.height - top - 10, width: 5, height: 5)
            groupColor(row.colorIndex).withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            drawText(row.text, x: pad + row.indent, top: top, attrs: attrs(size: 10.5, weight: .regular, color: fg))
            let timeAttrs = attrs(size: 10, weight: .regular, color: muted, mono: true)
            drawRight(row.time, right: bounds.width - pad, top: top, attrs: timeAttrs)
            if !row.secondary.isEmpty {
                let timeWidth = (row.time as NSString).size(withAttributes: timeAttrs).width
                drawRight(row.secondary, right: bounds.width - pad - timeWidth - 8, top: top + 1, attrs: attrs(size: 9.5, weight: .regular, color: muted))
            }
        case .empty:
            drawText(row.text, x: pad + row.indent, top: top, attrs: attrs(size: 10.5, weight: .regular, color: muted))
            if !row.secondary.isEmpty {
                drawText(row.secondary, x: pad + row.indent, top: top + 17, attrs: attrs(size: 9.5, weight: .regular, color: muted))
            }
        case .divider:
            border.withAlphaComponent(0.55).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: pad, y: y(top + 4)))
            line.line(to: NSPoint(x: bounds.width - pad, y: y(top + 4)))
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawScrollbar(content: CGFloat, viewport: CGFloat, bottom: CGFloat) {
        let maxOffset = max(0, content - viewport)
        guard maxOffset > 0 else { return }
        let trackX = bounds.width - 8
        NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.10 : 0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: trackX, y: bottom, width: 4, height: viewport), xRadius: 2, yRadius: 2).fill()
        let thumbH = max(18, viewport * viewport / content)
        let progress = min(1, max(0, scrollOffset / maxOffset))
        let thumbY = bottom + (viewport - thumbH) * (1 - progress)
        NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 0.38).setFill()
        NSBezierPath(roundedRect: NSRect(x: trackX, y: thumbY, width: 4, height: thumbH), xRadius: 2, yRadius: 2).fill()
    }
}

// MARK: - Panel

final class BubblePanel: NSPanel {
    let bubbleView: BubbleView
    private var lastNonEmptyAt: Date?
    private var anchor: NSPoint?
    private var isUserDragging = false
    private var lastAnchorSave = Date.distantPast
    var pinned = false

    init() {
        bubbleView = BubbleView(frame: NSRect(x: 0, y: 0, width: 238, height: 42))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 238, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = bubbleView
        anchor = loadAnchor()
        pinned = loadPinned()
        if anchor != nil && screenFor(point: anchor!) == nil { anchor = nil }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        bubbleView.scrollWheel(with: event)
    }

    /// Keep the last non-empty state for a short grace period so a child
    /// finishing (or a single empty poll between turns) does not make the
    /// bubble disappear or flash idle.
    func apply(roots: [Root]) {
        if pinned { bubbleView.expanded = true }
        if roots.isEmpty {
            if !bubbleView.roots.isEmpty, let last = lastNonEmptyAt, Date().timeIntervalSince(last) < 2.5 {
                return
            }
            bubbleView.roots = []
        } else {
            bubbleView.roots = roots
            lastNonEmptyAt = Date()
        }
        resize(expanded: bubbleView.expanded)
        orderFrontRegardless()
        bubbleView.needsDisplay = true
    }

    func resize(expanded: Bool) {
        guard !isUserDragging else { return }
        let width: CGFloat = expanded ? 356 : 238
        let height = bubbleView.preferredHeight(expanded: expanded)
        let screen = anchor.flatMap { screenFor(point: $0) } ?? targetScreen()
        guard let screen else { return }
        let visible = screen.visibleFrame
        let right = anchor?.x ?? (visible.maxX - 18)
        let bottom = anchor?.y ?? (visible.minY + 18)
        var x = right - width
        var y = bottom
        x = min(max(x, visible.minX + 6), visible.maxX - width - 6)
        y = min(max(y, visible.minY + 6), visible.maxY - height - 6)
        let frame = NSRect(x: x, y: y, width: width, height: height)
        setFrame(frame, display: true, animate: false)
        bubbleView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        bubbleView.needsDisplay = true
    }

    func beginUserDrag() {
        isUserDragging = true
        anchor = NSPoint(x: frame.maxX, y: frame.minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.isUserDragging else { return }
            self.endUserDrag()
        }
    }

    func dragUserWindow(to origin: NSPoint) {
        let center = NSPoint(x: origin.x + frame.width / 2, y: origin.y + frame.height / 2)
        let screen = screenFor(point: center) ?? targetScreen()
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        let y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
        anchor = NSPoint(x: frame.maxX, y: frame.minY)
        if Date().timeIntervalSince(lastAnchorSave) > 0.2, let anchor {
            lastAnchorSave = Date()
            saveAnchor(anchor)
        }
    }

    func endUserDrag() {
        isUserDragging = false
        anchor = NSPoint(x: frame.maxX, y: frame.minY)
        if let anchor { saveAnchor(anchor) }
        resize(expanded: bubbleView.expanded)
    }

    func saveState() {
        let point = NSPoint(x: frame.maxX, y: frame.minY)
        anchor = point
        saveAnchor(point)
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func screenFor(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.visibleFrame, false) }
    }

    private var positionURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dsh/run-bubble/position.json")
    }

    private func loadAnchor() -> NSPoint? {
        guard let data = try? Data(contentsOf: positionURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let x = dict["x"] as? NSNumber,
              let y = dict["y"] as? NSNumber else { return nil }
        return NSPoint(x: x.doubleValue, y: y.doubleValue)
    }

    private func loadPinned() -> Bool {
        guard let data = try? Data(contentsOf: positionURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return false }
        return dict["pinned"] as? Bool ?? false
    }

    private func saveAnchor(_ point: NSPoint) {
        let payload: [String: Any] = ["x": point.x, "y": point.y, "pinned": pinned]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(at: positionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: positionURL)
    }
}

// MARK: - App

@main
struct RunBubbleApp {
    static func main() {
        let args = CommandLine.arguments
        let demo = args.contains("--demo")
        let demoMany = args.contains("--demo-many")
        let demoSameTitle = args.contains("--demo-roots")
        let demoIdle = args.contains("--demo-idle")
        let collapsed = args.contains("--collapsed")
        let collapseFirst = args.contains("--collapse-first")
        let snapshotPath = value(after: "--snapshot", in: args)
        let scroll = Double(value(after: "--scroll", in: args) ?? "") ?? 0
        let statusURL = statusFileURL()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let panel = BubblePanel()
        panel.ignoresMouseEvents = snapshotPath != nil
        panel.bubbleView.suppressHover = snapshotPath != nil
        panel.bubbleView.expanded = panel.pinned || ((demo || demoMany || demoSameTitle || demoIdle || snapshotPath != nil) && !collapsed)
        panel.resize(expanded: panel.bubbleView.expanded)

        func applyDemo() {
            if demoIdle {
                panel.apply(roots: [])
            } else if demoMany {
                panel.apply(roots: demoManyRoots())
            } else if demoSameTitle {
                panel.apply(roots: demoSameTitleRoots())
            } else {
                panel.apply(roots: demoRoots())
            }
            if collapseFirst {
                panel.bubbleView.collapseFirstRootForDemo()
                panel.resize(expanded: true)
            }
            panel.bubbleView.scrollOffset = CGFloat(scroll)
            panel.bubbleView.needsDisplay = true
        }

        if demo || demoMany || demoSameTitle || demoIdle {
            applyDemo()
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let path = snapshotPath { writeSnapshot(panel, path) }
                if snapshotPath != nil { NSApp.terminate(nil) }
            }
            app.run()
            return
        }

        // Startup state: idle and mounted, even before any session exists.
        panel.apply(roots: [])

        // Pulse the status dot without animating layout.
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            tick += 1
            panel.bubbleView.pulse = (tick % 2 == 0) ? 0.55 : 1.0
            panel.bubbleView.needsDisplay = true
        }

        func reload() {
            if demo || demoMany || demoSameTitle || demoIdle { return }
            guard let data = try? Data(contentsOf: statusURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                panel.apply(roots: [])
                return
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: statusURL.path),
               let modified = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 6 {
                panel.apply(roots: [])
                return
            }
            let roots = (dict["roots"] as? [Any])?.compactMap(parseRoot) ?? []
            panel.apply(roots: roots)
        }

        reload()
        if snapshotPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let path = snapshotPath { writeSnapshot(panel, path) }
                NSApp.terminate(nil)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { reload() }
        }
        app.run()
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func statusFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["RUN_BUBBLE_STATUS_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("status.json")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dsh/run-bubble/status.json")
    }

    static func writeSnapshot(_ panel: BubblePanel, _ path: String) {
        let view = panel.bubbleView
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    static func demoRoots() -> [Root] {
        var root = Root()
        root.id = "96197fc7-89e7-448e-90b5-ad0c994773a8"
        root.title = "Call the subagent tool exactly"
        root.startedAt = Date().timeIntervalSince1970 * 1000 - 754_000
        root.active = true
        root.turn = 1
        root.model = "deepseek-flash"
        root.effort = "high"
        root.source = "codex"
        root.sourceLabel = "Codex"
        root.sourceConfidence = "explicit"
        root.titleSource = "explicit"
        root.taskPreview = "Refactor the auth middleware into a provider chain"
        root.colorKey = 0
        root.tokens = Tokens(input: 6400, output: 541, cacheRead: 19100, total: 26200)
        var child = Child()
        child.id = "66756e38-5fcf-4572-9c7b-c8fbf0b9f711"
        child.label = "bubble child test"
        child.parent = root.id
        child.startedAt = Date().timeIntervalSince1970 * 1000 - 32_000
        child.active = true
        child.model = "deepseek-flash"
        child.effort = "high"
        child.tokens = Tokens(input: 3227, output: 82, cacheRead: 5376, total: 8685)
        root.children = [child]
        return [root]
    }

    static func demoSameTitleRoots() -> [Root] {
        let now = Date().timeIntervalSince1970 * 1000
        let ids = ["b7b0142f", "1c78e458", "e7c6993a", "0b7b9455", "ab606f91"]
        let tasks = [
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/CI",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/API",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/WEB",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/DOCS",
            "Work only inside /Users/you/Projects/agent-ledger/wo/work/p7b-2026-10-16/OPS"
        ]
        return ids.enumerated().map { index, short in
            var root = Root()
            root.id = short + "-0000-4000-8000-00000000000\(index)"
            root.title = "Work only inside /Users/you/Projects/agent-ledger"
            root.startedAt = now - Double(3_180_000 + index * 17_000)
            root.active = true
            root.turn = 1
            root.model = "deepseek-flash"
            root.effort = "high"
            root.source = "terminal"
            root.sourceLabel = "Terminal"
            root.sourceConfidence = "explicit"
            root.titleSource = "fallback"
            root.taskPreview = tasks[index]
            root.colorKey = index
            root.tokens = Tokens(input: 12000 + index * 1100, output: 1200 + index * 90, cacheRead: 42000 + index * 2300, total: 55200 + index * 3490)
            return root
        }
    }

    static func demoManyRoots() -> [Root] {
        var first = Root()
        first.id = "96197fc7-89e7-448e-90b5-ad0c994773a8"
        first.title = "Fan-out: refactor auth modules"
        first.startedAt = Date().timeIntervalSince1970 * 1000 - 1_254_000
        first.active = true
        first.turn = 2
        first.model = "deepseek-flash"
        first.effort = "max"
        first.source = "codex"
        first.sourceLabel = "Codex"
        first.sourceConfidence = "explicit"
        first.titleSource = "explicit"
        first.taskPreview = "Split auth into provider adapters and update 14 call sites"
        first.colorKey = 0
        first.tokens = Tokens(input: 18400, output: 2411, cacheRead: 47100, total: 67911)
        for index in 1...14 {
            var child = Child()
            child.id = "codex-child-\(index)-0000-0000-0000-000000000000"
            child.label = "worker \(index): refactor module \(index)"
            child.parent = first.id
            child.startedAt = Date().timeIntervalSince1970 * 1000 - Double(60 - index * 3) * 1000
            child.active = true
            child.model = "deepseek-flash"
            child.effort = "high"
            child.tokens = Tokens(input: 1200 + index * 100, output: 60 + index * 10, cacheRead: 3000, total: 4260 + index * 110)
            first.children.append(child)
        }

        var second = Root()
        second.id = "4f3c2a10-1234-4abc-9def-556677889900"
        second.title = "Parallel test repair"
        second.startedAt = Date().timeIntervalSince1970 * 1000 - 620_000
        second.active = true
        second.turn = 1
        second.model = "deepseek-flash"
        second.effort = "high"
        second.source = "claude-code"
        second.sourceLabel = "Claude Code"
        second.sourceConfidence = "inferred"
        second.titleSource = "explicit"
        second.taskPreview = "Repair flaky integration tests and rerun the suite"
        second.colorKey = 2
        second.tokens = Tokens(input: 8200, output: 930, cacheRead: 21000, total: 30130)
        for index in 1...8 {
            var child = Child()
            child.id = "claude-child-\(index)-0000-0000-0000-000000000000"
            child.label = "test worker \(index): repair suite \(index)"
            child.parent = second.id
            child.startedAt = Date().timeIntervalSince1970 * 1000 - Double(40 - index * 3) * 1000
            child.active = true
            child.model = "deepseek-flash"
            child.effort = "high"
            child.tokens = Tokens(input: 900 + index * 80, output: 40 + index * 8, cacheRead: 2000, total: 2940 + index * 88)
            second.children.append(child)
        }
        return [first, second]
    }
}
