import Foundation
import Testing
@testable import codiclens

/// The Acknowledgements Settings shows, against the built app: the test host
/// is Codiclens, so `Bundle.main` is the bundle a user downloads. The expected
/// components and notices are the license audit's (#5), not the model's own
/// list read back.
struct AcknowledgementsTests {

    /// Every row of the audit's component table that ships something or
    /// asks for credit, by the title Settings shows.
    static let auditedComponents = [
        "Codiclens",
        "llama.cpp and ggml",
        "Sparkle",
        "DigUp",
        "Pillow",
        "Unicode Emoji Data",
        "EmbeddingGemma 2",
    ]

    @Test func everyAuditedComponentIsListed() {
        #expect(Acknowledgements.all.map(\.title) == Self.auditedComponents)
    }

    @Test(arguments: Acknowledgements.all)
    func everyListedNoticeShipsInTheApp(_ acknowledgement: Acknowledgement) throws {
        let text = try #require(Acknowledgements.text(of: acknowledgement), "\(acknowledgement.title) is missing from the bundle")
        #expect(!text.isEmpty)
        #expect(!acknowledgement.summary.isEmpty)
    }

    /// What each notice must name, from the audit's tables: every copyright
    /// holder whose license asks for its notice in a binary distribution,
    /// and a credit for the rest.
    static let requiredNotices: [String: [String]] = [
        "Codiclens": [
            "Copyright 2026 Emil Lykke Grann", "Apache License", "Version 2.0, January 2004",
            "llama.cpp", "DigUp", "Pillow", "Sparkle", "Unicode", "EmbeddingGemma 2",
        ],
        "llama.cpp and ggml": [
            "Copyright (c) 2023-2026 The ggml authors",
            "Copyright 2024 Mozilla Foundation",                          // llamafile sgemm
            "Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng",        // YaRN
            "ggllm.cpp",                                                  // BPE tokenizer
            "Pillow",                                                     // mtmd resampling
            "Copyright (c) 2012-2021 Yann Collet",                        // xxHash, BSD-2
            "Redistributions in binary form must reproduce",
            "Copyright (c) 2021 William Casarin",                         // rotate-bits
            "Igor Pavlov", "Steve Reid",                                  // sha256, sha1
            "stb_image", "Sean Barrett", "miniaudio", "David Reid", "subprocess.h",
        ],
        "Sparkle": [
            "Andy Matuschak", "Colin Percival", "Yuta Mori", "Orson Peters", "Mark Hamlin",
        ],
        "DigUp": ["Copyright (c) 2026 Abdur Rahim", "each such file says so in its first line"],
        "Pillow": ["Secret Labs AB", "Fredrik Lundh", "Jeffrey 'Alex' Clark", "MIT-CMU"],
        "Unicode Emoji Data": ["Unicode, Inc.", "Unicode-3.0"],
        "EmbeddingGemma 2": [
            "google/embeddinggemma-2", "ggml-org/embeddinggemma-2-GGUF", ModelFiles.revision,
            "Apache License 2.0", "not included in Codiclens",
        ],
    ]

    @Test(arguments: Acknowledgements.all)
    func eachNoticeNamesWhatItsLicenseAsksFor(_ acknowledgement: Acknowledgement) throws {
        let text = try #require(Acknowledgements.text(of: acknowledgement))
        let required = try #require(Self.requiredNotices[acknowledgement.title])
        for phrase in required {
            #expect(text.contains(phrase), "\(acknowledgement.title) does not mention \(phrase)")
        }
    }

    /// The DigUp notice no longer lists files, so it cannot go stale.
    @Test func theDigUpNoticeListsNoFiles() throws {
        let digUp = try #require(Acknowledgements.all.first { $0.title == "DigUp" })
        let text = try #require(Acknowledgements.text(of: digUp))
        #expect(!text.contains(".swift"))
    }

    /// NOTICE names the llama.cpp release the app was built against, so a
    /// bump without a NOTICE update fails here.
    @Test func theNoticeNamesTheLlamaReleaseThatIsLinked() throws {
        let codiclens = try #require(Acknowledgements.all.first { $0.title == "Codiclens" })
        let text = try #require(Acknowledgements.text(of: codiclens))
        #expect(text.contains("release \(Embedder.buildTag)"))
    }

    // MARK: - Copied from the sources, not retyped

    /// The repository this test file is in.
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    /// `Scripts/build-llama.sh`'s checkout, present wherever the app was built.
    static let llamaSource = repository.appending(path: "Vendor/llama.cpp")
    /// Xcode's checkout of the pinned Sparkle, beside `Build/Products/<config>/`.
    static let sparkleSource = Bundle.main.bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "SourcePackages/checkouts/Sparkle")

    static func bundled(_ file: String) throws -> String {
        try String(contentsOf: try #require(Bundle.main.resourceURL).appending(path: file), encoding: .utf8)
    }

    static func source(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: llamaSource.appending(path: "LICENSE").path)))
    func theLlamaLicensesAreTheLinkedCheckouts() throws {
        #expect(try Self.bundled("licenses/llama-cpp/LICENSE") == String(contentsOf: Self.llamaSource.appending(path: "LICENSE"), encoding: .utf8))
        let thirdParty = try Self.bundled("licenses/llama-cpp/THIRD-PARTY.txt")
        for file in ["vendor/hash/xxhash/LICENSE", "vendor/hash/rotate-bits/LICENSE.md", "vendor/hash/sha256/LICENSE"] {
            #expect(thirdParty.contains(try Self.source(Self.llamaSource.appending(path: file))), "\(file) changed")
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sparkleSource.appending(path: "LICENSE").path)))
    func theSparkleLicenseIsTheLinkedCheckouts() throws {
        #expect(try Self.bundled("licenses/sparkle/LICENSE") == String(contentsOf: Self.sparkleSource.appending(path: "LICENSE"), encoding: .utf8))
    }
}
