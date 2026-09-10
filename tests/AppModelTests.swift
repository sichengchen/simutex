import Foundation
import CoreGraphics

@main
struct AppModelTests {
    static func main() throws {
        for size in [CGSize(width: 568,height:280), CGSize(width:1148,height:570), CGSize(width:1600,height:900)] {
            for count in 1...8 {
                let bounds=CGRect(origin:.zero,size:size)
                let frames=WorkspaceLayout.frames(aspects:(0..<count).map { $0%3 == 0 ? 0.75 : 0.46 },in:bounds)
                precondition(frames.count == count)
                for (i,frame) in frames.enumerated() {
                    precondition(frame.width > 0 && frame.height > 0)
                    precondition(bounds.insetBy(dx:-0.001,dy:-0.001).contains(frame))
                    for other in frames.dropFirst(i+1) { precondition(!frame.intersects(other)) }
                }
            }
        }
        precondition(WorkspaceLayout.frames(aspects:[],in:.zero).isEmpty)
        let json = #"{"devices":[{"udid":"SIM-1","name":"iPhone","runtime":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","state":"Booted","owner":null,"description":"Checkout only","hooks":{}}]}"#
        let inventory=try JSONDecoder().decode(Inventory.self,from:Data(json.utf8))
        precondition(inventory.devices[0].owner == nil)
        precondition(inventory.devices[0].runtimeLabel == "iOS 27.0")
        let text=instructions(for:inventory.devices[0])
        precondition(text.contains("Checkout only") && text.contains("simutex claim 'SIM-1'"))
        precondition(shellQuote("a'b") == "'a'\\''b'")

        // Main-panel membership: explicit, de-duplicated, order-preserving.
        var selection = [String]()
        selection = WorkspaceSelection.adding("SIM-2", to: selection)
        selection = WorkspaceSelection.adding("SIM-1", to: selection)
        selection = WorkspaceSelection.adding("SIM-2", to: selection)
        precondition(selection == ["SIM-2", "SIM-1"])
        precondition(WorkspaceSelection.removing("SIM-2", from: selection) == ["SIM-1"])
        precondition(WorkspaceSelection.removing("absent", from: selection) == selection)

        func device(_ udid: String, owner: String?) -> SimulatorDevice {
            let json = "{\"udid\":\"\(udid)\",\"name\":\"n\",\"runtime\":\"r\",\"state\":\"Booted\",\"owner\":\(owner.map { "\"\($0)\"" } ?? "null"),\"description\":\"\"}"
            return try! JSONDecoder().decode(SimulatorDevice.self, from: Data(json.utf8))
        }
        let agentOwned = device("SIM-1", owner: "agent:tests")
        let free = device("SIM-2", owner: nil)
        let mine = device("SIM-3", owner: AppSettings.manualOwner)
        // Selection order wins over inventory order, and vanished devices drop out.
        let resolved = WorkspaceSelection.resolved(["SIM-3", "SIM-1", "gone"], available: [free, agentOwned, mine])
        precondition(resolved.map(\.udid) == ["SIM-3", "SIM-1"])
        precondition(WorkspaceSelection.resolved([], available: [free]).isEmpty)

        let stopped = SimulatorDevice(udid: "SIM-4", name: "Stopped", runtime: "r", state: "Shutdown", owner: nil, description: "")
        let all = [free, mine, stopped, agentOwned]
        func members(_ mode: LayoutMode, pins: [String] = [], inventory: [SimulatorDevice] = all) -> [String] {
            WorkspaceSelection.members(mode: mode, manual: ["SIM-2"], pinned: pins, available: inventory).map(\.udid)
        }
        precondition(members(.auto) == ["SIM-1", "SIM-3"])
        precondition(members(.auto, pins: ["SIM-1", "SIM-4", "gone"]) == ["SIM-1", "SIM-3", "SIM-4"])
        precondition(members(.auto, inventory: all.reversed()) == members(.auto))
        precondition(members(.manual, pins: ["SIM-4"]) == ["SIM-2"])
        // A released claim leaves the panel unless pinned, regardless of boot state.
        let released = device("SIM-1", owner: nil)
        precondition(members(.auto, inventory: [released, free]).isEmpty)
        precondition(members(.auto, pins: ["SIM-1"], inventory: [released, free]) == ["SIM-1"])
        precondition(members(.auto, inventory: [SimulatorDevice(udid: "SIM-5", name: "Claimed", runtime: "r", state: "Shutdown", owner: "agent:tests", description: "")]) == ["SIM-5"])
        precondition(members(.auto, pins: ["SIM-4"], inventory: []).isEmpty)

        // Agent-held and unlocked simulators are viewable but not usable.
        precondition(agentOwned.isLocked && agentOwned.viewOnly && !agentOwned.lockedByMe)
        precondition(!free.isLocked && free.viewOnly)
        precondition(mine.lockedByMe && !mine.viewOnly && mine.isLocked)
        precondition(agentOwned.lockStatus.contains("view only"))
        precondition(mine.lockStatus == "Locked by you")
        precondition(free.lockStatus.contains("Available"))
        print("App models: layout, inventory, and agent instructions passed")
    }
}
