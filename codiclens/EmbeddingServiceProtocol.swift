import Foundation

// What the app and the embedding helper say to each other: one JSON object per
// line, the app's requests on the helper's stdin and the helper's answers on
// its stdout. The first line the helper writes is an `EmbeddingServiceHello`,
// once the model has loaded or failed to; every line after it is an
// `EmbeddingResponse` to a request, by its `id`. Requests are answered in the
// order they arrive.
//
//   → {"id":1,"kind":"embedText","texts":["task: search result | query: banana"]}
//   ← {"id":1,"vectors":["<768 float16s, base64>"]}
//   → {"id":2,"kind":"embedImage","path":"/…/Zebra.heic","budget":140,"fullSpeed":true}
//   ← {"id":2,"error":"can't read /…/Zebra.heic"}
//   → {"id":3,"kind":"hold","on":true}
//   → {"id":4,"kind":"shutdown"}

/// One thing the app asks of the helper.
nonisolated struct EmbeddingRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// `texts`, already prompted (`EmbeddingPrompt`): one vector each.
        case embedText
        /// The image at `path`, or the encoded image in `imageData`, at
        /// `budget`: one vector.
        case embedImage
        /// `duration` seconds of the recording at `path` from `start`: one
        /// vector.
        case embedAudio
        /// `on`: the Panel is open, so the helper stays loaded however long
        /// it waits. Off arms the idle exit again. Answered with no vectors.
        case hold
        /// Answered, then the helper exits.
        case shutdown
    }

    var id: Int
    var kind: Kind
    var texts: [String]?
    var path: String?
    var imageData: Data?
    var budget: ImageBudget?
    var start: Double?
    var duration: Double?
    var on: Bool?
    /// On a vector request: the backfill is at full speed (`MeaningPace`), so
    /// the helper answers it with App Nap off.
    var fullSpeed: Bool?

    init(
        id: Int, kind: Kind, texts: [String]? = nil, path: String? = nil, imageData: Data? = nil,
        budget: ImageBudget? = nil, start: Double? = nil, duration: Double? = nil, on: Bool? = nil,
        fullSpeed: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.texts = texts
        self.path = path
        self.imageData = imageData
        self.budget = budget
        self.start = start
        self.duration = duration
        self.on = on
        self.fullSpeed = fullSpeed
    }
}

/// The helper's answer to the request with the same `id`: vectors, or why
/// there are none.
nonisolated struct EmbeddingResponse: Codable, Equatable, Sendable {
    var id: Int
    /// One per input, each `EmbeddingVector.float16Data`: the precision they
    /// are stored at, in half the bytes of float32.
    var vectors: [Data]?
    var error: String?

    /// The vectors as floats, or nil when there are none or one is malformed.
    var floatVectors: [[Float]]? {
        guard let vectors else { return nil }
        let floats = vectors.compactMap(EmbeddingVector.floats(float16Data:))
        return floats.count == vectors.count ? floats : nil
    }
}

/// The helper's first line: whether the model loaded.
nonisolated struct EmbeddingServiceHello: Codable, Equatable, Sendable {
    var ready: Bool
    var textOnly: Bool?
    /// Model load and Metal warm-up, for the log.
    var loadSeconds: Double?
    /// The llama.cpp release it runs.
    var llama: String?
    var error: String?
}

/// JSON lines, both ways.
nonisolated enum EmbeddingServiceLine {
    /// `value` as one line, newline included. JSON escapes any newline inside
    /// a string, so the encoding never spans two.
    static func encode<Value: Encodable>(_ value: Value) -> Data {
        // These types always encode: strings, numbers, bools and Data.
        (try! JSONEncoder().encode(value)) + Data([0x0A])
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from line: Data) throws -> Value {
        try JSONDecoder().decode(type, from: line)
    }

    /// Splits complete lines off the front of `buffer`, leaving any partial
    /// last line in it. Empty lines are dropped.
    static func takeLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
