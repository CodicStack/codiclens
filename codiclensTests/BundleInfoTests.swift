import Foundation
import Testing

/// The app is the test host, so `Bundle.main` is the built Codiclens bundle and
/// its Info.plist is what the About box and Finder show.
struct BundleInfoTests {

    @Test func theAboutBoxCarriesTheCopyrightAndLicense() {
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        #expect(copyright == "Copyright © 2026 Emil Lykke Grann. Apache License 2.0.")
    }
}
