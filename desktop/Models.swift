import Foundation
import CoreGraphics

struct SimulatorDevice: Decodable, Equatable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let owner: String?
    let description: String
    // Hook configuration is edited through CLI JSON, independent of inventory decoding.
    var running: Bool { state == "Booted" }
    var runtimeLabel: String { runtime.components(separatedBy: ".iOS-").last.map { "iOS " + $0.replacingOccurrences(of: "-", with: ".") } ?? runtime }
}
struct Inventory: Decodable { let devices: [SimulatorDevice] }

extension SimulatorDevice {
    var isLocked: Bool { owner != nil }
    func isOwned(by candidate: String) -> Bool { owner == candidate }
    var lockedByMe: Bool { isOwned(by: AppSettings.manualOwner) }
    // Only the holder of the lock may drive a simulator; everyone else watches.
    var viewOnly: Bool { !lockedByMe }
    var lockStatus: String {
        if lockedByMe { return "Locked by you" }
        if let owner { return "\(owner) - view only" }
        return "Available - lock to use"
    }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func instructions(for device: SimulatorDevice) -> String {
    """
    Use simulator \(device.name) (\(device.udid)) for this task.
    \(device.description.isEmpty ? "No additional simulator instructions." : device.description)

    Choose a unique agent:<purpose> owner for this task and keep it stable.
    Claim this exact device; do not substitute another simulator if unavailable:
    simutex claim \(shellQuote(device.udid)) --owner "$SIMUTEX_AGENT"
    Use only the returned UDID for simulator commands. Check ownership before use.
    Release when finished:
    simutex release \(shellQuote(device.udid)) --owner "$SIMUTEX_AGENT"
    If claim fails after setup, inspect simutex status before cleanup: its lock may be retained.
    """
}

enum LayoutMode: String, CaseIterable {
    case auto = "Auto Layout"
    case manual = "Manual Layout"
}

struct AppSettings {
    static let defaults = UserDefaults.standard
    static var manualOwner: String { "manual:" + NSUserName() }
    static var developerDirectory: String {
        if let value = defaults.string(forKey: "developerDirectory"), !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !value.isEmpty { return value }
        for path in ["/Applications/Xcode.app/Contents/Developer", "/Applications/Xcode-beta.app/Contents/Developer"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/Library/Developer/CommandLineTools"
    }
    static var layoutMode: LayoutMode {
        get { defaults.string(forKey: "layoutMode").flatMap(LayoutMode.init(rawValue:)) ?? .manual }
        set { defaults.set(newValue.rawValue, forKey: "layoutMode") }
    }
    static var pinnedSimulators: [String] {
        get { defaults.stringArray(forKey: "pinnedSimulators") ?? [] }
        set { defaults.set(newValue, forKey: "pinnedSimulators") }
    }
    // Preserve manual membership independently of automatic layout and pins.
    static var workspace: [String] {
        get { defaults.stringArray(forKey: "workspace") ?? [] }
        set { defaults.set(newValue, forKey: "workspace") }
    }
    static func lockPath(_ udid: String) -> String {
        let env = environment
        let directory = env["SIMUTEX_STATE_DIR"] ?? ((env["TMPDIR"] ?? "/tmp") as NSString).appendingPathComponent("simutex")
        return (directory as NSString).appendingPathComponent(udid + ".lock")
    }
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DEVELOPER_DIR"] = developerDirectory
        for (key, name) in [("statePath", "SIMUTEX_STATE_DIR"), ("metadataPath", "SIMUTEX_METADATA_PATH"), ("hooksPath", "SIMUTEX_HOOKS")] {
            if let value = defaults.string(forKey: key), !value.isEmpty { env[name] = value }
        }
        return env
    }
}

final class CLIClient {
    var onInventory: (([SimulatorDevice]) -> Void)?
    var onError: ((String) -> Void)?
    private var watcher: Process?
    private var generation = 0
    private var receivedSnapshot = false
    var binary: URL { Bundle.main.resourceURL!.appendingPathComponent("simutex") }

    func run(_ arguments: [String], completion: @escaping (Result<String, Error>) -> Void) {
        execute(binary, arguments, environment: AppSettings.environment, completion: completion)
    }
    func simctl(_ arguments: [String], input: Data? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        execute(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl"] + arguments, environment: AppSettings.environment, input: input, completion: completion)
    }
    private func execute(_ executable: URL, _ arguments: [String], environment: [String: String], input: Data? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(), output = Pipe(), errors = Pipe()
            task.executableURL = executable; task.arguments = arguments; task.environment = environment
            task.standardOutput = output; task.standardError = errors
            let inputPipe = input == nil ? nil : Pipe()
            task.standardInput = inputPipe ?? FileHandle.nullDevice
            do {
                try task.run()
                let group = DispatchGroup()
                let errorBox = DataBox()
                group.enter()
                DispatchQueue.global().async { errorBox.value = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                if let input, let inputPipe { inputPipe.fileHandleForWriting.write(input); try? inputPipe.fileHandleForWriting.close() }
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit(); group.wait()
                let result: Result<String, Error> = task.terminationStatus == 0 ? .success(String(decoding: bytes, as: UTF8.self)) : .failure(NSError(domain: "simutex.cli", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errorBox.value, as: UTF8.self)]))
                DispatchQueue.main.async { completion(result) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func startWatching() {
        stopWatching()
        let current = generation
        receivedSnapshot = false
        let task = Process(), output = Pipe(), errors = Pipe()
        task.executableURL = binary; task.arguments = ["watch", "--json"]; task.environment = AppSettings.environment
        task.standardOutput = output; task.standardError = errors; task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { onError?(error.localizedDescription); return }
        watcher = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak task] in
            guard let self, self.generation == current, !self.receivedSnapshot else { return }
            self.onError?("The simulator service is not responding. Retrying…")
            if task?.isRunning == true { task?.terminate() }
            self.startWatching()
        }
        let errorBox = DataBox()
        DispatchQueue.global().async { errorBox.value = errors.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pending = Data()
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                pending.append(bytes)
                if pending.count > 16 * 1024 * 1024 { task.terminate(); break }
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end]); pending.removeSubrange(...end)
                    do {
                        let inventory = try JSONDecoder().decode(Inventory.self, from: line)
                        DispatchQueue.main.async { guard let self, self.generation == current else { return }; self.receivedSnapshot = true; self.onInventory?(inventory.devices) }
                    } catch { DispatchQueue.main.async { guard let self, self.generation == current else { return }; self.onError?("Invalid inventory: \(error.localizedDescription)") } }
                }
            }
            task.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.onError?("Simulator inventory disconnected. Retrying… " + String(decoding: errorBox.value.suffix(1500), as: UTF8.self))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in guard let self, self.generation == current else { return }; self.startWatching() }
            }
        }
    }
    func stopWatching() { generation += 1; if watcher?.isRunning == true { watcher?.terminate() }; watcher = nil }
}
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { get { lock.lock(); defer { lock.unlock() }; return data } set { lock.lock(); defer { lock.unlock() }; data = newValue } }
}

struct WorkspaceSelection {
    static func members(mode: LayoutMode, manual: [String], pinned: [String], available: [SimulatorDevice]) -> [SimulatorDevice] {
        if mode == .manual { return resolved(manual, available: available) }
        let pins = Set(pinned)
        return available.filter { $0.isLocked || pins.contains($0.udid) }.sorted { $0.udid < $1.udid }
    }

    static func adding(_ udid: String, to current: [String]) -> [String] {
        current.contains(udid) ? current : current + [udid]
    }
    static func removing(_ udid: String, from current: [String]) -> [String] {
        current.filter { $0 != udid }
    }
    // Preserve the user's ordering; inventory order is not stable across refreshes,
    // and drop members that have disappeared from the inventory.
    static func resolved(_ current: [String], available: [SimulatorDevice]) -> [SimulatorDevice] {
        current.compactMap { udid in available.first { $0.udid == udid } }
    }
}

struct WorkspaceLayout {
    static func frames(aspects: [CGFloat], in bounds: CGRect) -> [CGRect] {
        guard !aspects.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        var columns = 1, best: CGFloat = -1
        for candidate in 1...aspects.count {
            let rows = Int(ceil(Double(aspects.count) / Double(candidate)))
            let width = max(0, (bounds.width - CGFloat(candidate-1)*20) / CGFloat(candidate))
            let height = max(0, (bounds.height - CGFloat(rows-1)*16) / CGFloat(rows))
            let score = aspects.reduce(CGFloat(0)) { total, aspect in
                let screenWidth = min(max(0,width-8), max(0,height-96)*aspect)
                return total + screenWidth*screenWidth/aspect
            }
            if score > best { best = score; columns = candidate }
        }
        let rows = Int(ceil(Double(aspects.count) / Double(columns)))
        let cellWidth = max(0,(bounds.width-CGFloat(columns-1)*20)/CGFloat(columns))
        let cellHeight = max(0,(bounds.height-CGFloat(rows-1)*16)/CGFloat(rows))
        return aspects.enumerated().map { index, aspect in
            let width = min(cellWidth,max(0,cellHeight-96)*aspect+8)
            let height = min(cellHeight, max(0,width-8)/aspect+96)
            return CGRect(x: bounds.minX+CGFloat(index%columns)*(cellWidth+20)+(cellWidth-width)/2,
                          y: bounds.maxY-CGFloat(index/columns+1)*(cellHeight+16)+16+(cellHeight-height)/2,
                          width: width, height: height)
        }
    }
}
