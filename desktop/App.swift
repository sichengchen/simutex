import AppKit

class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    convenience init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: #selector(invoke))
        target = self; bezelStyle = .rounded; actionHandler = action
    }
    @objc private func invoke() { actionHandler?() }
}
func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); return field
}
func stack(_ orientation: NSUserInterfaceLayoutOrientation, _ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = orientation; s.spacing = spacing; s.alignment = orientation == .vertical ? .leading : .centerY; return s
}

func symbolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> ActionButton {
    let b = ActionButton("", action: action)
    b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
    b.imagePosition = .imageOnly; b.contentTintColor = .labelColor; b.toolTip = help; b.setAccessibilityLabel(help)
    b.bezelStyle = .texturedRounded; b.controlSize = .small
    b.widthAnchor.constraint(equalToConstant: 28).isActive = true
    b.heightAnchor.constraint(equalToConstant: 26).isActive = true
    return b
}

// Retain NSButton's keyboard and accessibility behavior without its permanent bezel.
final class QuietIconButton: ActionButton {
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let color: NSColor = hovered && isEnabled ? .labelColor : .secondaryLabelColor
        if let icon = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) {
            let scale = min(16 / max(1, icon.size.width), 16 / max(1, icon.size.height))
            let size = NSSize(width: icon.size.width*scale, height: icon.size.height*scale)
            icon.draw(in: NSRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil)
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}
func controlButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> QuietIconButton {
    let button = QuietIconButton("", action: action)
    button.isBordered = false; button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    button.toolTip = help; button.setAccessibilityLabel(help)
    button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
}

final class SimulatorTile: NSView {
    var device: SimulatorDevice
    weak var controller: AppController?
    let display = SimulatorView()
    let name = label("", size: 12, weight: .medium)
    let sessionOwner = label("", size: 11)
    let message = label("", size: 12)
    let controls = NSStackView()
    let spinner = NSProgressIndicator()
    let ownership = NSImageView()
    private var more: ActionButton!
    private var connectGeneration = 0
    private var connecting = false
    private var retry: DispatchWorkItem?
    private var observedState = ""
    private var large = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(device: SimulatorDevice, controller: AppController) {
        self.device = device; self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        name.lineBreakMode = .byTruncatingTail
        sessionOwner.lineBreakMode = .byTruncatingMiddle; sessionOwner.textColor = .secondaryLabelColor
        sessionOwner.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        message.textColor = .secondaryLabelColor; message.maximumNumberOfLines = 3; message.isHidden = true
        controls.orientation = .horizontal; controls.spacing = 4
        controls.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        controls.wantsLayer = true; controls.layer?.cornerRadius = 9; controls.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        more = symbolButton("ellipsis", "Device actions") { [weak self] in self?.showActions() }
        more.isBordered = false
        ownership.imageScaling = .scaleProportionallyDown
        for view in [display, name, sessionOwner, ownership, more!, controls, message, spinner] { addSubview(view) }
        display.onFocus = { [weak self] in guard let self else { return }; self.controller?.focus(self.device.udid) }
        display.onGeometryChange = { [weak self] in self?.controller?.layoutTiles() }
        display.onFailure = { [weak self] error in self?.showFailure(error) }
        update(device)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let header: CGFloat = 54
        let footer: CGFloat = large ? 38 : 0
        let inset: CGFloat = 12
        let centerY = bounds.height - 20
        let titleX: CGFloat = inset + 16 + 8
        let titleHeight = name.intrinsicContentSize.height
        ownership.frame = NSRect(x: inset, y: centerY-8, width: 16, height: 16)
        more.frame = NSRect(x: bounds.width-inset-28, y: centerY-13, width: 28, height: 26)
        name.frame = NSRect(x: titleX, y: centerY-titleHeight/2,
                            width: max(0,more.frame.minX-8-titleX), height: titleHeight)
        let ownerHeight = sessionOwner.intrinsicContentSize.height
        sessionOwner.frame = NSRect(x: titleX, y: bounds.height-40-ownerHeight/2,
                                    width: max(0,bounds.width-inset-titleX), height: ownerHeight)
        display.frame = NSRect(x: 4, y: footer+4, width: max(0,bounds.width-8), height: max(0,bounds.height-header-footer-4))
        let count = CGFloat(controls.arrangedSubviews.count)
        let controlWidth = count*32 + max(0,count-1)*4 + 8
        controls.frame = NSRect(x: (bounds.width-controlWidth)/2, y: 3, width: controlWidth, height: 32)
        message.frame = NSRect(x: 16, y: bounds.midY-35, width: max(0,bounds.width-32), height: 70)
        spinner.frame = NSRect(x: bounds.midX-8, y: bounds.midY-8, width: 16, height: 16)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; applyFocus() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyFocus() }
    func update(_ next: SimulatorDevice) {
        let changed = device.owner != next.owner || observedState != next.state
        device = next; observedState = next.state
        name.stringValue = next.name
        sessionOwner.stringValue = next.owner ?? ""; sessionOwner.isHidden = next.owner == nil
        sessionOwner.toolTip = next.owner; sessionOwner.setAccessibilityLabel(next.owner ?? "")
        toolTip = "\(next.runtimeLabel)\n\(next.owner ?? "Available")\n\(next.description)"
        ownership.image = NSImage(systemSymbolName: next.owner == nil ? "lock.open" : "lock", accessibilityDescription: next.owner ?? "Available")
        ownership.contentTintColor = .secondaryLabelColor
        ownership.toolTip = next.owner ?? "Available"
        controls.arrangedSubviews.forEach { controls.removeArrangedSubview($0); $0.removeFromSuperview() }
        let manual = next.owner == AppSettings.manualOwner
        if manual {
            controls.addArrangedSubview(controlButton("house", "Home") { [weak self] in self?.display.session?.home() })
            controls.addArrangedSubview(controlButton("rotate.right", "Rotate") { [weak self] in self?.rotate() })
            controls.addArrangedSubview(controlButton("arrow.up.left.and.arrow.down.right", "Enlarge") { [weak self] in guard let self else { return }; self.controller?.enlarge(self.device.udid) })
        }
        if manual { controls.addArrangedSubview(controlButton("lock.open", "Unlock") { [weak self] in self?.unlock() }) }
        if changed { disconnect() }
        if next.running && display.session == nil && !connecting { connect() }
        applyFocus(); needsLayout = true
    }
    func setLarge(_ large: Bool) { self.large = large; name.font = .systemFont(ofSize: large ? 13 : 11, weight: .medium); needsLayout = true; display.needsDisplay = true }
    func applyFocus() {
        let manual = device.owner == AppSettings.manualOwner, focused = controller?.focused == device.udid
        display.framesPerSecond = large ? (focused ? 60 : 30) : 5
        display.interactive = manual && large && display.session != nil
        layer?.borderWidth = focused && manual && large ? 2 : 0.5
        layer?.borderColor = (focused && manual && large ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        controls.isHidden = !large || !(hovered || focused)
        controls.alphaValue = controls.isHidden ? 0 : 1
    }
    func showActions() {
        display.cancelInput()
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: String) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self; item.representedObject = action; menu.addItem(item)
        }
        if device.owner == AppSettings.manualOwner {
            add("Unlock", "lock.open", "unlock")
            if !large { add("Show in workspace", "arrow.up.left.and.arrow.down.right", "show") }
        } else { add(device.owner == nil ? "Use manually" : "Take over…", "lock", "claim") }
        menu.addItem(.separator())
        add("Copy agent instructions", "doc.on.doc", "copy")
        add("Edit description…", "text.alignleft", "description")
        add("Hooks…", "point.3.connected.trianglepath.dotted", "hooks")
        menu.addItem(.separator())
        add("Device details…", "info.circle", "details")
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.minY), in: self)
    }
    override func rightMouseDown(with event: NSEvent) { showActions() }
    @objc private func menuAction(_ item: NSMenuItem) {
        switch item.representedObject as? String {
        case "unlock": unlock()
        case "claim": claim()
        case "show": controller?.enlarge(device.udid); controller?.focus(device.udid)
        case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(instructions(for: device), forType: .string)
        default: controller?.inspect(device.udid, section: item.representedObject as? String ?? "details")
        }
    }
    func showFailure(_ error: String) { spinner.stopAnimation(nil); message.stringValue = error; message.toolTip = error; message.isHidden = false }
    func connect() {
        guard device.running else { return }
        connecting = true; connectGeneration += 1
        let token = connectGeneration, udid = device.udid, manual = device.owner == AppSettings.manualOwner, directory = AppSettings.developerDirectory
        message.isHidden = true; spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try SXSimulatorSession(udid: udid, developerDirectory: directory)
                if manual { session.setOwnershipLockPath(AppSettings.lockPath(udid), owner: AppSettings.manualOwner); try session.enableInput() }
                DispatchQueue.main.async {
                    guard let self, self.connectGeneration == token else { session.close(); return }
                    self.connecting = false; self.display.session = session
                    self.spinner.stopAnimation(nil); self.message.isHidden = true; self.applyFocus()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.connectGeneration == token else { return }
                    self.connecting = false; self.showFailure(error.localizedDescription)
                    let retry = DispatchWorkItem { [weak self] in self?.connect() }; self.retry = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: retry)
                }
            }
        }
    }
    func disconnect() {
        connectGeneration += 1; connecting = false; retry?.cancel(); retry = nil
        display.cancelInput(); display.interactive = false
        let session = display.session; display.session = nil
        DispatchQueue.global(qos: .utility).async { session?.close() }
    }
    func claim() {
        guard let controller else { return }
        var args = ["claim", device.udid, "--owner", AppSettings.manualOwner]
        if let owner = device.owner, owner != AppSettings.manualOwner {
            let alert = NSAlert(); alert.messageText = "Take over \(device.name)?"
            alert.informativeText = "Current session: \(owner)\n\nThis transfers the reservation to \(AppSettings.manualOwner). It does not stop the agent or cancel commands already running."
            alert.addButton(withTitle: "Take over"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            args = ["takeover", device.udid, "--owner", AppSettings.manualOwner, "--expected-owner", owner]
        }
        spinner.startAnimation(nil); setControlsEnabled(false)
        let udid = device.udid
        controller.cli.run(args) { [weak self, weak controller] result in
            self?.spinner.stopAnimation(nil); self?.setControlsEnabled(true)
            switch result {
            case .success:
                controller?.expanded = nil; AppSettings.defaults.removeObject(forKey: "expanded")
                controller?.focus(udid); controller?.layoutTiles()
                if self?.device.running == true { return }
                controller?.cli.simctl(["boot", udid]) { result in
                    if case .failure(let error) = result, !(self?.device.running ?? false) { controller?.showError(error.localizedDescription) }
                }
            case .failure(let error): controller?.showError(error.localizedDescription)
            }
        }
    }
    func unlock() {
        display.cancelInput(); display.interactive = false; setControlsEnabled(false)
        controller?.cli.run(["release", device.udid, "--owner", AppSettings.manualOwner]) { [weak self] result in
            self?.spinner.stopAnimation(nil); self?.setControlsEnabled(true)
            if case .failure(let error) = result { self?.controller?.showError(error.localizedDescription); self?.applyFocus() }
        }
    }
    func setControlsEnabled(_ enabled: Bool) { more.isEnabled = enabled; controls.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = enabled } }
    func rotate() {
        display.cancelInput()
        let current = display.session?.orientation ?? 1
        let target = current == 1 ? 3 : 1
        do { try display.session?.rotate(target) } catch { controller?.showError(error.localizedDescription) }
    }
    deinit { retry?.cancel(); display.session?.close() }
}

final class PreviewDocument: NSView { override var isFlipped: Bool { true } }

final class WorkspaceView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {
    let cli = CLIClient()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    var devices = [SimulatorDevice]()
    var tiles = [String: SimulatorTile]()
    var focused = AppSettings.defaults.string(forKey: "focused")
    var expanded = AppSettings.defaults.string(forKey: "expanded")
    private let workspace = WorkspaceView()
    private let canvas = NSView()
    private let previews = NSScrollView()
    private let previewDocument = PreviewDocument()
    private let rail = NSView()
    private let errorBanner = label("", size: 12)
    private var previewVisible = AppSettings.defaults.object(forKey: "previewsVisible") as? Bool ?? true
    private var emptyButton: NSButton!
    private var inspectors = [String: InspectorController]()
    private var settingsController: SettingsController?
    var manualViewportHeight: CGFloat { canvas.bounds.height }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window.title = "Simutex"; window.minSize = NSSize(width: 600, height: 480); window.delegate = self
        window.setFrameAutosaveName("SimutexWorkspace"); window.center(); window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "WorkspaceToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        configureMenu()
        window.contentView = workspace
        emptyButton = ActionButton("Open simulator") { [weak self] in self?.showPicker() }
        emptyButton.bezelStyle = .rounded; emptyButton.controlSize = .large
        workspace.wantsLayer = true; workspace.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        rail.wantsLayer = true; rail.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rail.addSubview(previews)
        previews.drawsBackground = false; previews.hasVerticalScroller = true; previews.autohidesScrollers = true
        previews.documentView = previewDocument
        errorBanner.textColor = .systemOrange; errorBanner.isHidden = true; errorBanner.lineBreakMode = .byTruncatingTail
        for view in [canvas, rail, emptyButton!, errorBanner] { workspace.addSubview(view) }
        workspace.onLayout = { [weak self] in self?.layoutTiles() }
        cli.onInventory = { [weak self] devices in self?.receive(devices) }
        cli.onError = { [weak self] error in
            self?.errorBanner.stringValue = error; self?.errorBanner.toolTip = error; self?.errorBanner.isHidden = false
            self?.tiles.values.forEach { $0.display.interactive = false }
        }
        cli.startWatching(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("add"), .init("grid"), .init("previews"), .init("inspector"), .init("settings")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let specs: [String: (String, String)] = ["add":("plus","Add Simulator"),"grid":("square.grid.2x2","Layout"),"previews":("sidebar.right","Previews"),"inspector":("info.circle","Inspector"),"settings":("gearshape","Settings")]
        guard let spec = specs[id.rawValue] else { return nil }
        item.label = spec.1; item.toolTip = spec.1
        item.image = NSImage(systemSymbolName: spec.0, accessibilityDescription: spec.1)
        item.target = self; item.action = #selector(toolbarAction(_:))
        return item
    }
    @objc private func toolbarAction(_ item: NSToolbarItem) {
        switch item.itemIdentifier.rawValue {
        case "add": showPicker()
        case "grid": expanded = nil; AppSettings.defaults.removeObject(forKey: "expanded"); layoutTiles()
        case "previews": togglePreviews()
        case "inspector": if let focused { inspect(focused) }
        case "settings": showSettings()
        default: break
        }
    }
    func togglePreviews() {
        previewVisible.toggle(); AppSettings.defaults.set(previewVisible, forKey: "previewsVisible"); layoutTiles()
    }
    func receive(_ devices: [SimulatorDevice]) {
        self.devices = devices
        let ids = Set(devices.map(\.udid))
        for id in Array(tiles.keys) where !ids.contains(id) { tiles[id]?.disconnect(); tiles.removeValue(forKey: id) }
        for device in devices {
            if let tile = tiles[device.udid] { tile.update(device) }
            else if device.running || device.owner == AppSettings.manualOwner { tiles[device.udid] = SimulatorTile(device: device, controller: self) }
        }
        errorBanner.isHidden = true
        window.contentView?.layoutSubtreeIfNeeded()
        layoutTiles()
    }
    func layoutTiles() {
        guard emptyButton != nil else { return }
        let safeTop = window.contentLayoutRect.height
        let width = workspace.bounds.width
        let manual = devices.filter { $0.owner == AppSettings.manualOwner }
        var shown = manual.filter { expanded == nil || $0.udid == expanded }
        if shown.isEmpty && !manual.isEmpty { expanded = nil; shown = manual }
        let shownIDs = Set(shown.map(\.udid))
        let small = devices.filter { $0.running && !shownIDs.contains($0.udid) }
        let railWidth: CGFloat = previewVisible && !small.isEmpty ? (width >= 1100 && small.count > 1 ? 320 : 180) : 0
        rail.isHidden = railWidth == 0
        rail.frame = NSRect(x: width-railWidth, y: 0, width: railWidth, height: safeTop)
        previews.frame = NSRect(x: 12, y: 12, width: max(0,railWidth-24), height: max(0,safeTop-24))
        canvas.frame = NSRect(x: 20, y: 18, width: max(0,width-railWidth-40), height: max(0,safeTop-36))
        emptyButton.isHidden = !shown.isEmpty
        emptyButton.frame = NSRect(x: canvas.frame.midX-80, y: safeTop/2-18, width: 160, height: 36)
        errorBanner.frame = NSRect(x: 24, y: safeTop-28, width: max(0,width-48), height: 20)
        let frames = WorkspaceLayout.frames(aspects: shown.map { tiles[$0.udid]?.display.aspectRatio ?? 0.46 }, in: canvas.bounds)
        for tile in tiles.values { tile.isHidden = true }
        for (index, device) in shown.enumerated() {
            guard let tile = tiles[device.udid] else { continue }
            if tile.superview !== canvas { tile.removeFromSuperview(); canvas.addSubview(tile) }
            tile.frame = frames[index]; tile.isHidden = false; tile.setLarge(true); tile.applyFocus()
        }
        let columns = railWidth >= 300 ? 2 : 1
        let contentWidth = max(0, previews.contentSize.width)
        let cellWidth = max(0, (contentWidth-CGFloat(columns-1)*12)/CGFloat(columns))
        var previewFrames = [NSRect](), y: CGFloat = 0
        for start in stride(from: 0, to: small.count, by: columns) {
            let row = Array(small[start..<min(start+columns,small.count)])
            let heights = row.map { (cellWidth-8)/max(0.3,tiles[$0.udid]?.display.aspectRatio ?? 0.46)+58 }
            let height = heights.max() ?? 0
            for (column,h) in heights.enumerated() { previewFrames.append(NSRect(x: CGFloat(column)*(cellWidth+12), y: y, width: cellWidth, height: h)) }
            y += height+16
        }
        let documentHeight = max(previews.contentSize.height,y)
        previewDocument.frame = NSRect(x:0,y:0,width:contentWidth,height:documentHeight)
        for (index,device) in small.enumerated() {
            guard let tile = tiles[device.udid] else { continue }
            if tile.superview !== previewDocument { tile.removeFromSuperview(); previewDocument.addSubview(tile) }
            tile.frame = previewFrames[index]; tile.isHidden = !previewVisible; tile.setLarge(false); tile.applyFocus()
        }
    }

    func focus(_ udid: String) { focused = udid; AppSettings.defaults.set(udid, forKey: "focused"); tiles.values.forEach { $0.applyFocus() } }
    func enlarge(_ udid: String) { expanded = expanded == udid ? nil : udid; AppSettings.defaults.set(expanded, forKey: "expanded"); layoutTiles() }
    func windowDidResize(_ notification: Notification) { layoutTiles() }
    func windowDidResignKey(_ notification: Notification) { tiles.values.forEach { $0.display.cancelInput() } }
    func showError(_ message: String) { let a = NSAlert(); a.messageText = "Simutex"; a.informativeText = message; a.runModal() }
    func inspect(_ udid: String, section: String = "details") {
        guard let device = devices.first(where: { $0.udid == udid }) else { return }
        let inspector = InspectorController(device: device, app: self, section: section); inspectors[udid] = inspector; inspector.showWindow(nil)
    }
    func showSettings() { settingsController = SettingsController(app: self); settingsController?.showWindow(nil) }
    func settingsChanged() { tiles.values.forEach { $0.disconnect() }; cli.startWatching() }
    func showPicker() {
        let menu = NSMenu()
        for device in devices {
            let item = NSMenuItem(title: "\(device.name) (\(device.runtimeLabel))", action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: device.owner == nil ? "iphone" : "lock", accessibilityDescription: device.owner ?? "Available")
            item.toolTip = "\(device.state)\n\(device.owner ?? "Available")\n\(device.description)"
            item.target = self; item.representedObject = device.udid; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: window.contentView!.bounds.height - 70), in: window.contentView)
    }
    @objc func pickDevice(_ item: NSMenuItem) {
        guard let udid = item.representedObject as? String, let device = devices.first(where: { $0.udid == udid }) else { return }
        if tiles[udid] == nil { tiles[udid] = SimulatorTile(device: device, controller: self) }; tiles[udid]?.claim()
    }
    @objc func pasteToSimulator() {
        guard let focused, let tile = tiles[focused], tile.device.owner == AppSettings.manualOwner, tile.display.interactive, let text = NSPasteboard.general.string(forType: .string) else { return }
        cli.simctl(["pbcopy", focused], input: text.data(using: .utf8)) { [weak self, weak tile] result in
            if case .failure(let e) = result { self?.showError(e.localizedDescription); return }
            guard let tile, tile.display.interactive else { return }
            tile.display.session?.keyUsage(227, down: true); tile.display.session?.keyUsage(25, down: true)
            tile.display.session?.keyUsage(25, down: false); tile.display.session?.keyUsage(227, down: false)
        }
    }
    private func configureMenu() {
        let menu = NSMenu(), app = NSMenu(), edit = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = app; menu.addItem(appItem)
        app.addItem(withTitle: "Quit Simutex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        for (title, action, key) in [("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let paste = edit.addItem(withTitle: "Paste into Simulator", action: #selector(pasteToSimulator), keyEquivalent: "V"); paste.target = self
        NSApp.mainMenu = menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { cli.stopWatching(); tiles.values.forEach { $0.disconnect() } }
}

@main
struct SimutexApplication {
    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        withExtendedLifetime(controller) { application.run() }
    }
}
