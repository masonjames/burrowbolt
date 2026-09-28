import Foundation
import Sentry

// Isolate SDK checks from scans, workers, the real app's preferences and crash cache.
@MainActor final class CleanupCoordinator {
    static let shared = CleanupCoordinator()
    func updateDiagnostics() {}
}

@main struct DiagnosticsCheck {
    @MainActor static var settled = false
    @MainActor static func settle() {
        settled = false
        DispatchQueue.main.async { settled = true }
        while !settled { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
    }
    @MainActor static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "check"
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain == "com.masonjames.burrowbolt.diagnostics-check")
        if mode == "crash" {
            Diagnostics.setEnabled(true)
            settle()
            SentrySDK.crash() // Separate fixture process only; restart with `send` to deliver.
            return
        }
        if mode == "send" {
            Diagnostics.setEnabled(true)
            Diagnostics.report(.testReport)
            settle()
            SentrySDK.flush(timeout: 10)
            SentrySDK.close()
            print("Synthetic app report flushed")
            return
        }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        Diagnostics.start()
        settle()
        precondition(!Diagnostics.enabled && !SentrySDK.isEnabled)
        let options = Diagnostics.options()
        precondition(!options.sendDefaultPii && !options.enableMemoryIntrospection)
        precondition(!options.enableNetworkTracking && !options.enableFileIOTracing)
        precondition(!options.enableAutoSessionTracking && !options.enableLogs && !options.enableMetrics)
        precondition(!options.enableCaptureFailedRequests && options.maxBreadcrumbs == 0)
        let secret = "/Users/PRIVATE_REPORT_MARKER/secret-file.dmg"
        let source = Event(level: .fatal)
        source.message = SentryMessage(formatted: secret)
        source.extra = ["prompt": secret]; source.tags = ["path": secret]
        source.serverName = secret; source.context = ["custom": ["path": secret]]
        source.releaseName = "burrowbolt@fixture"
        let frame = Frame(); frame.fileName = secret; frame.contextLine = secret
        frame.vars = ["path": secret]; frame.function = "fixtureCrash"
        frame.instructionAddress = "0x1234"
        let exception = Exception(value: secret, type: secret)
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        source.exceptions = [exception]
        precondition(options.beforeSend!(source) == nil, "Opt-out accepted a report")
        let safe = Diagnostics.scrub(source)
        precondition(safe.user?.ipAddress == "0.0.0.0")
        let data = try JSONSerialization.data(withJSONObject: safe.serialize())
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains("PRIVATE_REPORT_MARKER") && !text.contains("secret-file"))
        precondition(text.contains("fixtureCrash") && text.contains("0x1234") && text.contains("burrowbolt@fixture"))
        // Enabling alone must not send sessions, transactions, or logs.
        Diagnostics.setEnabled(true)
        settle()
        precondition(SentrySDK.isEnabled && options.beforeSend!(source) != nil)
        Diagnostics.setEnabled(false)
        settle()
        precondition(!SentrySDK.isEnabled && options.beforeSend!(source) == nil)
        precondition(!FileManager.default.fileExists(atPath: Diagnostics.cache.path))
        UserDefaults.standard.removePersistentDomain(forName: domain)
        print("PASS: opt-out, opt-in, revocation, cache removal and allowlisted native crash payload")
    }
}
