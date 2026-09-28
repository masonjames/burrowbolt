import AppKit
import SwiftUI
import Foundation
import Observation

/// Zero-copy view over the Rust engine's flat tree arrays.
/// Read-only after init, so sharing it across threads is safe.
nonisolated final class Tree: @unchecked Sendable {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    let alloc: UnsafePointer<UInt64>
    let logical: UnsafePointer<UInt64>
    let nFiles: UnsafePointer<UInt32>
    let complete: UnsafePointer<Bool>
    let flags: UnsafePointer<UInt8>
    let childOff: UnsafePointer<UInt32>
    let childArr: UnsafePointer<UInt32>
    let nameOff: UnsafePointer<UInt32>
    let nameBlob: UnsafePointer<UInt8>
    let cleanupCount: Int
    let cleanupNodes: UnsafePointer<UInt32>
    let errors: UInt64

    init?(handle: OpaquePointer) {
        let n = bz_take_tree(handle)
        guard n > 0,
              let parents = bz_parents(handle),
              let alloc = bz_alloc(handle),
              let logical = bz_logical(handle),
              let nFiles = bz_nfiles(handle),
              let flags = bz_flags(handle),
              let complete = bz_complete(handle),
              let childOff = bz_child_off(handle),
              let childArr = bz_children(handle),
              let nameOff = bz_name_off(handle),
              let nameBlob = bz_name_blob(handle),
              let cleanupNodes = bz_cleanup_nodes(handle)
        else { return nil }
        self.handle = handle
        self.count = Int(n)
        self.parents = parents
        self.alloc = alloc
        self.logical = logical
        self.nFiles = nFiles
        self.flags = flags
        self.complete = complete
        self.childOff = childOff
        self.childArr = childArr
        self.nameOff = nameOff
        self.nameBlob = nameBlob
        self.cleanupCount = Int(bz_cleanup_count(handle))
        self.cleanupNodes = cleanupNodes
        self.errors = bz_errors(handle)
    }

    deinit { bz_free(handle) }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    func cleanupDescription(_ index: Int) -> String {
        guard let label = bz_cleanup_description(handle, UInt64(index)) else { return "" }
        return String(cString: label)
    }

    func name(_ i: Int) -> String {
        let start = Int(nameOff[i])
        let end = Int(nameOff[i + 1])
        let buf = UnsafeBufferPointer(start: nameBlob + start, count: end - start)
        return String(decoding: buf, as: UTF8.self)
    }

    /// A lossy display name must never address a different file for cleanup.
    func hasExactPath(_ i: Int) -> Bool {
        var node = i
        while true {
            let start = Int(nameOff[node]), end = Int(nameOff[node+1])
            if String(bytes:UnsafeBufferPointer(start:nameBlob+start,count:end-start),encoding:.utf8) == nil { return false }
            if node == 0 { return true }
            node = Int(parents[node])
        }
    }

    func children(_ i: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(childOff[i])
        let end = Int(childOff[i + 1])
        return UnsafeBufferPointer(start: childArr + start, count: end - start)
    }

    /// Human-facing path: the Data-volume firmlink prefix reads as "/".
    func displayPath(_ i: Int) -> String {
        let p = path(i)
        let prefix = "/System/Volumes/Data"
        if p.hasPrefix(prefix) {
            let rest = String(p.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return p
    }

    /// Full path: root's name is the scanned path itself.
    func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(name(cur))
            cur = Int(parents[cur])
            if cur == Int(UInt32.max) { break }
        }
        var p = name(0)
        if p.hasSuffix("/") { p.removeLast() }
        for part in parts.reversed() { p += "/" + part }
        return p
    }

    /// Chain of ancestors from root to node (inclusive), for breadcrumbs.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [i]
        var cur = i
        while cur != 0 && cur != Int(UInt32.max) {
            cur = Int(parents[cur])
            chain.append(cur)
        }
        return chain.reversed()
    }

    /// What a map draws for `node`: itself, or when it has no shape of its
    /// own (merged into an "A ▸ B" box, too deep for the rings) the nearest
    /// drawn folder that is mostly it. Nil when only a much larger folder is.
    func drawn(_ node: Int, isDrawn: (Int) -> Bool) -> Int? {
        var cur = node
        while !isDrawn(cur) {
            let parent = parents[cur]
            guard parent != UInt32.max, alloc[Int(parent)] <= 2 * alloc[node] else { return nil }
            cur = Int(parent)
        }
        return cur
    }
}

enum FDA {
    /// FDA-protected paths deny silently (no dialog), so probing is safe.
    static func isActive() -> Bool {
        let home = NSHomeDirectory()
        for p in ["\(home)/Library/Messages", "\(home)/Library/Mail", "\(home)/Library/Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

/// How the scan is drawn: WizTree-style boxes or DaisyDisk-style rings.
enum MapStyle: String {
    case treemap, rings
}

@Observable
@MainActor
final class ScanModel {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var bytes: UInt64 = 0
    var scanning = false
    var elapsed: Double = 0
    var tree: Tree?
    var scanRoot: String = {
        // `BurrowBolt /some/path` scans that path on launch (also handy for QA).
        if CommandLine.arguments.count > 1 {
            var isDir: ObjCBool = false
            let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    /// Coding agents found on this Mac (Claude Code, Codex) and the user's PATH.
    var agentEnv = AgentEnvironment()
    /// The agent cleanup on screen, if any.
    var agentRun: AgentRun?
    /// An agent being installed or signed in from the panel.
    var agentSetup: AgentSetup?
    /// The first scan after launch hands itself to the agent once.
    private var autoStarted = false
    private var discoveryReady = false
    private var renderedTree: ObjectIdentifier?

    /// The agent to use: the one picked last, else Claude Code, else Codex.
    var preferredAgent: InstalledAgent? {
        let ready = agentEnv.ready
        let picked = UserDefaults.standard.string(forKey: "bz.agent")
        return ready.first { $0.kind.rawValue == picked } ?? ready.first { $0.kind == .claude } ?? ready.first
    }

    func startAgent(_ agent: InstalledAgent) {
        guard let tree, !scanning, !cleanupTrash.running else { return }
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.agent")
        agentRun?.cancel()
        let run = AgentRun(agent: agent, env: agentEnv, tree: tree, scanRoot: scanRoot, known: cleanup) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// After the launch scan: start the agent straight away when one is ready,
    /// else open the panel on the setup offer.
    func autoStartIfReady() {
        guard ProcessInfo.processInfo.environment["BURROWBOLT_QA_NO_AGENT"] != "1", !autoStarted, discoveryReady, agentEnv.loaded, tree != nil, !scanning,
              !cleanupTrash.running, agentRun == nil else { return }
        autoStarted = true
        if let agent = preferredAgent {
            startAgent(agent)
        } else {
            panelRequests += 1
            // QA only: BZ_QA_SETUP=claude|codex presses the setup button.
            if let kind = ProcessInfo.processInfo.environment["BZ_QA_SETUP"].flatMap(AgentKind.init) { setUp(kind) }
        }
    }

    /// Bumped to ask the window to open the Clean Up panel.
    var panelRequests = 0

    func setUp(_ kind: AgentKind) {
        agentSetup?.cancel()
        let installed = agentEnv.agents.first { $0.kind == kind }
        agentSetup = AgentSetup(kind: kind, installed: installed, envPath: agentEnv.path) { [weak self] env in
            guard let self else { return }
            agentEnv = env
            agentSetup = nil
            if let agent = env.ready.first(where: { $0.kind == kind }) { startAgent(agent) }
        }
    }
    /// A tree has been shown at least once, so the views exist (see ContentView).
    var hasShownTree = false
    var viewRoot: Int = 0 {
        didSet {
            // A selection outside the folder on screen would read as over 100%.
            if let sel = selection, let tree, !tree.ancestry(sel).contains(viewRoot) { selection = nil }
        }
    }
    var selection: Int? = nil

    /// Select a node from a list, zooming out first if it is outside the
    /// folder on screen (it would have nothing to outline).
    func reveal(_ node: Int) {
        if let tree, !tree.ancestry(node).contains(viewRoot) { viewRoot = 0 }
        selection = node
    }
    var hovered: Int? = nil
    var freeBytes: UInt64 = 0
    /// Rebuildable folders worth deleting, largest first.
    var cleanup: [CleanupItem] = []
    var localSnapshotCount: Int?
    var enrichmentStatus = ""
    var enrichmentFailures: [String] = []
    var searchText = "" { didSet { updateSearch() } }
    var showLargest = false
    var searchResults: [Int] = []
    var largestFiles: [Int] = []
    var searchLimited = false
    private var searchTask: Task<Void, Never>?

    func updateSearch() {
        searchTask?.cancel()
        guard let tree, !searchText.isEmpty else { searchResults = []; return }
        let query = searchText
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let job = Task.detached(priority: .utility) { InventoryBrowse.search(tree, query: query) }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled, self.tree === tree else { return }
            searchResults = result; searchLimited = result.count == 1000
        }
    }
    let cleanupTrash = CleanupTrashBatch()
    /// Volume-used minus what the scan could see: root-only territory.
    var unscannedBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }
    var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "bz.mapStyle") ?? "") ?? .treemap {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "bz.mapStyle") }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var discoveryTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var volumeTask: Task<VolumeSpace, Never>?

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running || CleanupCoordinator.shared.running || agentRun?.phase == .trashing || agentRun?.phase == .deleting { return }
        discoveryReady = false
        renderedTree = nil
        discoveryTask?.cancel()
        CleanupCoordinator.shared.invalidateScan()
        agentRun?.cancel(); agentRun = nil
        if let path { scanRoot = path }
        scanGeneration = UUID()
        freeBytes = 0
        unscannedBytes = 0
        tree = nil
        cleanup = []
        searchTask?.cancel(); searchResults = []; largestFiles = []
        enrichmentStatus = ""; enrichmentFailures = []; localSnapshotCount = nil
        viewRoot = 0
        selection = nil
        hovered = nil
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        lastPollAt = nil; maxPollGap = 0
        scanning = true
        startedAt = Date()
        endScanActivity()
        // Keep the process out of App Nap / timer coalescing through first-map delivery.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disk scan"
        )
        // Foundation may ask a disk-management service about purgeable space.
        // Read it alongside the scan without delaying publication of the tree, so
        // the main thread never waits synchronously on that service.
        let volumePath = scanRoot
        volumeTask = Task.detached(priority: .userInitiated) { VolumeSpace.read(volumePath) }
        // Completion must not wait for the next progress frame. The callback
        // owns this retain until it queues the model back onto the main thread.
        handle = bz_scan_start_notifying(scanRoot, scanCompleted,
            Unmanaged.passRetained(self).toOpaque())

        // 60 Hz: the elapsed time ticks every frame, so the screen keeps
        // moving while the engine assembles the tree after the last file is
        // counted (the counters sit still for that part).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Common modes: keep polling while a control is being clicked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var lastPollAt: Date?
    private var maxPollGap: Double = 0

    fileprivate func poll() {
        guard let handle else {
            // A slow volume-space service must not freeze progress while the
            // already finished tree waits for its matching volume snapshot.
            if scanning { elapsed = -(startedAt?.timeIntervalSinceNow ?? 0) }
            return
        }
        if let last = lastPollAt { maxPollGap = max(maxPollGap, -last.timeIntervalSinceNow) }
        lastPollAt = Date()
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        bz_progress(handle, &f, &d, &b, &done)
        files = f; dirs = d; bytes = b
        elapsed = -(startedAt?.timeIntervalSinceNow ?? 0)
        if done != 0 {
            let doneAt = Date()
            let result = Tree(handle: handle)
            self.handle = nil
            if result == nil { bz_free(handle) }
            let pendingVolume = volumeTask
            volumeTask = nil
            let generation = scanGeneration
            finishScan(result, space: VolumeSpace(free: nil, used: nil), doneAt: doneAt)
            Task {
                let space = await pendingVolume?.value ?? VolumeSpace(free: nil, used: nil)
                guard generation == scanGeneration else { return }
                updateVolumeSpace(space)
            }
        }
    }

    private func finishScan(_ result: Tree?, space: VolumeSpace, doneAt: Date) {
        timer?.invalidate()
        timer = nil
        tree = result
        if tree != nil { hasShownTree = true }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            // Queue latency includes awaiting metadata and UI updates; it is
            // not a measurement of uninterrupted main-thread blocking.
            DispatchQueue.main.async {
                NSLog("BZ hand-off: queued completion %.1f ms after engine done", -doneAt.timeIntervalSinceNow * 1000)
            }
            NSLog("BZ done at %.3f, longest gap between polls %.1f ms", doneAt.timeIntervalSinceReferenceDate, maxPollGap * 1000)
        }
        scanning = false
        updateVolumeSpace(space)
        if result == nil { endScanActivity() }
    }

    private func endScanActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Enrichment and the one automatic AI run start only after a map is ready.
    func didRender(_ tree: Tree) {
        guard self.tree === tree, renderedTree != ObjectIdentifier(tree) else { return }
        renderedTree = ObjectIdentifier(tree)
        endScanActivity()
            discoveryTask = Task {
                let job = Task.detached(priority: .utility) { DiskInsights.find(in: tree) }
                let found = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                // A rescan may have replaced the tree while discovery ran.
                // Node IDs only belong to the scan that produced them.
                guard self.tree === tree, !Task.isCancelled else { return }
                cleanup = found
                do {
                    let resolved = try await CleanupCoordinator.shared.discover(found, tree: tree)
                    guard self.tree === tree, !Task.isCancelled else { return }
                    cleanup = resolved
                } catch {
                    guard self.tree === tree, !Task.isCancelled else { return }
                    cleanup = found.map { var item = $0; item.blockingReason = error.localizedDescription; return item }
                }
                discoveryReady = true
                autoStartIfReady()
                let largestJob = Task.detached(priority:.utility) { InventoryBrowse.largest(tree) }
                largestFiles = await withTaskCancellationHandler { await largestJob.value } onCancel: { largestJob.cancel() }
                guard self.tree === tree, !Task.isCancelled else { return }
                updateSearch()
                let scanPath = tree.path(0)
                let scansHome = scanPath == "/System/Volumes/Data" || scanPath == "/" || scanPath == NSHomeDirectory() || NSHomeDirectory().hasPrefix(scanPath + "/")
                if scansHome {
                    let snapshotJob = Task.detached(priority:.utility) { DiskInsights.localSnapshots() }
                    let count = await withTaskCancellationHandler { await snapshotJob.value } onCancel: { snapshotJob.cancel() }
                    guard self.tree === tree, !Task.isCancelled else { return }
                    localSnapshotCount = count
                }
                if scansHome, let url = Bundle.main.url(forResource:"families",withExtension:"txt"),
                   let families = try? String(contentsOf:url,encoding:.utf8) {
                    for family in families.split(separator:"\n").map(String.init) {
                        guard self.tree === tree, !Task.isCancelled else { return }
                        while CleanupCoordinator.shared.running {
                            try? await Task.sleep(for:.milliseconds(50))
                            if Task.isCancelled { return }
                        }
                        // Foreground scan cancels the worker's entire current probe group.
                        enrichmentStatus = "Checking " + family.replacingOccurrences(of:"_",with:" ")
                        do {
                            let extra = try await CleanupCoordinator.shared.enrich(family,tree:tree)
                            guard self.tree === tree, !Task.isCancelled else { return }
                            var merged = Dictionary(uniqueKeysWithValues:cleanup.map { ($0.node,$0) })
                            for item in extra where merged[item.node]?.canReview != true || item.canReview { merged[item.node] = item }
                            cleanup = merged.values.sorted { $0.bytes > $1.bytes }
                        } catch {
                            guard self.tree === tree, !Task.isCancelled else { return }
                            enrichmentFailures.append(family + ": " + error.localizedDescription)
                        }
                    }
                }
                let archiveDeadline = ContinuousClock.now.advanced(by:.seconds(20))
                var deferredArchives = 0
                for archive in cleanup.filter({ $0.category == "installer-zip" && $0.complete && !$0.generation.isEmpty }) {
                    guard self.tree === tree, !Task.isCancelled else { return }
                    while CleanupCoordinator.shared.running {
                        try? await Task.sleep(for:.milliseconds(50))
                        if Task.isCancelled { return }
                    }
                    if ContinuousClock.now >= archiveDeadline { deferredArchives += 1; continue }
                    enrichmentStatus = "Inspecting installer archives"
                    if let item = try? await CleanupCoordinator.shared.inspectArchive(archive),
                       self.tree === tree, !Task.isCancelled,
                       let index = cleanup.firstIndex(where: { $0.node == item.node }) { cleanup[index] = item }
                }
                if deferredArchives > 0 { enrichmentFailures.append("\(deferredArchives) archive listings deferred; select an archive to inspect it") }
                enrichmentStatus = enrichmentFailures.isEmpty ? "Checks finished; protected or uncertain targets may be withheld" : "Discovery partial: \(enrichmentFailures.count) probes unavailable"
            }
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
    }

    func inspectArchive(_ archive: CleanupItem) async {
        guard let tree, !scanning, !CleanupCoordinator.shared.running else { return }
        do {
            let checked = try await CleanupCoordinator.shared.inspectArchive(archive)
            guard self.tree === tree, let index = cleanup.firstIndex(where:{ $0.node == archive.node }) else { return }
            cleanup[index] = checked
        } catch {
            guard self.tree === tree, let index = cleanup.firstIndex(where:{ $0.node == archive.node }) else { return }
            cleanup[index].blockingReason = error.localizedDescription
        }
    }

    func cancelScan() {
        if let handle { bz_cancel(handle) }
    }

    private func updateVolumeSpace(_ space: VolumeSpace) {
        freeBytes = space.free ?? 0
        // This also includes unreadable data, snapshots and filesystem accounting.
        unscannedBytes = 0
        if let tree, let used = space.used, used > tree.alloc[0] {
            unscannedBytes = used - tree.alloc[0]
        }
    }
}

// C invokes this on the Rust thread; never inherit MainActor isolation here.
nonisolated private func scanCompleted(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let model = Unmanaged<ScanModel>.fromOpaque(context).takeRetainedValue()
    DispatchQueue.main.async { model.poll() }
}

nonisolated private struct VolumeSpace: Sendable {
    let free: UInt64?
    let used: UInt64?

    static func read(_ path: String) -> VolumeSpace {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return VolumeSpace(
            free: values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            used: path == "/System/Volumes/Data" ? volumeUsedBytes(path) : nil
        )
    }
}

/// Space used by this APFS volume alone, the figure `df` shows. statfs and
/// Foundation's systemSize/systemFreeSize describe the whole container,
/// which also holds the macOS system volume, VM swap and Recovery.
nonisolated func volumeUsedBytes(_ path: String) -> UInt64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var reply = (length: UInt32(0), used: UInt64(0))
    let status = withUnsafeMutableBytes(of: &reply) {
        getattrlist(path, &request, $0.baseAddress, $0.count, 0)
    }
    guard status == 0 else { return nil }
    // Packed buffer: u_int32_t length, then off_t at offset 4 (unaligned).
    return withUnsafeBytes(of: &reply) { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
}

nonisolated enum Fmt {
    static func size(_ b: UInt64) -> String { Int64(b).formatted(.byteCount(style: .file)) }
    static func num(_ n: UInt64) -> String { n.formatted() }
}
