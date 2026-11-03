// Adapted from DigUp (https://github.com/ARahim3/DigUp, MIT; see docs/licenses/digup/LICENSE).

import CoreGraphics
import Foundation
import Synchronization
#if arch(arm64)
import CLlama
#endif

/// What turns inputs into vectors: `Embedder` in the helper process, a fake in
/// tests. Values in, values out, one call at a time. Every vector is
/// `EmbeddingVector.dimension` long and L2-normalized.
nonisolated protocol EmbeddingBackend: AnyObject {
    /// Started without the image and audio encoders: the query encoder.
    var isTextOnly: Bool { get }
    /// The rate `embed(audio:)` wants its samples at.
    var audioSampleRate: Int { get }
    /// Already prompted (`EmbeddingPrompt`), one vector each, in order.
    func embed(texts: [String]) throws -> [[Float]]
    func embed(image: CGImage, budget: ImageBudget) throws -> [Float]
    /// Mono samples at `audioSampleRate`; anything past
    /// `EmbeddingInput.audioWindow` is dropped.
    func embed(audio samples: [Float]) throws -> [Float]
    /// Frees the model. Safe to call twice.
    func close()
}

#if arch(arm64)
/// EmbeddingGemma 2 on llama.cpp with Metal, in this process: the image and
/// audio encoders (mtmd) feed the text model, and its mean-pooled output,
/// L2-normalized, is the vector.
///
/// Inputs are framed as the reference (transformers, mlx-vlm) frames them:
/// `<bos> text <eos>`, and `<bos> <|image> soft tokens <image|> <eos>` and the
/// same for audio. The model is non-causal with no KV cache, so each input —
/// token ids and encoder rows together — goes through one `llama_process`
/// call, and up to 16 texts share one. DigUp measured this pipeline against
/// mlx-vlm in bf16: cosine ≥ 0.999 on text and images, 0.9998 on 30 seconds
/// of audio.
///
/// About 1 GB with both files loaded, about 0.25 GB text-only. Not
/// thread-safe: the helper calls it from one queue.
nonisolated final class Embedder: EmbeddingBackend {
    /// The llama.cpp release `Scripts/build-llama.sh` built, for the log.
    static let buildTag = LLAMA_BUILD_TAG

    let isTextOnly: Bool
    let audioSampleRate: Int

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var batch: OpaquePointer?
    private let vocab: OpaquePointer?
    /// 768: the width of the output projection.
    private let embeddingSize: Int
    /// The width of the encoder rows fed to the text model.
    private let rowSize: Int
    private let maxTokens: Int
    private static let maxSequences: Int32 = 16

    // The batch being filled.
    private var sequences: Int32 = 0
    private var tokens = 0
    private var position: llama_pos = 0

    /// Loads `text` on the GPU, and `media` — the image and audio encoders —
    /// when it is given. Without it the embedder is text-only: what a Query
    /// needs, in a quarter of the memory.
    init(text: URL, media mediaFile: URL?) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(text.path, modelParams) else {
            throw EmbeddingError.cannotLoad(text.lastPathComponent)
        }
        // One input has to fit one micro-batch: 2,048 tokens (the reference's
        // cut) holds a 1,120-token image or the ~750 tokens of 30 seconds of
        // audio. A Query is short, so the text-only encoder reserves less.
        let maxTokens = mediaFile == nil ? 512 : 2048
        var params = llama_context_default_params()
        params.n_ctx = UInt32(maxTokens)
        params.n_batch = UInt32(maxTokens)
        params.n_ubatch = UInt32(maxTokens)
        params.n_seq_max = UInt32(Self.maxSequences)
        // Each input may use the whole context, as in llama-embedding.
        params.kv_unified = true
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw EmbeddingError.cannotLoad("a llama.cpp context")
        }
        var media: OpaquePointer?
        var sampleRate = 16_000
        if let mediaFile {
            var mediaParams = mtmd_context_params_default()
            mediaParams.use_gpu = true
            mediaParams.print_timings = false
            mediaParams.warmup = true
            // Never rescaled here: `ImageSizing` hands over each image at the
            // size its budget calls for.
            mediaParams.image_min_tokens = 1
            mediaParams.image_max_tokens = Int32(ImageBudget.allowed.max()!)
            guard let loaded = mtmd_init_from_file(mediaFile.path, model, mediaParams) else {
                llama_free(context)
                llama_model_free(model)
                throw EmbeddingError.cannotLoad(mediaFile.lastPathComponent)
            }
            media = loaded
            if mtmd_support_audio(loaded) { sampleRate = Int(mtmd_get_audio_sample_rate(loaded)) }
        }
        self.model = model
        self.context = context
        self.media = media
        batch = llama_batch_ext_init(context)
        vocab = llama_model_get_vocab(model)
        embeddingSize = Int(llama_model_n_embd_out(model))
        rowSize = Int(llama_model_n_embd_inp(model))
        self.maxTokens = maxTokens
        isTextOnly = media == nil
        audioSampleRate = sampleRate
        // The first calls build the Metal pipelines; pay for that now, while
        // nobody is waiting on a vector.
        do {
            for _ in 0..<2 { _ = try embed(texts: [EmbeddingPrompt.query("warm up")]) }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, media, context, model) = (nil, nil, nil, nil)
    }

    // MARK: - Text

    func embed(texts: [String]) throws -> [[Float]] {
        reset()
        var vectors: [[Float]] = []
        for text in texts {
            let tokens = tokenize(text)
            if sequences == Self.maxSequences || self.tokens + tokens.count > maxTokens {
                vectors += try run()
            }
            begin()
            for token in tokens { try add(token: token) }
        }
        if sequences > 0 { vectors += try run() }
        return vectors
    }

    /// `<bos> text <eos>`, cut to `maxTokens` the way transformers cuts,
    /// keeping both special tokens. Special-token spellings inside the text
    /// are read as text: a file that happens to contain `<eos>` does not end
    /// its own input.
    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let length = Int32(utf8.count - 1)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, length, &tokens, Int32(tokens.count), true, false)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, length, &tokens, Int32(tokens.count), true, false)
        }
        tokens.removeLast(tokens.count - Int(max(count, 0)))
        if tokens.count > maxTokens {
            tokens = Array(tokens[0..<(maxTokens - 1)]) + [llama_vocab_eos(vocab)]
        }
        return tokens
    }

    // MARK: - Images and audio

    func embed(image: CGImage, budget: ImageBudget) throws -> [Float] {
        guard let media else { throw EmbeddingError.textOnly }
        guard mtmd_support_vision(media) else { throw EmbeddingError.failed("the media model has no vision encoder") }
        let (pixels, width, height) = try EmbeddingInput.rgb(image)
        guard let target = ImageSizing.targetSize(height: height, width: width, budget: budget.tokens) else {
            throw EmbeddingError.unreadable("a \(width)×\(height) image, too thin to embed")
        }
        let sized = target == (height, width) ? pixels : pixels.withUnsafeBufferPointer {
            ImageSizing.resizeBicubic(
                $0.baseAddress!, width: width, height: height, toWidth: target.width, toHeight: target.height
            )
        }
        guard let bitmap = sized.withUnsafeBufferPointer({
            mtmd_bitmap_init(UInt32(target.width), UInt32(target.height), $0.baseAddress)
        }) else {
            throw EmbeddingError.failed("can't make a \(target.width)×\(target.height) bitmap")
        }
        defer { mtmd_bitmap_free(bitmap) }
        return try embed(media: bitmap)
    }

    func embed(audio samples: [Float]) throws -> [Float] {
        guard let media else { throw EmbeddingError.textOnly }
        guard mtmd_support_audio(media) else { throw EmbeddingError.failed("the media model has no audio encoder") }
        let limit = Int(EmbeddingInput.audioWindow) * audioSampleRate
        let count = min(samples.count, limit)
        guard count > 0 else { throw EmbeddingError.unreadable("an empty audio clip") }
        let bitmap = samples.withUnsafeBufferPointer { mtmd_bitmap_init_from_audio(count, $0.baseAddress) }
        guard let bitmap else {
            throw EmbeddingError.failed("can't make an audio bitmap of \(count) samples")
        }
        defer { mtmd_bitmap_free(bitmap) }
        return try embed(media: bitmap)
    }

    /// The media marker tokenized with one bitmap gives the framed input:
    /// text chunks around the encoder's rows. Both go into one sequence.
    private func embed(media bitmap: OpaquePointer) throws -> [Float] {
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let status = String(cString: mtmd_default_marker()).withCString { marker in
            var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
        }
        guard status == 0 else { throw EmbeddingError.failed("mtmd_tokenize failed (\(status))") }
        reset()
        begin()
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for i in 0..<count { try add(token: tokens[i]) }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
                    throw EmbeddingError.failed("the media encoder failed")
                }
                try add(rows: rows, count: mtmd_input_chunk_get_n_tokens(chunk))
            }
        }
        return try run()[0]
    }

    // MARK: - The batch

    /// Starts the next input; each input is a sequence of its own.
    private func begin() {
        sequences += 1
        position = 0
    }

    /// Drops everything added so far, an input that failed halfway included.
    private func reset() {
        llama_batch_ext_clear(batch)
        sequences = 0
        tokens = 0
    }

    private func add(token: llama_token) throws {
        try place(llama_batch_ext_add_token(batch, sequences - 1, token))
    }

    private func add(rows: UnsafeMutablePointer<Float>, count: Int) throws {
        for row in 0..<count {
            // Copied by the batch.
            let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)
            try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
        }
    }

    private func place(_ index: Int32) throws {
        guard index >= 0 else { throw EmbeddingError.failed("the batch is full (\(index))") }
        guard tokens < maxTokens else { throw EmbeddingError.failed("an input longer than \(maxTokens) tokens") }
        var pos: [llama_pos] = [position, 0, 0, 0]
        guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
            throw EmbeddingError.failed("can't place token \(index)")
        }
        position += 1
        tokens += 1
    }

    /// Runs the text model over the batch: one L2-normalized vector per
    /// input, in order.
    private func run() throws -> [[Float]] {
        defer { reset() }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw EmbeddingError.failed("llama_process failed (\(status))") }
        return try (0..<sequences).map { sequence in
            guard let pooled = llama_get_embeddings_seq(context, sequence) else {
                throw EmbeddingError.failed("no pooled embedding for input \(sequence)")
            }
            return EmbeddingVector.normalized(Array(UnsafeBufferPointer(start: pooled, count: embeddingSize)))
        }
    }

    /// llama.cpp's process-wide setup, once. Its log goes to stderr, warnings
    /// and errors only: it says a great deal while loading.
    private static let backend: Void = {
        llama_log_set(logCallback, nil)
        mtmd_log_set(logCallback, nil)
        llama_backend_init()
    }()
}

/// The level of the last message that was not a continuation; `CONT` lines
/// carry on at it.
nonisolated private let lastLogLevel = Mutex(GGML_LOG_LEVEL_INFO)

nonisolated private let logCallback: ggml_log_callback = { level, text, _ in
    guard let text else { return }
    let shown = lastLogLevel.withLock { last in
        if level != GGML_LOG_LEVEL_CONT { last = level }
        return last.rawValue >= GGML_LOG_LEVEL_WARN.rawValue
    }
    if shown { fputs(text, stderr) }
}
#endif
