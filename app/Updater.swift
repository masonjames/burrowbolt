import AppKit
import Sparkle

/// Sparkle's standard consent and installation UI; local unsigned builds do not poll a feed.
@MainActor final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController!
    var cleanupActive = false { didSet { resumeWhenIdle() } }
    var cleanupBatchActive = false { didSet { resumeWhenIdle() } }
    private var busy: Bool { cleanupActive || cleanupBatchActive }
    private func resumeWhenIdle() {
        if !busy, let resume = deferredInstall {
            deferredInstall = nil
            resume()
        }
    }
    private var deferredInstall: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil && Bundle.main.object(forInfoDictionaryKey: "BurrowBoltDevelopmentBuild") as? Bool == false,
            updaterDelegate: self, userDriverDelegate: nil)
    }

    func check() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil && Bundle.main.object(forInfoDictionaryKey: "BurrowBoltDevelopmentBuild") as? Bool == false else {
            let alert = NSAlert()
            alert.messageText = "Development build"
            alert.informativeText = "Automatic updates become available in signed BurrowBolt releases."
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if busy {
            throw NSError(domain: "BurrowBolt", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finish or cancel cleanup before checking for updates."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        deferredInstall = installHandler
        return true
    }
}
