import AppKit
import Foundation

/// Production scan/model/renderer with an offscreen Retina window. No agents,
/// cleanup actions, UI scripting, or published bundle preferences are used.
@main struct FirstMap {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = ScanModel()
        model.showFreeSpace = false
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1024,height:640),styleMask:[.borderless],backing:.buffered,defer:false)
        let view = TreemapNSView(frame:window.contentView!.bounds)
        view.model = model; window.contentView = view
        let started = ProcessInfo.processInfo.systemUptime
        var last = started, longestGap = 0.0
        model.startScan(path:CommandLine.arguments[1])
        while view.bitmap == nil {
            RunLoop.current.run(until:Date().addingTimeInterval(0.001))
            view.relayoutIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            longestGap = max(longestGap,now-last);last=now
            if now-started > 120 { fputs("First map timed out\n",stderr); exit(1) }
        }
        let record: [String:Any] = ["seconds":ProcessInfo.processInfo.systemUptime-started,
            "max_main_loop_gap_ms":longestGap*1000,"nodes":model.tree!.count,
            "bytes":model.tree!.alloc[0],"scale":window.backingScaleFactor]
        print(String(data:try! JSONSerialization.data(withJSONObject:record,options:.sortedKeys),encoding:.utf8)!)
        #if BURROWBOLT_BENCHMARK
        if CommandLine.arguments.contains("--enrich") {
            var frames = 0, maxGap = 0.0, lastRoot = 0
            var previousStatus = ""
            let enrichmentStart = ProcessInfo.processInfo.systemUptime
            var nextNavigation = enrichmentStart
            last = enrichmentStart
            while !model.enrichmentStatus.hasPrefix("Checks finished") && !model.enrichmentStatus.hasPrefix("Discovery partial") {
                RunLoop.current.run(until:Date().addingTimeInterval(0.005))
                if previousStatus != model.enrichmentStatus {
                    previousStatus = model.enrichmentStatus
                    fputs((previousStatus + "\n"),stderr)
                }
                let now = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap,now-last);last=now
                if now >= nextNavigation {
                    let children = Array(model.tree!.children(0)).filter { model.tree!.isDir(Int($0)) }
                    if !children.isEmpty { lastRoot = frames%2==0 ? Int(children[frames/2 % children.count]) : 0 }
                    model.viewRoot = lastRoot; view.relayoutIfNeeded()
                    frames += 1; nextNavigation = now + 0.2
                }
                if now-enrichmentStart > 360 { fputs("Enrichment timed out\n",stderr);exit(1) }
            }
            while view.rendering || view.pendingRender != nil { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
            precondition(view.lastRoot == model.viewRoot)
            for rect in view.rects where rect.node >= 0 {
                precondition(model.tree!.ancestry(rect.node).contains(model.viewRoot),"Obsolete geometry was installed")
            }
            let details:[String:Any] = ["enrichment_seconds":ProcessInfo.processInfo.systemUptime-enrichmentStart,
                "navigation_requests":frames,"max_main_loop_gap_ms":maxGap*1000,
                "findings":model.cleanup.count,"status":model.enrichmentStatus,"unavailable_probes":model.enrichmentFailures]
            print(String(data:try! JSONSerialization.data(withJSONObject:details,options:.sortedKeys),encoding:.utf8)!)
            CleanupCoordinator.shared.cancel()
        }
        #endif
        // Visible-window paint and desktop interaction remain separate acceptance.
        exit(0)
    }
}
