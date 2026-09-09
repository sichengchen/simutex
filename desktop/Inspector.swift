import AppKit

final class InspectorStack: NSStackView { override var isFlipped: Bool { true } }

final class HookEditor: NSStackView {
    let mode = NSPopUpButton()
    let executable = NSTextField(string: "")
    let arguments = NSTextField(string: "")
    let directory = NSTextField(string: NSHomeDirectory())
    let timeout = NSTextField(string: "60")
    let fields = NSStackView()
    var onChange: (() -> Void)?
    init(title: String) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        addArrangedSubview(label(title, size: 14, weight: .semibold))
        mode.addItems(withTitles: ["Inherit defaults", "Disabled", "Custom"]); addArrangedSubview(mode)
        mode.target = self; mode.action = #selector(modeChanged)
        fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 6
        addArrangedSubview(fields); fields.isHidden = true
        for (title, field) in [("Executable (absolute path)", executable), ("Arguments (one per line)", arguments), ("Working directory", directory), ("Timeout (seconds)", timeout)] {
            fields.addArrangedSubview(label(title, size: 11)); fields.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }
        arguments.maximumNumberOfLines = 4; arguments.cell?.wraps = true
        executable.placeholderString = "/path/to/setup-script"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func modeChanged() { fields.isHidden = mode.indexOfSelectedItem != 2; onChange?() }
    func load(_ value: Any?) {
        defer { modeChanged() }
        guard let value else { mode.selectItem(at: 0); return }
        if value is NSNull { mode.selectItem(at: 1); return }
        guard let hook = value as? [String: Any], let argv = hook["argv"] as? [String] else { return }
        mode.selectItem(at: 2); executable.stringValue = argv.first ?? ""
        arguments.stringValue = argv.dropFirst().joined(separator: "\n")
        directory.stringValue = hook["cwd"] as? String ?? NSHomeDirectory()
        timeout.stringValue = String((hook["timeout_seconds"] as? NSNumber)?.doubleValue ?? 60)
    }
    func configuration() throws -> [String: Any]? {
        guard mode.indexOfSelectedItem == 2 else { return nil }
        guard executable.stringValue.hasPrefix("/"), directory.stringValue.hasPrefix("/"), let seconds = Double(timeout.stringValue), seconds > 0, seconds <= 86400 else {
            throw NSError(domain: "simutex.settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Custom hooks need absolute executable and working-directory paths, and a timeout between 0 and 86400 seconds."])
        }
        let args = arguments.stringValue.isEmpty ? [] : arguments.stringValue.components(separatedBy: "\n")
        return ["argv": [executable.stringValue] + args, "cwd": directory.stringValue, "timeout_seconds": seconds]
    }
}

final class InspectorController: NSWindowController {
    weak var app: AppController?
    let device: SimulatorDevice
    let descriptionField = NSTextField(string: "")
    let pre = HookEditor(title: "Before claim")
    let post = HookEditor(title: "After claim")
    let feedback = label("", size: 11)
    var saveButton: ActionButton!
    private var sections = [NSView]()
    private var tabs: NSSegmentedControl!
    private var editActions: NSView!
    init(device: SimulatorDevice, app: AppController, section: String = "details") {
        self.device = device; self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = device.name; window.center()
        descriptionField.stringValue = device.description; descriptionField.maximumNumberOfLines = 4; descriptionField.cell?.wraps = true
        saveButton = ActionButton("Save") { [weak self] in self?.save() }; saveButton.isEnabled = false
        let copy = ActionButton("Copy agent instructions") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(instructions(for: device), forType: .string) }
        let shutdown = ActionButton("Shut down") { [weak self] in
            guard let self else { return }
            self.app?.cli.run(["status", device.udid, "--json"]) { [weak self] result in
                guard let self else { return }
                do {
                    let output = try result.get()
                    let state = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
                    guard state?["owner"] as? String == AppSettings.manualOwner else { self.app?.showError("Claim this simulator for manual use before shutting it down."); return }
                    self.app?.cli.simctl(["shutdown", device.udid]) { [weak self] result in if case .failure(let e) = result { self?.app?.showError(e.localizedDescription) } }
                } catch { self.app?.showError(error.localizedDescription) }
            }
        }
        let retry = ActionButton("Reconnect display") { [weak app] in app?.tiles[device.udid]?.disconnect(); app?.tiles[device.udid]?.connect() }
        tabs = NSSegmentedControl(labels: ["Description", "Hooks", "Device"], trackingMode: .selectOne, target: self, action: #selector(sectionChanged))
        tabs.selectedSegment = section == "description" ? 0 : section == "hooks" ? 1 : 2
        let descriptionPanel = stack(.vertical, [descriptionField, copy], spacing: 12)
        let hooksPanel = stack(.vertical, [pre, post], spacing: 18)
        let owner = label(device.owner ?? "Unlocked", size: 12)
        owner.isSelectable = true
        let identifier = label(device.udid, size: 11); identifier.isSelectable = true
        let devicePanel = stack(.vertical, [label("Session", size: 11), owner, label("Identifier", size: 11), identifier, stack(.horizontal, [retry, shutdown])], spacing: 12)
        shutdown.isEnabled = device.owner == AppSettings.manualOwner
        sections = [descriptionPanel, hooksPanel, devicePanel]
        editActions = stack(.horizontal, [saveButton, feedback])
        let body = InspectorStack(views: [tabs, descriptionPanel, hooksPanel, devicePanel, editActions])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        descriptionField.heightAnchor.constraint(equalToConstant: 58).isActive = true
        window.title = device.name; window.subtitle = device.runtimeLabel
        body.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; body.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = body
        window.contentView = scroll
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), descriptionField.widthAnchor.constraint(equalToConstant: 460)])
        pre.onChange = { [weak self] in self?.sectionChanged() }
        post.onChange = { [weak self] in self?.sectionChanged() }
        sectionChanged()
        app.cli.run(["hooks", "show", device.udid, "--json"]) { [weak self] result in
            guard let self else { return }
            do {
                let output = try result.get()
                let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
                let hooks = root?["overrides"] as? [String: Any] ?? [:]
                self.pre.load(hooks["pre_claim"]); self.post.load(hooks["post_claim"])
                let effective = root?["effective"] as? [String: Any] ?? [:]
                func summary(_ name: String) -> String { ((effective[name] as? [String: Any])?["argv"] as? [String])?.first ?? "Disabled" }
                self.pre.mode.toolTip = summary("pre_claim")
                self.post.mode.toolTip = summary("post_claim")
                self.saveButton.isEnabled = true

            } catch { self.feedback.stringValue = error.localizedDescription }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func sectionChanged() {
        guard let tabs, let window else { return }
        let selected = tabs.selectedSegment
        for (index, view) in sections.enumerated() { view.isHidden = index != selected }
        editActions.isHidden = selected == 2
        let custom = selected == 1 ? [pre, post].filter { $0.mode.indexOfSelectedItem == 2 }.count : 0
        let base = selected == 0 ? 265 : 320
        var frame = window.frame
        let height = min(CGFloat(base + custom*235), NSScreen.main?.visibleFrame.height ?? 880)
        frame.origin.y += frame.height-height; frame.size.height = height
        window.setFrame(frame, display: true, animate: true)
    }
    private func save() {
        guard let app else { return }
        do {
            let editingHooks = tabs.selectedSegment == 1
            let configurations = editingHooks ? try [pre.configuration(), post.configuration()] : [nil, nil]
            var commands: [[String]] = editingHooks ? [] : [["describe", "--", device.udid, descriptionField.stringValue]]
            var files = [URL]()
            for (index, event) in ["pre-claim", "post-claim"].enumerated() where editingHooks {
                let editor = index == 0 ? pre : post
                if let config = configurations[index] {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("simutex-hook-\(UUID().uuidString).json")
                    try JSONSerialization.data(withJSONObject: config).write(to: file, options: .atomic); files.append(file)
                    commands.append(["hooks", "set", device.udid, "--event", event, "--config", file.path])
                } else { commands.append(["hooks", editor.mode.indexOfSelectedItem == 1 ? "disable" : "inherit", device.udid, "--event", event]) }
            }
            saveButton.isEnabled = false; feedback.stringValue = "Saving…"
            func execute(_ index: Int) {
                if index == commands.count { files.forEach { try? FileManager.default.removeItem(at: $0) }; self.saveButton.isEnabled = true; self.close(); return }
                app.cli.run(commands[index]) { result in
                    if case .failure(let error) = result { files.forEach { try? FileManager.default.removeItem(at: $0) }; self.saveButton.isEnabled = true; self.feedback.stringValue = "Save stopped: \(error.localizedDescription)"; return }
                    execute(index + 1)
                }
            }
            execute(0)
        } catch { feedback.stringValue = error.localizedDescription }
    }
}

final class SettingsController: NSWindowController {
    init(app: AppController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 370), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Simutex Settings"; window.center()
        var fields = [(String, NSTextField)]()
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 10; body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        for (key, title) in [("developerDirectory", "Xcode developer directory"), ("statePath", "Shared lock directory (blank uses CLI default)"), ("metadataPath", "Simulator metadata file (blank uses CLI default)"), ("hooksPath", "Default hooks file (optional)")] {
            body.addArrangedSubview(label(title, size: 12))
            let field = NSTextField(string: AppSettings.defaults.string(forKey: key) ?? (key == "developerDirectory" ? AppSettings.developerDirectory : ""))
            field.widthAnchor.constraint(equalToConstant: 520).isActive = true; body.addArrangedSubview(field); fields.append((key,field))
        }
        body.addArrangedSubview(ActionButton("Save") { [weak self, weak app] in
            for (_, field) in fields where !field.stringValue.isEmpty && !field.stringValue.hasPrefix("/") { app?.showError("Use absolute paths in Settings."); return }
            let previousXcode = AppSettings.developerDirectory
            for (key, field) in fields { AppSettings.defaults.set(field.stringValue, forKey: key) }
            app?.settingsChanged(); self?.close()
            if AppSettings.developerDirectory != previousXcode { app?.showError("Restart Simutex to use the selected Xcode for embedded displays.") }
        })
        window.contentView = body
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
