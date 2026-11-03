// Prompts and image budgets adapted from DigUp (https://github.com/ARahim3/DigUp, MIT; see docs/licenses/digup/LICENSE).

import Accelerate
import Foundation

/// The vectors search by meaning compares: 768 floats from EmbeddingGemma 2,
/// L2-normalized, so the cosine of two of them is their dot product. Stored as
/// 768 float16s (1.5 KB) and compared as float32.
///
/// Never compute *with* float16: the model's activations overflow it and come
/// back NaN. Rounding a finished, normalized vector to float16 for storage is
/// fine; each component is below 1 in magnitude.
nonisolated enum EmbeddingVector {
    static let dimension = 768

    /// `vector` scaled to length 1. A zero vector stays zero rather than
    /// becoming NaN.
    static func normalized(_ vector: [Float]) -> [Float] {
        let length = vDSP.sumOfSquares(vector).squareRoot()
        guard length > 0, length.isFinite else { return [Float](repeating: 0, count: vector.count) }
        return vDSP.divide(vector, length)
    }

    /// The cosine of the angle between two vectors of the same length; 0 when
    /// either is zero.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vectors of different lengths")
        let lengths = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        guard lengths > 0 else { return 0 }
        return vDSP.dot(a, b) / lengths
    }

    /// `vector` as little-endian float16s, two bytes a component. Goes through
    /// vImage rather than `Float16`, which an x86_64 slice does not have.
    static func float16Data(_ vector: [Float]) -> Data {
        var halves = Data(count: vector.count * 2)
        vector.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBytes { destination in
                var from = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                    width: vImagePixelCount(vector.count), rowBytes: vector.count * 4
                )
                var to = vImage_Buffer(
                    data: destination.baseAddress, height: 1,
                    width: vImagePixelCount(vector.count), rowBytes: vector.count * 2
                )
                vImageConvert_PlanarFtoPlanar16F(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return halves
    }

    /// The floats `float16Data` stored, or nil when `data` is not a whole
    /// number of float16s.
    static func floats(float16Data data: Data) -> [Float]? {
        guard data.count.isMultiple(of: 2) else { return nil }
        let count = data.count / 2
        var floats = [Float](repeating: 0, count: count)
        guard count > 0 else { return floats }
        data.withUnsafeBytes { source in
            floats.withUnsafeMutableBufferPointer { destination in
                var from = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: 1,
                    width: vImagePixelCount(count), rowBytes: count * 2
                )
                var to = vImage_Buffer(
                    data: destination.baseAddress, height: 1,
                    width: vImagePixelCount(count), rowBytes: count * 4
                )
                vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        return floats
    }
}

/// EmbeddingGemma 2's task prompts, from the model card. Text without one
/// "still works but reduces precision". A query and the documents it should
/// find take *different* prompts; images and audio take none.
nonisolated enum EmbeddingPrompt {
    /// What the user typed, looking for a file.
    static func query(_ text: String) -> String {
        "task: search result | query: \(text)"
    }

    /// What the user typed, looking for code by what it does.
    static func codeQuery(_ text: String) -> String {
        "task: code retrieval | query: \(text)"
    }

    /// A stretch of a file's text. `title` is the file's name, or the path of
    /// a code file in its repo; an empty one is written as the card's `none`.
    static func document(title: String?, text: String) -> String {
        let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        return "title: \(title) | text: \(text)"
    }
}

/// How many soft tokens the vision encoder spends on one picture: more sees
/// finer detail and costs more time. The model takes 70, 140, 280, 560 or
/// 1120; the four uses below are DigUp's, chosen on its evals.
nonisolated struct ImageBudget: Hashable, Codable, Sendable {
    let tokens: Int

    static let allowed = [70, 140, 280, 560, 1120]

    /// A photo: what it shows matters, not its fine print.
    static let photo = ImageBudget(tokens: 140)
    /// A screenshot: mostly text and interface, so it needs the detail.
    static let screenshot = ImageBudget(tokens: 280)
    /// A PDF page rendered as a picture (a scan, a slide).
    static let pdfPage = ImageBudget(tokens: 280)
    /// One keyframe of a video; there are many, and they repeat.
    static let videoFrame = ImageBudget(tokens: 70)

    init(tokens: Int) {
        precondition(Self.allowed.contains(tokens), "EmbeddingGemma 2 takes \(Self.allowed) soft tokens an image")
        self.tokens = tokens
    }

    init(from decoder: Decoder) throws {
        let tokens = try decoder.singleValueContainer().decode(Int.self)
        guard Self.allowed.contains(tokens) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(tokens) is not one of \(Self.allowed)"
            ))
        }
        self.tokens = tokens
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tokens)
    }
}
