import SwiftUI

/// The key that acts on a Card, in its bottom-trailing corner.
///
/// One glyph or two — `⏎`, `⌘⏎`, `⇥` — and only on the Card that has the
/// keyboard. A hint on a Card the key does not act on is worse than no hint, so
/// every Card computes this from its own focus state and returns nil when there
/// is nothing obvious to say.
struct KeyHintChip: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .chipSurface()
    }
}
