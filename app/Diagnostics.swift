import OSLog
import Sentry
import SwiftUI

/// Only bounded operational codes enter remote reports. Files and agent output never do.
enum Diagnostics {
    enum Failure: String { case scanFailed, workerLaunchFailed, workerConnectionLost, testReport }
    nonisolated static let log = Logger(subsystem: "com.masonjames.burrowbolt", category: "app")
    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: "diagnostics.enabled") }
    nonisolated static var cache: URL {
        URL.applicationSupportDirectory.appending(path: "BurrowBolt/Diagnostics/" + (Bundle.main.bundleIdentifier ?? "tests"))
    }
    private static var started = false
    private static var reported: Set<Failure> = []

    static func start() {
        // Sentry requires the main thread. Queue initialization so scanning can
        // start first, and keep reports/consent changes in the same FIFO.
        DispatchQueue.main.async { configure() }
        log.info("App started; crash reporting enabled: \(enabled)")
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "diagnostics.enabled")
        DispatchQueue.main.async { configure() }
        CleanupCoordinator.shared.updateDiagnostics()
        log.info("Crash reporting enabled: \(value)")
    }

    private static func configure() {
        if enabled {
            guard !started else { return }
            do {
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
                SentrySDK.start(options: options())
                started = true
            } catch { log.error("Could not prepare private diagnostics cache") }
        } else {
            if started { SentrySDK.close(); started = false }
            // Also discard reports left by an earlier consented run.
            clearCache()
        }
    }

    nonisolated private static func clearCache() {
        guard FileManager.default.fileExists(atPath: cache.path) else { return }
        do { try FileManager.default.removeItem(at: cache) }
        catch { log.error("Could not remove local diagnostics cache") }
    }

    static func report(_ failure: Failure) {
        log.error("Operational failure: \(failure.rawValue, privacy: .public)")
        guard enabled, failure == .testReport || reported.insert(failure).inserted else { return }
        DispatchQueue.main.async {
            guard enabled, started else { return }
            let event = Event(level: .error)
            event.tags = ["failure": failure.rawValue]
            SentrySDK.capture(event: event)
        }
    }

    nonisolated static func options() -> Options {
        let options = Options()
        options.dsn = Bundle.main.object(forInfoDictionaryKey: "BurrowBoltSentryDSN") as? String
        options.releaseName = Bundle.main.object(forInfoDictionaryKey: "BurrowBoltSentryRelease") as? String
        options.environment = Bundle.main.object(forInfoDictionaryKey: "BurrowBoltDevelopmentBuild") as? Bool == false ? "production" : "development"
        options.cacheDirectoryPath = cache.path
        options.sendDefaultPii = false
        options.enableMemoryIntrospection = false
        options.enableUncaughtNSExceptionReporting = true
        options.enableAutoSessionTracking = false
        options.enableAutoPerformanceTracing = false
        options.enablePersistingTracesWhenCrashing = false
        options.tracesSampleRate = 0
        // AppKit exception reporting needs this; all I/O instrumentation stays off.
        options.enableSwizzling = true
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.enableAutoBreadcrumbTracking = false
        options.maxBreadcrumbs = 0
        options.enableLogs = false
        options.enableMetrics = false
        options.enableAppHangTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableMetricKit = false
        options.sendClientReports = false
        options.maxCacheItems = 10
        options.maxAttachmentSize = 0
        options.shutdownTimeInterval = 0
        options.beforeSend = { event in enabled ? scrub(event) : nil }
        return options
    }

    /// Rebuild from an allowlist so newly added SDK fields are private by default.
    nonisolated static func scrub(_ source: Event) -> Event {
        let event = Event(level: source.level)
        event.eventId = source.eventId
        event.timestamp = source.timestamp
        event.platform = source.platform
        // Absence lets ingestion infer peer-IP geolocation, even with IP scrubbing.
        let user = User(); user.ipAddress = "0.0.0.0"; event.user = user
        event.releaseName = source.releaseName
        event.environment = source.environment
        let failure = source.tags?["failure"].flatMap(Failure.init(rawValue:))
        event.tags = ["component": "app", "failure": failure?.rawValue ?? "nativeCrash"]
        event.message = SentryMessage(formatted: failure?.rawValue ?? "Native app crash")
        event.exceptions = source.exceptions?.map { old in
            let knownTypes: Set<String> = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC",
                "EXC_BREAKPOINT", "EXC_CRASH", "SIGABRT", "SIGBUS", "SIGSEGV", "SIGILL",
                "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException"]
            let type = old.type.flatMap { knownTypes.contains($0) ? $0 : nil } ?? "NativeException"
            let exception = Exception(value: "Exception details withheld", type: type)
            exception.threadId = old.threadId
            exception.stacktrace = stack(old.stacktrace)
            let mechanism = Mechanism(type: "native")
            mechanism.handled = old.mechanism?.handled
            exception.mechanism = mechanism
            return exception
        }
        event.threads = source.threads?.map { old in
            let thread = SentryThread(threadId: old.threadId)
            thread.crashed = old.crashed; thread.current = old.current; thread.isMain = old.isMain
            thread.stacktrace = stack(old.stacktrace)
            return thread
        }
        event.stacktrace = stack(source.stacktrace)
        event.debugMeta = source.debugMeta?.map { old in
            let image = DebugMeta()
            image.debugID = old.debugID; image.type = old.type
            image.imageAddress = old.imageAddress; image.imageSize = old.imageSize
            image.imageVmAddress = old.imageVmAddress
            image.codeFile = old.codeFile.map { URL(fileURLWithPath: $0).lastPathComponent }
            return image
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        event.context = ["os": ["type": "os", "name": "macOS", "version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"],
                         "device": ["type": "device", "arch": "arm64"]]
        return event
    }

    nonisolated private static func stack(_ old: SentryStacktrace?) -> SentryStacktrace? {
        guard let old else { return nil }
        return SentryStacktrace(frames: old.frames.map { old in
            let frame = Frame()
            frame.instructionAddress = old.instructionAddress; frame.imageAddress = old.imageAddress
            frame.symbolAddress = old.symbolAddress; frame.function = old.function
            frame.inApp = old.inApp; frame.lineNumber = old.lineNumber; frame.columnNumber = old.columnNumber
            return frame
        }, registers: [:])
    }
}

struct DiagnosticsSettings: View {
    @AppStorage("diagnostics.enabled") private var enabled = false
    @State private var sentTest = false
    var body: some View {
        Form {
            Toggle("Share crash and error reports with Sentry", isOn: Binding(
                get: { enabled }, set: { Diagnostics.setEnabled($0); sentTest = false }))
            Text("Off by default. Reports include code stacks, app build and macOS version. Scanned paths, file names, file contents, cleanup history and AI prompts are excluded. Routine logs stay on your Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Button(sentTest ? "Test report queued" : "Send a test report") {
                Diagnostics.report(.testReport); sentTest = true
            }.disabled(!enabled || sentTest)
        }.padding(24).frame(width: 480)
    }
}
