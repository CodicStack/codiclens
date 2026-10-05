import Foundation
import Vision

/// Reading the text out of an image.
///
/// The whole of the app's Vision use, deliberately. `CommandCoordinator`
/// returns `.ocr(URL)` and knows nothing about this file — see
/// `docs/adr/0007-async-action-behind-the-effect-seam.md`. `SystemEffectRunner`
/// is the only caller, and no test reaches here: a test hands the coordinator a
/// canned string through the same callback the runner uses, so Vision never
/// runs under `xcodebuild test`.
///
/// The configuration is fixed in code and has no Settings knob. `.accurate`
/// with language detection and correction on is what makes the OCR Text
/// readable prose rather than a bag of characters; the faster level is the
/// wrong trade for an Action the user is waiting on the result of.
enum OCR {

    /// The OCR Text of the image at `url`, or `nil` when there is none.
    ///
    /// An image with no readable text produces **no OCR Text at all** rather
    /// than an empty string — see `GLOSSARY.md`. A Vision failure is reported
    /// the same way, because to the user the two are the same answer: nothing
    /// to show.
    static func text(in url: URL) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: url)
        } catch {
            return nil
        }

        // Joined in the order Vision returned them, and deliberately **not**
        // sorted by `boundingRegion`. Sorting top-to-bottom looks like the
        // obvious improvement and is not: a two-column page, or a screenshot
        // with a sidebar, has lines at similar heights on both sides, so
        // sorting interleaves the columns line by line into nonsense. Reading
        // order is Vision's answer and not ours to second-guess.
        let text = observations.map(\.transcript).joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
