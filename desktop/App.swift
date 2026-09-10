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

func controlButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> ActionButton {
    let button = ActionButton("", action: action)
    button.bezelStyle = .toolbar; button.controlSize = .regular
    button.isBordered = true; button.showsBorderOnlyWhileMouseInside = true
    button.imagePosition = .imageOnly
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
    button.toolTip = help; button.setAccessibilityLabel(help)
    button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
}

final class ScreenShade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SimulatorTile: NSView {
    var device: SimulatorDevice
    weak var controller: AppController?
    let display = SimulatorView()
    let name = label("", size: 12, weight: .medium)
    let sessionOwner = label("", size: 11)
    let message = label("", size: 12)
    private let unavailable = label("", size: 18, weight: .medium)
    private let screenShade = ScreenShade()
    let controls = NSStackView()
    private let controlsBackground: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = 12
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .withinWindow
        effect.state = .active; effect.wantsLayer = true; effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        return effect
    }()
    let spinner = NSProgressIndicator()
    let ownership = NSImageView()
    private var more: ActionButton!
    private var connectGeneration = 0
    private var connecting = false
    private var retry: DispatchWorkItem?
    private var observedState = ""
    private var inputFailures = 0
    private var lastInputFailure = Date.distantPast
    private var recovering = false
    var headerHeight: CGFloat { device.owner == nil ? 32 : 48 }
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
        unavailable.alignment = .center; unavailable.maximumNumberOfLines = 3
        unavailable.lineBreakMode = .byWordWrapping
        unavailable.textColor = .white
        screenShade.wantsLayer = true
        screenShade.layer?.backgroundColor = NSColor.black.cgColor
        screenShade.alphaValue = 0
        message.textColor = .secondaryLabelColor; message.maximumNumberOfLines = 3; message.isHidden = true
        controls.orientation = .horizontal; controls.spacing = 4
        controls.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        if #available(macOS 26.0, *), let glass = controlsBackground as? NSGlassEffectView {
            glass.contentView = controls
        } else { controlsBackground.addSubview(controls) }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        more = controlButton("ellipsis", "Device actions") { [weak self] in self?.showActions() }
        ownership.imageScaling = .scaleProportionallyDown
        for view in [display, screenShade, name, sessionOwner, ownership, controlsBackground, unavailable, message, spinner] { addSubview(view) }
        display.onFocus = { [weak self] in guard let self else { return }; self.controller?.focus(self.device.udid) }
        display.onGeometryChange = { [weak self] in self?.controller?.layoutTiles() }
        display.onFailure = { [weak self] error in self?.showFailure(error) }
        display.onInputFailure = { [weak self] error in self?.handleInputFailure(error) }
        update(device)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let header = headerHeight
        let footer: CGFloat = 38
        let inset: CGFloat = large ? 12 : 4
        let centerY = bounds.height - 16
        let titleX: CGFloat = inset + 16 + 8
        let titleHeight = name.intrinsicContentSize.height
        ownership.frame = NSRect(x: inset, y: centerY-8, width: 16, height: 16)
        name.frame = NSRect(x: titleX, y: centerY-titleHeight/2,
                            width: max(0,bounds.width-inset-titleX), height: titleHeight)
        let ownerHeight = sessionOwner.intrinsicContentSize.height
        sessionOwner.frame = NSRect(x: titleX, y: bounds.height-34-ownerHeight/2,
                                    width: max(0,bounds.width-inset-titleX), height: ownerHeight)
        display.frame = NSRect(x: 4, y: footer+4, width: max(0,bounds.width-8), height: max(0,bounds.height-header-footer-4))
        let capacity = max(1, Int((bounds.width-8)/36))
        for (index, button) in controls.arrangedSubviews.enumerated() {
            button.isHidden = index < controls.arrangedSubviews.count-capacity
        }
        let count = CGFloat(controls.arrangedSubviews.filter { !$0.isHidden }.count)
        let controlWidth = count*32 + max(0,count-1)*4 + 8
        controlsBackground.frame = NSRect(x: (bounds.width-controlWidth)/2, y: 3, width: controlWidth, height: 32)
        controls.frame = controlsBackground.bounds
        screenShade.frame = display.frame
        unavailable.font = .systemFont(ofSize: large ? 18 : 12, weight: .medium)
        let textWidth = max(0, display.frame.width-32)
        let textHeight = unavailable.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 120)).height ?? 60
        unavailable.frame = NSRect(x: display.frame.minX+16, y: display.frame.midY-textHeight/2, width: textWidth, height: textHeight)
        message.frame = NSRect(x: 16, y: display.frame.minY+12, width: max(0,bounds.width-32), height: 50)
        spinner.frame = NSRect(x: bounds.midX-8, y: bounds.midY-8, width: 16, height: 16)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateHover() }
    private func updateHover() {
        let show = hovered && device.viewOnly
        unavailable.isHidden = !show
        let opacity: CGFloat = show ? 0.6 : 0
        if screenShade.alphaValue != opacity {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                screenShade.animator().alphaValue = opacity
            }
        }
    }
    func update(_ next: SimulatorDevice) {
        let changed = device.owner != next.owner || observedState != next.state
        device = next; observedState = next.state
        name.stringValue = next.name
        sessionOwner.stringValue = next.owner ?? ""; sessionOwner.isHidden = next.owner == nil
        sessionOwner.toolTip = next.owner; sessionOwner.setAccessibilityLabel(next.owner ?? "")
        toolTip = "\(next.runtimeLabel)\n\(next.lockStatus)\n\(next.description)"
        ownership.image = NSImage(systemSymbolName: next.isLocked ? "lock.fill" : "lock.open", accessibilityDescription: next.lockStatus)
        ownership.contentTintColor = next.lockedByMe ? .controlAccentColor : (next.isLocked ? .systemOrange : .secondaryLabelColor)
        ownership.toolTip = next.lockStatus
        unavailable.stringValue = next.owner.map { "Simulator in Use\n\($0)\nView only" } ?? "Lock this simulator to use it"
        updateHover()
        refreshControls()
        if changed { disconnect() }
        if next.running && display.session == nil && !connecting { connect() }
        if !next.running { spinner.stopAnimation(nil); message.stringValue = "Not booted"; message.toolTip = nil; message.isHidden = false }
        applyFocus(); needsLayout = true
    }
    // Driving controls belong only to the lock holder; everyone else gets a
    // read-only tile plus the means to take the lock.
    func refreshControls() {
        controls.arrangedSubviews.forEach { controls.removeArrangedSubview($0); $0.removeFromSuperview() }
        let mine = device.lockedByMe
        let automatic = controller?.layoutMode == .auto
        defer {
            controls.addArrangedSubview(more)
            needsLayout = true
        }
        func addOwnershipControl() {
            if mine {
                controls.addArrangedSubview(controlButton("lock.open", "Unlock") { [weak self] in self?.unlock() })
            } else if device.isLocked {
                controls.addArrangedSubview(controlButton("lock.trianglebadge.exclamationmark", "Take over") { [weak self] in self?.claim() })
            } else {
                controls.addArrangedSubview(controlButton("lock", "Lock for my use") { [weak self] in self?.claim() })
            }
        }
        func addMembershipControl() {
            let pinned = controller?.isPinned(device.udid) == true
            controls.addArrangedSubview(controlButton(automatic ? (pinned ? "pin.slash" : "pin") : "minus.circle",
                automatic ? (pinned ? "Unpin simulator" : "Pin simulator") : "Remove from main panel") { [weak self] in
                guard let self, let controller = self.controller else { return }
                if controller.layoutMode == .auto { controller.togglePin(self.device.udid) }
                else { controller.removeFromWorkspace(self.device.udid) }
            })
        }
        guard controller?.isInWorkspace(device.udid) == true else {
            addOwnershipControl()
            if automatic { addMembershipControl() } else {
                controls.addArrangedSubview(controlButton("plus.circle", "Add to main panel") { [weak self] in guard let self else { return }; self.controller?.addToWorkspace(self.device.udid) })
            }
            needsLayout = true
            return
        }
        if mine {
            controls.addArrangedSubview(controlButton("house", "Home") { [weak self] in self?.display.session?.home() })
            controls.addArrangedSubview(controlButton("rotate.right", "Rotate") { [weak self] in self?.rotate() })
        }
        if !automatic { controls.addArrangedSubview(controlButton("arrow.up.left.and.arrow.down.right", "Enlarge") { [weak self] in guard let self else { return }; self.controller?.enlarge(self.device.udid) }) }
        addOwnershipControl()
        addMembershipControl()
        needsLayout = true
    }
    func setLarge(_ large: Bool) {
        self.large = large
        layer?.cornerRadius = large ? 16 : 0
        layer?.backgroundColor = large ? NSColor.controlBackgroundColor.cgColor : NSColor.clear.cgColor
        name.font = .systemFont(ofSize: large ? 13 : 11, weight: .medium)
        needsLayout = true; display.needsDisplay = true
    }
    func applyFocus() {
        let mine = device.lockedByMe, focused = controller?.focused == device.udid
        display.framesPerSecond = large ? (focused ? 60 : 30) : 5
        display.interactive = mine && large && display.session != nil
        layer?.borderWidth = large ? (focused && mine ? 2 : 0.5) : 0
        layer?.borderColor = (focused && mine && large ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        // Keep each simulator’s actions together and accessible without hovering.
        controlsBackground.isHidden = controls.arrangedSubviews.isEmpty
    }
    func showActions() {
        display.cancelInput()
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: String) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self; item.representedObject = action; menu.addItem(item)
        }
        if device.lockedByMe && controller?.isInWorkspace(device.udid) == true {
            add("Home", "house", "home")
            add("Rotate", "rotate.right", "rotate")
        }
        if device.lockedByMe { add("Unlock", "lock.open", "unlock") }
        else if device.isLocked { add("Take over…", "lock.trianglebadge.exclamationmark", "claim") }
        else { add("Lock for my use", "lock", "claim") }
        menu.addItem(.separator())
        if controller?.layoutMode == .auto {
            let pinned = controller?.isPinned(device.udid) == true
            add(pinned ? "Unpin simulator" : "Pin simulator", pinned ? "pin.slash" : "pin", "pin")
        } else if controller?.isInWorkspace(device.udid) == true {
            add(controller?.expanded == device.udid ? "Show all simulators" : "Enlarge", "arrow.up.left.and.arrow.down.right", "show")
            add("Remove from main panel", "minus.circle", "remove")
        } else {
            add("Add to main panel", "plus.circle", "add")
        }
        menu.addItem(.separator())
        add("Copy agent instructions", "doc.on.doc", "copy")
        add("Edit description…", "text.alignleft", "description")
        add("Hooks…", "point.3.connected.trianglepath.dotted", "hooks")
        menu.addItem(.separator())
        add("Device details…", "info.circle", "details")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
    }
    override func rightMouseDown(with event: NSEvent) { showActions() }
    @objc private func menuAction(_ item: NSMenuItem) {
        switch item.representedObject as? String {
        case "home": display.session?.home()
        case "rotate": rotate()
        case "unlock": unlock()
        case "claim": claim()
        case "show": controller?.enlarge(device.udid); controller?.focus(device.udid)
        case "add": controller?.addToWorkspace(device.udid)
        case "remove": controller?.removeFromWorkspace(device.udid)
        case "pin": controller?.togglePin(device.udid)
        case "copy": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(instructions(for: device), forType: .string)
        default: controller?.inspect(device.udid, section: item.representedObject as? String ?? "details")
        }
    }
    func showFailure(_ error: String) { spinner.stopAnimation(nil); message.stringValue = error; message.toolTip = error; message.isHidden = false }
    // Home makes the runtime reset its HID session, so one failed event is normal
    // and the transport comes back on its own. Only rebuild it once failures stick.
    func handleInputFailure(_ failure: String) {
        if Date().timeIntervalSince(lastInputFailure) > 5 { inputFailures = 0 }
        lastInputFailure = Date(); inputFailures += 1
        guard inputFailures >= 3, !recovering, let session = display.session else { return }
        inputFailures = 0; recovering = true
        // Re-enabling input can block on the transport, so never on the UI thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var recovered = false
            do { try session.recoverInput(); recovered = true } catch { recovered = false }
            DispatchQueue.main.async {
                guard let self, self.display.session === session else { return }
                self.recovering = false
                if recovered { self.message.isHidden = true }
                else { self.display.interactive = false; self.showFailure(failure) }
            }
        }
    }
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
                controller?.addToWorkspace(udid)
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
    var panelIDs = AppSettings.workspace
    var layoutMode = AppSettings.layoutMode
    var pinnedIDs = AppSettings.pinnedSimulators
    var panelMembers: [SimulatorDevice] {
        WorkspaceSelection.members(mode: layoutMode, manual: panelIDs, pinned: pinnedIDs, available: devices)
    }
    private let workspace = WorkspaceView()
    private let splitController = NSSplitViewController()
    private let mainPanel = WorkspaceView()
    private var previewItem: NSSplitViewItem!
    private let canvas = NSView()
    private let previews = NSScrollView()
    private let previewDocument = PreviewDocument()
    private let rail = WorkspaceView()
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
        emptyButton = ActionButton("Add simulator") { [weak self] in self?.showPicker() }
        emptyButton.bezelStyle = .rounded; emptyButton.controlSize = .large
        workspace.wantsLayer = true; workspace.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        rail.wantsLayer = true; rail.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rail.addSubview(previews)
        previews.drawsBackground = false; previews.hasVerticalScroller = true; previews.autohidesScrollers = true
        previews.documentView = previewDocument
        errorBanner.textColor = .systemOrange; errorBanner.isHidden = true; errorBanner.lineBreakMode = .byTruncatingTail
        let mainController = NSViewController(); mainController.view = mainPanel
        let previewController = NSViewController(); previewController.view = rail
        let mainItem = NSSplitViewItem(viewController: mainController)
        mainItem.minimumThickness = 300
        previewItem = NSSplitViewItem(sidebarWithViewController: previewController)
        previewItem.minimumThickness = 160; previewItem.maximumThickness = 320
        previewItem.preferredThicknessFraction = 0.18
        previewItem.canCollapse = true
        previewItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(mainItem); splitController.addSplitViewItem(previewItem)
        workspace.addSubview(splitController.view)
        for view in [canvas, emptyButton!, errorBanner] { mainPanel.addSubview(view) }
        workspace.onLayout = { [weak self] in
            guard let self else { return }
            self.splitController.view.frame = NSRect(x: 0, y: 0, width: self.workspace.bounds.width, height: self.window.contentLayoutRect.height)
        }
        mainPanel.onLayout = { [weak self] in self?.layoutTiles() }
        rail.onLayout = { [weak self] in self?.layoutTiles() }
        cli.onInventory = { [weak self] devices in self?.receive(devices) }
        cli.onError = { [weak self] error in
            self?.errorBanner.stringValue = error; self?.errorBanner.toolTip = error; self?.errorBanner.isHidden = false
            self?.tiles.values.forEach { $0.display.interactive = false }
        }
        cli.startWatching(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("devices"), .init("add"), .init("grid"), .init("previews"), .init("settings")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("devices")] + (layoutMode == .manual ? [.init("add")] : []) + [.init("grid"), .init("previews"), .init("settings")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let specs: [String: (String, String)] = ["devices":("iphone","Devices"),"add":("plus","Add Simulator"),"grid":("square.grid.2x2","Layout"),"previews":("sidebar.right","Previews"),"settings":("gearshape","Settings")]
        guard let spec = specs[id.rawValue] else { return nil }
        item.label = spec.1; item.toolTip = spec.1
        item.image = NSImage(systemSymbolName: spec.0, accessibilityDescription: spec.1)
        item.target = self; item.action = #selector(toolbarAction(_:))
        item.autovalidates = false
        return item
    }
    @objc private func changeLayoutMode(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let mode = LayoutMode(rawValue: value) else { return }
        layoutMode = mode; AppSettings.layoutMode = mode
        if let toolbar = window.toolbar {
            if mode == .auto, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "add" }) {
                toolbar.removeItem(at: index)
            } else if mode == .manual && !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "add" }) {
                toolbar.insertItem(withItemIdentifier: .init("add"), at: 2)
            }
        }
        receive(devices)
    }
    func showLayoutMenu() {
        let menu = NSMenu()
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(changeLayoutMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue
            item.state = layoutMode == mode ? .on : .off
            menu.addItem(item)
        }
        if layoutMode == .manual && expanded != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Show all simulators", action: #selector(showAllSimulators), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: workspace)
    }
    @objc private func showAllSimulators() {
        expanded = nil; AppSettings.defaults.removeObject(forKey: "expanded"); layoutTiles()
    }
    @objc private func toolbarAction(_ item: NSToolbarItem) {
        switch item.itemIdentifier.rawValue {
        case "devices": showDevices()
        case "add": showPicker()
        case "grid": showLayoutMenu()
        case "previews": togglePreviews()
        case "settings": showSettings()
        default: break
        }
    }
    func togglePreviews() {
        previewVisible.toggle(); AppSettings.defaults.set(previewVisible, forKey: "previewsVisible")
        updatePreviewVisibility()
    }
    func receive(_ devices: [SimulatorDevice]) {
        self.devices = devices
        let ids = Set(devices.map(\.udid))
        let memberIDs = Set(panelMembers.map(\.udid))
        for id in Array(tiles.keys) where !ids.contains(id) { tiles[id]?.disconnect(); tiles.removeValue(forKey: id) }
        for device in devices {
            if let tile = tiles[device.udid] { tile.update(device) }
            else if device.running || memberIDs.contains(device.udid) { tiles[device.udid] = SimulatorTile(device: device, controller: self) }
        }
        errorBanner.isHidden = true
        updatePreviewVisibility()
        layoutTiles(animated: true)
    }
    private func updatePreviewVisibility() {
        guard let previewItem else { return }
        let members = Set(panelMembers.map(\.udid))
        let collapsed = !previewVisible || !devices.contains { $0.running && !members.contains($0.udid) }
        guard previewItem.isCollapsed != collapsed else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { previewItem.isCollapsed = collapsed }
        else { previewItem.animator().isCollapsed = collapsed }
    }
    func layoutTiles(animated: Bool = false) {
        guard emptyButton != nil else { return }
        let safeTop = mainPanel.bounds.height
        let width = mainPanel.bounds.width
        let members = panelMembers
        var shown = members.filter { layoutMode == .auto || expanded == nil || $0.udid == expanded }
        if shown.isEmpty && !members.isEmpty { expanded = nil; shown = members }
        // The rail offers what is not already in the main panel, so members stay
        // out of it even while one of them is expanded.
        let memberIDs = Set(members.map(\.udid))
        let small = devices.filter { $0.running && !memberIDs.contains($0.udid) }
        previews.frame = rail.bounds.insetBy(dx: 4, dy: 4)
        canvas.frame = NSRect(x: 20, y: 18, width: max(0,width-40), height: max(0,safeTop-36))
        emptyButton.title = layoutMode == .auto ? "No claimed or pinned simulators" : "Add simulator"
        emptyButton.isEnabled = layoutMode == .manual
        emptyButton.isHidden = !shown.isEmpty
        emptyButton.frame = NSRect(x: canvas.frame.midX-140, y: safeTop/2-18, width: 280, height: 36)
        errorBanner.frame = NSRect(x: 24, y: safeTop-28, width: max(0,width-48), height: 20)
        let frames = WorkspaceLayout.frames(aspects: shown.map { tiles[$0.udid]?.display.aspectRatio ?? 0.46 }, in: canvas.bounds)
        for tile in tiles.values { tile.isHidden = true }
        for (index, device) in shown.enumerated() {
            guard let tile = tiles[device.udid] else { continue }
            if tile.superview !== canvas { tile.removeFromSuperview(); canvas.addSubview(tile) }
            position(tile, at: frames[index], animated: animated); tile.isHidden = false; tile.setLarge(true); tile.applyFocus()
        }
        let cellWidth = max(0, previews.contentSize.width)
        var previewFrames = [NSRect](), y: CGFloat = 0
        for device in small {
            let header = tiles[device.udid]?.headerHeight ?? 32
            let height = max(0,cellWidth-8)/max(0.3,tiles[device.udid]?.display.aspectRatio ?? 0.46)+header+42
            previewFrames.append(NSRect(x: 0, y: y, width: cellWidth, height: height))
            y += height+8
        }
        let documentHeight = max(previews.contentSize.height,y)
        previewDocument.frame = NSRect(x:0,y:0,width:cellWidth,height:documentHeight)
        for (index,device) in small.enumerated() {
            guard let tile = tiles[device.udid] else { continue }
            if tile.superview !== previewDocument { tile.removeFromSuperview(); previewDocument.addSubview(tile) }
            position(tile, at: previewFrames[index], animated: animated); tile.isHidden = false; tile.setLarge(false); tile.applyFocus()
        }
    }

    private func position(_ tile: SimulatorTile, at frame: NSRect, animated: Bool) {
        guard tile.frame != frame else { return }
        if animated && !tile.frame.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                tile.animator().frame = frame
            }
        } else { tile.frame = frame }
    }

    func focus(_ udid: String) { focused = udid; AppSettings.defaults.set(udid, forKey: "focused"); tiles.values.forEach { $0.applyFocus() } }
    func enlarge(_ udid: String) { guard layoutMode == .manual else { return }; expanded = expanded == udid ? nil : udid; AppSettings.defaults.set(expanded, forKey: "expanded"); layoutTiles(animated: true) }
    func windowDidResize(_ notification: Notification) { layoutTiles() }
    func windowDidResignKey(_ notification: Notification) { tiles.values.forEach { $0.display.cancelInput() } }
    func showError(_ message: String) { let a = NSAlert(); a.messageText = "Simutex"; a.informativeText = message; a.runModal() }
    func inspect(_ udid: String, section: String = "details") {
        guard let device = devices.first(where: { $0.udid == udid }) else { return }
        let inspector = InspectorController(device: device, app: self, section: section); inspectors[udid] = inspector; inspector.showWindow(nil)
    }
    func showSettings() { settingsController = SettingsController(app: self); settingsController?.showWindow(nil) }
    func settingsChanged() { tiles.values.forEach { $0.disconnect() }; cli.startWatching() }
    func showDevices() {
        let menu = NSMenu()
        for device in devices {
            let action = device.isLocked && !device.lockedByMe ? "View" : "Open for my use"
            let item = NSMenuItem(title: "\(device.name) (\(device.runtimeLabel)) — \(action)", action: #selector(openDevice(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: device.isLocked ? "lock.fill" : "iphone", accessibilityDescription: device.lockStatus)
            item.toolTip = "\(device.state)\n\(device.lockStatus)"
            item.target = self; item.representedObject = device.udid
            menu.addItem(item)
        }
        if devices.isEmpty {
            let item = NSMenuItem(title: "No simulators available", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: workspace)
    }
    @objc private func openDevice(_ item: NSMenuItem) {
        guard let udid = item.representedObject as? String, let device = devices.first(where: { $0.udid == udid }) else { return }
        if tiles[udid] == nil { tiles[udid] = SimulatorTile(device: device, controller: self) }
        if layoutMode == .manual { addToWorkspace(udid) }
        focus(udid)
        if !device.isLocked || device.lockedByMe { tiles[udid]?.claim() }
    }
    func showPicker() {
        guard layoutMode == .manual else { return }
        let menu = NSMenu()
        for device in devices {
            let member = isInWorkspace(device.udid)
            let item = NSMenuItem(title: "\(device.name) (\(device.runtimeLabel))", action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: device.isLocked ? "lock.fill" : "iphone", accessibilityDescription: device.lockStatus)
            item.toolTip = "\(device.state)\n\(device.lockStatus)\n\(device.description)"
            // Already-added devices remain listed but cannot be added twice.
            item.state = member ? .on : .off
            item.isEnabled = !member
            item.target = self; item.representedObject = device.udid; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: window.contentView!.bounds.height - 70), in: window.contentView)
    }
    @objc func pickDevice(_ item: NSMenuItem) {
        guard let udid = item.representedObject as? String else { return }
        addToWorkspace(udid)
    }
    func isInWorkspace(_ udid: String) -> Bool { panelMembers.contains { $0.udid == udid } }
    func isPinned(_ udid: String) -> Bool { pinnedIDs.contains(udid) }
    func togglePin(_ udid: String) {
        pinnedIDs = isPinned(udid) ? WorkspaceSelection.removing(udid, from: pinnedIDs) : WorkspaceSelection.adding(udid, to: pinnedIDs)
        AppSettings.pinnedSimulators = pinnedIDs
        receive(devices)
    }
    func addToWorkspace(_ udid: String) {
        guard layoutMode == .manual else { return }
        guard let device = devices.first(where: { $0.udid == udid }) else { return }
        panelIDs = WorkspaceSelection.adding(udid, to: panelIDs)
        AppSettings.workspace = panelIDs
        if tiles[udid] == nil { tiles[udid] = SimulatorTile(device: device, controller: self) }
        expanded = nil; AppSettings.defaults.removeObject(forKey: "expanded")
        focus(udid); tiles.values.forEach { $0.refreshControls() }; updatePreviewVisibility(); layoutTiles(animated: true)
    }
    func removeFromWorkspace(_ udid: String) {
        guard layoutMode == .manual else { return }
        panelIDs = WorkspaceSelection.removing(udid, from: panelIDs)
        AppSettings.workspace = panelIDs
        if expanded == udid { expanded = nil; AppSettings.defaults.removeObject(forKey: "expanded") }
        tiles.values.forEach { $0.refreshControls() }; updatePreviewVisibility(); layoutTiles(animated: true)
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
