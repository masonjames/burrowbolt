import AppKit
import Observation
import OSLog

@MainActor final class CleanupWorker {
    private var process: Process?
    private var input: FileHandle?
    private var session = UUID()
    private var nextID = 0
    private var replies: [Int: (records: [Data], bytes: Int, continuation: CheckedContinuation<[Data], Error>)] = [:]
    private let writes = DispatchQueue(label: "burrowbolt.worker.input")
    private let executableURL: URL?
    private static let log = Logger(subsystem: "com.masonjames.burrowbolt", category: "worker")

    init(executableURL: URL? = nil) { self.executableURL = executableURL }

    func request(_ message: [String: Any]) async throws -> [[String: Any]] {
        if process == nil { try launch() }
        nextID += 1
        let id = nextID, current = session
        var message = message
        message["version"] = 1
        message["id"] = id
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        guard data.count <= WorkerRecords.limit, let input else { throw failure("Worker request is too large") }
        let payload = data
        let records: [Data] = try await withCheckedThrowingContinuation { continuation in
            replies[id] = ([], 0, continuation)
            writes.async { [weak self] in
                do { try input.write(contentsOf: payload) }
                catch {
                    DispatchQueue.main.async {
                        self?.failAll("Worker input closed; rescan before trying again", session: current)
                    }
                }
            }
        }
        return records.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func cancel() {
        guard process != nil else { return }
        Task { _ = try? await request(["op": "cancel"]) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BurrowBolt", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func launch() throws {
        guard let url = executableURL ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("burrowbolt-worker") else {
            throw failure("Bundled worker is missing")
        }
        let process = Process(), stdout = Pipe(), stdin = Pipe()
        process.executableURL = url
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        session = UUID()
        let current = session, output = stdout.fileHandleForReading
        Self.log.info("Worker started")
        // Drain stdout before reporting exit. A termination handler can otherwise
        // discard the final successful Trash receipts still waiting in the pipe.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var decoder = WorkerRecords()
            var failure = "Cleanup worker stopped; rescan before trying again"
            defer {
                try? output.close()
                let message = failure
                DispatchQueue.main.async { [weak self] in self?.failAll(message, session: current) }
            }
            do {
                // FileHandle.read(upToCount:) can fill the requested length on
                // pipes. A persistent worker needs one read(2) per available chunk.
                let capacity = 64 * 1024
                var bytes = [UInt8](repeating: 0, count: capacity)
                while true {
                    let count = Darwin.read(output.fileDescriptor, &bytes, capacity)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw CocoaError(.fileReadUnknown)
                    }
                    if count == 0 { break }
                    let records = try decoder.feed(Data(bytes.prefix(count)))
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.session == current else { return }
                        for record in records { self.receive(record) }
                    }
                }
                try decoder.finish()
            } catch {
                failure = "Cleanup worker returned incomplete or oversized output; rescan before trying again"
            }
        }
    }

    private func receive(_ data: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["version"] as? Int == 1, let id = record["id"] as? Int,
              let event = record["event"] as? String else {
            failAll("Cleanup worker returned an invalid response; rescan before trying again", session: session)
            return
        }
        guard var reply = replies.removeValue(forKey: id) else { return }
        if event == "error" {
            resolve(reply, error: data)
        } else if event == "done" {
            reply.continuation.resume(returning: reply.records)
        } else if reply.bytes + data.count > 64 * 1024 * 1024 {
            replies[id] = reply
            failAll("Cleanup worker response exceeded its limit; rescan before trying again", session: session)
        } else {
            reply.records.append(data)
            reply.bytes += data.count
            replies[id] = reply
        }
    }

    private func resolve(_ reply: (records: [Data], bytes: Int, continuation: CheckedContinuation<[Data], Error>), error: Data) {
        let hasResults = reply.records.contains { data in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["event"] as? String == "result"
        }
        if hasResults {
            reply.continuation.resume(returning: reply.records + [error])
        } else {
            let record = try? JSONSerialization.jsonObject(with: error) as? [String: Any]
            let message = (record?["body"] as? [String: Any])?["message"] as? String ?? "Worker refused the request"
            reply.continuation.resume(throwing: failure(message))
        }
    }

    private func failAll(_ message: String, session current: UUID) {
        guard session == current else { return }
        // EOF cancels the Rust worker's active probe and lets it reap its children.
        try? input?.close()
        process = nil
        input = nil
        session = UUID()
        let pending = replies
        replies = [:]
        Self.log.error("Worker connection closed; pending requests: \(pending.count)")
        for (id, reply) in pending {
            let record: [String: Any] = ["version": 1, "id": id, "event": "error", "body": ["message": message]]
            resolve(reply, error: try! JSONSerialization.data(withJSONObject: record))
        }
    }
}

/// Used on one reader queue. Bound incomplete records as well as complete lines.
nonisolated struct WorkerRecords {
    static let limit = 8 * 1024 * 1024
    private var buffer = Data()
    enum Failure: Error { case oversized, incomplete }

    mutating func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var records: [Data] = []
        var start = buffer.startIndex
        while let end = buffer[start...].firstIndex(of: 10) {
            guard end - start <= Self.limit else { throw Failure.oversized }
            records.append(Data(buffer[start..<end]))
            start = buffer.index(after: end)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        guard buffer.count <= Self.limit else { throw Failure.oversized }
        return records
    }

    func finish() throws {
        guard buffer.isEmpty else { throw Failure.incomplete }
    }
}

/// All user-facing cleanup routes share this serialized execution boundary.
@Observable @MainActor final class CleanupCoordinator {
    static let shared = CleanupCoordinator()
    private let worker = CleanupWorker()
    private(set) var running = false
    private var generation = ""
    private var items: [String: CleanupItem] = [:]
    private var receipts: [URL: String] = [:]
    var exclusions: [String] {
        get { UserDefaults.standard.stringArray(forKey: "cleanup.exclusions") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.exclusions") }
    }

    func cancel() { worker.cancel() }
    func invalidateScan() { generation = ""; items = [:]; worker.cancel() }
    func discover(_ found: [CleanupItem], tree: Tree) async throws -> [CleanupItem] {
        guard !running else { throw error("Cleanup is active") }
        generation = UUID().uuidString
        let current = generation
        var byNode = Dictionary(uniqueKeysWithValues: found.map { (String($0.node),$0) })
        // Bound individual messages without dropping findings on very large inventories.
        let batches = max(1,(found.count + 999)/1000)
        for batch in 0..<batches {
            guard generation == current, !Task.isCancelled else { throw error("Scan was replaced") }
            let start = batch*1000, end = min(found.count,start+1000)
            let result = try await worker.request(["op":batch == 0 ? "discover" : "discoverMore", "generation":current,
                "root":tree.path(0), "exclusions":exclusions,
                "items":found[start..<end].map { ["candidateID":String($0.node),"path":$0.path,"category":$0.category,
                    "bytes":$0.bytes,"complete":$0.complete] as [String: Any] }])
            guard generation == current else { throw error("Scan was replaced") }
            for record in result {
                guard let body = record["body"] as? [String: Any], let key = body["candidateID"] as? String,
                      var item = byNode[key] else { continue }
                item.generation = current
                item.blockingReason = body["blockingReason"] as? String
                item.canReview = body["action"] as? String == "review"
                byNode[key] = item
            }
        }
        let resolved = found.compactMap { byNode[String($0.node)] }
        items = [:]
        for item in resolved where items[item.path]?.canReview != true || item.canReview { items[item.path] = item }
        return resolved
    }

    func inspectArchive(_ original: CleanupItem) async throws -> CleanupItem {
        let current = generation
        let records = try await worker.request(["op":"inspectArchive","generation":current,"candidateID":String(original.node)])
        guard current == generation, !Task.isCancelled else { throw error("Discovery was replaced") }
        var item = original
        for record in records {
            guard let body = record["body"] as? [String:Any] else { continue }
            item.canReview = body["action"] as? String == "review"
            item.blockingReason = body["blockingReason"] as? String
        }
        items[item.path] = item
        return item
    }

    func enrich(_ family: String, tree: Tree) async throws -> [CleanupItem] {
        let current = generation
        let records = try await worker.request(["op":"enrich","generation":current,"family":family])
        guard current == generation, !Task.isCancelled else { throw error("Discovery was replaced") }
        var additions: [CleanupItem] = []
        for record in records {
            guard let body = record["body"] as? [String: Any], let path = body["path"] as? String,
                  let node = tree.node(at:path) else { continue }
            var item = CleanupItem(node:node,path:path,display:tree.displayPath(node),
                kind:body["description"] as? String ?? family,bytes:tree.alloc[node],
                category:"family:" + family,complete:tree.complete[node],generation:current)
            item.blockingReason = body["action"] as? String == "review" ? "Checking scan coverage" : "Informational; this rule does not expose a supported selective action"
            item.canReview = body["action"] as? String == "review"
            additions.append(item)
        }
        let validated = try await worker.request(["op":"measure","generation":current,
            "items":additions.filter(\.canReview).map { ["candidateID":String($0.node),"path":$0.path,"category":$0.category,"complete":$0.complete] as [String: Any] }])
        guard current == generation, !Task.isCancelled else { throw error("Discovery was replaced") }
        let allowed = Set(validated.compactMap { ($0["body"] as? [String: Any])?["candidateID"] as? String })
        for index in additions.indices {
            additions[index].canReview = allowed.contains(String(additions[index].node))
            if additions[index].canReview { additions[index].blockingReason = nil }
            let item = additions[index]
            if items[item.path]?.canReview != true || item.canReview { items[item.path] = item }
        }
        return additions
    }

    func candidates(for paths: [String]) -> [CleanupItem]? {
        let found = paths.compactMap { path in
            items[path] ?? items["/System/Volumes/Data" + path]
        }
        return found.count == paths.count && found.allSatisfy(\.canReview) ? found : nil
    }

    func trash(_ selected: [CleanupItem]) async -> (moved: [URL], bytes: UInt64, error: String?) {
        guard !running else { return ([], 0, "Another cleanup is active") }
        guard !selected.isEmpty, selected.allSatisfy({ $0.generation == generation && $0.canReview }) else {
            return ([], 0, "Selection is unavailable or belongs to an earlier scan")
        }
        running = true; AppUpdater.shared.cleanupActive = true
        defer { running = false; AppUpdater.shared.cleanupActive = false }
        let ids = selected.map { String($0.node) }
        do {
            // Stop enrichment promptly; candidate identities remain bound to this scan.
            _ = try await worker.request(["op":"cancel"])
            let records = try await worker.request(["op":"plan","generation":generation,"candidateIDs":ids])
            guard let plan = records.first(where: { $0["event"] as? String == "plan" })?["body"] as? [String: Any],
                  let token = plan["token"] as? String else { throw error("Worker did not validate a plan") }
            let result = try await worker.request(["op":"apply","generation":generation,"token":token,"candidateIDs":ids])
            var moved: [URL] = [], failures: [String] = []
            var movedBytes: UInt64 = 0
            let sizes = Dictionary(uniqueKeysWithValues: selected.map { (String($0.node),$0.bytes) })
            for record in result {
                guard let body = record["body"] as? [String: Any] else { continue }
                if body["status"] as? String == "trashed", let path = body["trashPath"] as? String {
                    let url = URL(fileURLWithPath: path)
                    moved.append(url)
                    if let id = body["candidateID"] as? String { movedBytes += sizes[id] ?? 0 }
                    if let receipt = body["receipt"] as? String { receipts[url] = receipt }
                } else { failures.append(body["error"] as? String ?? body["message"] as? String ?? "Cleanup was refused") }
            }
            do { try appendHistory(result) } catch { failures.append("Items moved, but history could not be saved: \(error.localizedDescription)") }
            return (moved, movedBytes, failures.isEmpty ? nil : failures.joined(separator:"\n"))
        } catch { return ([], 0, error.localizedDescription) }
    }
    func removeTrashed(_ urls: [URL]) async -> String? {
        guard !running else { return "Another cleanup is active" }
        let ids = urls.compactMap { receipts[$0] }
        guard ids.count == urls.count else { return "Missing Trash receipt; use Finder to review this item" }
        running = true; AppUpdater.shared.cleanupActive = true
        defer { running = false; AppUpdater.shared.cleanupActive = false }
        do {
            _ = try await worker.request(["op":"cancel"])
            let records = try await worker.request(["op":"empty","receipts":ids,"confirmedPermanentRemoval":true])
            for url in urls { receipts[url] = nil }
            try appendHistory(records)
            let errors = records.compactMap { record -> String? in
                let body = record["body"] as? [String: Any]
                return body?["error"] as? String ?? body?["message"] as? String
            }
            return errors.isEmpty ? nil : errors.joined(separator:"\n")
        } catch { return error.localizedDescription }
    }
    func exclude(_ path: String) { if !running && !exclusions.contains(path) { exclusions = exclusions + [path] } }
    private func error(_ text: String) -> NSError {
        NSError(domain:"BurrowBolt",code:1,userInfo:[NSLocalizedDescriptionKey:text])
    }
    private func appendHistory(_ records: [[String: Any]]) throws {
        let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BurrowBolt")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url = folder.appendingPathComponent("cleanup-history.ndjson")
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw error("Could not open cleanup history safely") }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else { throw error("Cleanup history is not an owned regular file") }
        guard fchmod(descriptor, 0o600) == 0 else { throw error("Could not protect cleanup history permissions") }
        for record in records {
            var row = record; row["time"] = ISO8601DateFormatter().string(from:Date())
            var data = try JSONSerialization.data(withJSONObject:row); data.append(10)
            try handle.write(contentsOf:data)
        }
    }
}
