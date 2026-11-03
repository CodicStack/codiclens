import Foundation
import Testing

/// The app is the test host, so `Bundle.main` is the built Codiclens bundle and
/// its Info.plist is what the About box and Finder show.
struct BundleInfoTests {

    @Test func theAboutBoxCarriesTheCopyrightAndLicense() {
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        #expect(copyright == "Copyright © 2026 Emil Lykke Grann. Apache License 2.0.")
    }

    /// Sparkle reads these at launch. A wrong one is not a crash but a
    /// silent hole: an unsigned feed accepted, or a prompt on the second
    /// launch the spec says never appears.
    @Test func updatesComeFromTheSiteSignedAndVerified() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://codiclens.codicstack.com/appcast.xml")
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true, "on from the first launch, no prompt")
        #expect(info["SUScheduledCheckInterval"] as? Int == 86_400)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        let key = info["SUPublicEDKey"] as? String
        #expect(key.flatMap { Data(base64Encoded: $0) }?.count == 32, "an Ed25519 public key")
    }

    /// Codiclens is not sandboxed; Sparkle says not to enable these then.
    @Test func noSparkleSandboxServicesAreEnabled() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUEnableInstallerLauncherService"] == nil)
        #expect(info["SUEnableDownloaderService"] == nil)
    }
}
