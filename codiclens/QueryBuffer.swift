import Foundation

/// What the search field shows, which is deliberately not always the query.
///
/// Once a subject search settles, the next keystroke starts a new search: the
/// field briefly contains "safn" but the query becomes "n", and the field is
/// forced back to match. Working out which characters are new needs the value
/// the field was last *told* to show — not the query, and not whatever the
/// field happens to report mid-edit. That value is `display`.
@Observable
final class QueryBuffer {
    /// The text the field is showing.
    private(set) var display: String = ""

    /// Accepts what the field now contains and returns the query to search for.
    ///
    /// Against a settled search, any edit ends it: typing keeps only the new
    /// characters, and a backspace clears the lot rather than nibbling a
    /// character off a search the user has already finished with.
    ///
    /// - Parameter startsNewQuery: whether a settled search should be replaced
    ///   rather than extended.
    func accept(_ typed: String, startsNewQuery: Bool) -> String {
        let query: String
        switch (startsNewQuery, typed.count > display.count) {
        case (true, true):
            query = String(typed.dropFirst(display.count))   // just the new characters
        case (true, false):
            query = ""                                       // a deletion wipes it
        case (false, _):
            query = typed
        }
        display = query
        return query
    }

    /// Forces the field's contents — on a phase change, a reset, or an escape.
    func set(_ text: String) {
        display = text
    }
}
