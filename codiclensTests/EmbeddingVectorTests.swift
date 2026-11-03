import Foundation
import Testing
@testable import codiclens

/// The arithmetic around a vector: what search compares and what the index
/// will store. None of it needs the model.
struct EmbeddingVectorTests {

    @Test func normalizingGivesLengthOne() {
        let vector = EmbeddingVector.normalized([3, 4, 0, 12])
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(length - 1) < 1e-6)
        #expect(abs(vector[0] - 3 / 13) < 1e-6)
    }

    @Test func aZeroVectorStaysZeroRatherThanNaN() {
        #expect(EmbeddingVector.normalized([0, 0, 0]) == [0, 0, 0])
        #expect(EmbeddingVector.cosine([0, 0], [1, 0]) == 0)
    }

    @Test func cosineIgnoresLength() {
        #expect(abs(EmbeddingVector.cosine([1, 2, 3], [2, 4, 6]) - 1) < 1e-6)
        #expect(abs(EmbeddingVector.cosine([1, 0], [0, 5])) < 1e-6)
        #expect(abs(EmbeddingVector.cosine([1, 0], [-1, 0]) + 1) < 1e-6)
    }

    /// Two bytes a component, and a normalized vector comes back within
    /// float16's precision at that size.
    @Test func float16RoundTripsANormalizedVector() throws {
        var generator = SystemRandomNumberGenerator()
        let vector = EmbeddingVector.normalized(
            (0..<EmbeddingVector.dimension).map { _ in Float.random(in: -1...1, using: &generator) }
        )
        let data = EmbeddingVector.float16Data(vector)
        #expect(data.count == EmbeddingVector.dimension * 2)
        let back = try #require(EmbeddingVector.floats(float16Data: data))
        #expect(back.count == vector.count)
        for (a, b) in zip(vector, back) {
            #expect(abs(a - b) <= 1e-4)
        }
        #expect(EmbeddingVector.cosine(vector, back) > 0.99999)
    }

    @Test func float16IsLittleEndianHalfPrecision() throws {
        // 1.0 is 0x3C00, -2.0 is 0xC000.
        #expect(EmbeddingVector.float16Data([1, -2]) == Data([0x00, 0x3C, 0x00, 0xC0]))
        #expect(EmbeddingVector.floats(float16Data: Data([0x00, 0x3C, 0x00, 0xC0])) == [1, -2])
    }

    @Test func anOddNumberOfBytesIsNotAVector() {
        #expect(EmbeddingVector.floats(float16Data: Data([0x00, 0x3C, 0x00])) == nil)
        #expect(EmbeddingVector.floats(float16Data: Data()) == [])
    }

    // MARK: - Prompts

    @Test func queriesAndDocumentsTakeTheModelCardsPrompts() {
        #expect(EmbeddingPrompt.query("kontrakt med Nordlys") == "task: search result | query: kontrakt med Nordlys")
        #expect(EmbeddingPrompt.codeQuery("retry with backoff") == "task: code retrieval | query: retry with backoff")
        #expect(EmbeddingPrompt.document(title: "Kontrakt.pdf", text: "Ansættelse")
            == "title: Kontrakt.pdf | text: Ansættelse")
    }

    @Test func aDocumentWithoutATitleSaysNone() {
        #expect(EmbeddingPrompt.document(title: nil, text: "x") == "title: none | text: x")
        #expect(EmbeddingPrompt.document(title: "", text: "x") == "title: none | text: x")
    }

    // MARK: - Image budgets

    @Test func budgetsAreDigUpsAndTheModelTakesThem() {
        #expect(ImageBudget.photo.tokens == 140)
        #expect(ImageBudget.screenshot.tokens == 280)
        #expect(ImageBudget.pdfPage.tokens == 280)
        #expect(ImageBudget.videoFrame.tokens == 70)
        for budget in [ImageBudget.photo, .screenshot, .pdfPage, .videoFrame] {
            #expect(ImageBudget.allowed.contains(budget.tokens))
        }
    }

    @Test func aBudgetTheModelDoesNotTakeDoesNotDecode() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ImageBudget.self, from: Data("100".utf8))
        }
        #expect(try JSONDecoder().decode(ImageBudget.self, from: Data("560".utf8)).tokens == 560)
    }

    /// The image the vision encoder sees fills the budget in 48px squares,
    /// keeping the aspect ratio.
    @Test func imagesAreSizedInWholeSquaresWithinTheBudget() throws {
        for budget in ImageBudget.allowed {
            for (height, width) in [(3024, 4032), (1080, 1920), (800, 800), (4000, 300)] {
                let target = try #require(ImageSizing.targetSize(height: height, width: width, budget: budget))
                #expect(target.height % 48 == 0 && target.width % 48 == 0)
                #expect((target.height / 48) * (target.width / 48) <= budget)
            }
        }
        #expect(ImageSizing.targetSize(height: 1, width: 1, budget: 70)?.height == 384)
    }
}
