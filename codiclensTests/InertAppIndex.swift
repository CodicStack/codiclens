import Testing
@testable import codiclens

/// An Index over no directories: it scans nothing and starts no FSEvents
/// stream. Pass it as `CommandCoordinator(index:)` so building a coordinator in
/// a test never touches `/Applications` or watches the filesystem.
@MainActor
let inertAppIndex = AppIndex(directories: [])
