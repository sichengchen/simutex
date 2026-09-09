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
        print("App models: layout, inventory, and agent instructions passed")
    }
}
