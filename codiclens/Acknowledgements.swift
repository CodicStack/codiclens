import Foundation

/// One entry in Settings' Acknowledgements: something Codiclens ships, is
/// built from or credits, with the notice its license asks to travel with
/// the app.
nonisolated struct Acknowledgement: Identifiable, Hashable, Sendable {
    let title: String
    /// One line under the title: the license, and what Codiclens uses it for.
    let summary: String
    /// Bundled files, relative to the app's Resources folder, shown in order.
    let files: [String]

    var id: String { title }
}

/// Every notice the app carries (license audit, #5). The texts are bundled
/// files: `LICENSE` and `NOTICE` from the repository root, the folder
/// `docs/licenses` as `licenses/`, and `emoji-data-license.txt` through the
/// synchronised group. Bumping llama.cpp, Sparkle or the emoji data updates
/// NOTICE and those files in the same commit.
nonisolated enum Acknowledgements {
    static let all: [Acknowledgement] = [
        Acknowledgement(
            title: "Codiclens",
            summary: "Apache License 2.0. Copyright 2026 Emil Lykke Grann.",
            files: ["NOTICE", "LICENSE"]
        ),
        Acknowledgement(
            title: "llama.cpp and ggml",
            summary: "MIT License. Search by meaning runs on it, built into the app with the code it compiles in.",
            files: ["licenses/llama-cpp/LICENSE", "licenses/llama-cpp/THIRD-PARTY.txt"]
        ),
        Acknowledgement(
            title: "Sparkle",
            summary: "MIT License, with parts under BSD, MIT and zlib licenses. Keeps Codiclens up to date.",
            files: ["licenses/sparkle/LICENSE"]
        ),
        Acknowledgement(
            title: "DigUp",
            summary: "MIT License. Parts of the File Index and of search by meaning are adapted from it.",
            files: ["licenses/digup/LICENSE"]
        ),
        Acknowledgement(
            title: "Pillow",
            summary: "MIT-CMU License. Image resizing for search by meaning follows its bicubic resampling.",
            files: ["licenses/pillow/LICENSE"]
        ),
        Acknowledgement(
            title: "Unicode Emoji Data",
            summary: "Unicode License v3. The emoji, their names and keywords come from Unicode Emoji and CLDR.",
            files: ["emoji-data-license.txt"]
        ),
        Acknowledgement(
            title: "EmbeddingGemma 2",
            summary: "Apache License 2.0. The model search by meaning downloads; not included in the app.",
            files: ["licenses/embeddinggemma-2/README.txt"]
        ),
    ]

    /// The entry's files joined, or nil when any of them is missing from
    /// `bundle`.
    static func text(of acknowledgement: Acknowledgement, in bundle: Bundle = .main) -> String? {
        guard let resources = bundle.resourceURL else { return nil }
        var texts: [String] = []
        for file in acknowledgement.files {
            guard let text = try? String(contentsOf: resources.appending(path: file), encoding: .utf8) else { return nil }
            texts.append(text.trimmingCharacters(in: .newlines))
        }
        return texts.joined(separator: "\n\n\n")
    }
}
