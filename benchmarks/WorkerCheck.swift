import Foundation

@main struct WorkerCheck {
    static func check(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

    @MainActor static func main() async throws {
        var decoder = WorkerRecords()
        check(try decoder.feed(Data("first\npar".utf8)) == [Data("first".utf8)], "Split record lost")
        check(try decoder.feed(Data("tial\n".utf8)) == [Data("partial".utf8)], "Fragment was not reassembled")
        try decoder.finish()
        _ = try decoder.feed(Data("unfinished".utf8))
        do { try decoder.finish(); fatalError("Partial EOF accepted") } catch WorkerRecords.Failure.incomplete {}
        decoder = WorkerRecords()
        do {
            _ = try decoder.feed(Data(repeating: 65, count: WorkerRecords.limit + 1))
            fatalError("Unbounded worker output accepted")
        } catch WorkerRecords.Failure.oversized {}

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burrowbolt-worker-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("fixture-worker")
        func fixture(_ lines: [String]) throws {
            // No filesystem actions: only protocol records, followed by immediate exit.
            let body = "#!/bin/bash\nIFS= read -r request\n" + lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n") + "\n"
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        let receipt = #"{"version":1,"id":1,"event":"result","body":{"status":"trashed","receipt":"fixture"}}"#
        try fixture([receipt, #"{"version":1,"id":1,"event":"done","body":{}}"#])
        let complete = try await CleanupWorker(executableURL: script).request(["op": "fixture"])
        check(complete.count == 1 && complete[0]["event"] as? String == "result", "Process exit lost a completed receipt")
        try fixture([receipt])
        let partial = try await CleanupWorker(executableURL: script).request(["op": "fixture"])
        check(partial.count == 2 && partial[0]["event"] as? String == "result" && partial[1]["event"] as? String == "error", "Partial success lost at EOF")
        try fixture([#"{"version":2,"id":1,"event":"done"}"#])
        do {
            _ = try await CleanupWorker(executableURL: script).request(["op": "fixture"])
            fatalError("Invalid protocol version accepted")
        } catch {
            check(error.localizedDescription.contains("invalid response"), "Wrong protocol failure")
        }
        print("PASS: bounded worker framing, fragmented records, partial EOF, final receipt delivery and protocol validation")
    }
}
