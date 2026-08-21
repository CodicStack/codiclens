import Testing
@testable import codiclens

/// An Index over no directories: it scans nothing and starts no FSEvents
/// stream. Lazily created once, then reused.
@MainActor
private let inertAppIndex = AppIndex(directories: [])

/// Points Subject search at the inert Index, so building a `CommandCoordinator`
/// in a test never scans `/Applications` or watches the filesystem.
///
/// `CommandCoordinator` constructs its own `SubjectSearchVM`, so this is the
/// only seam available; call it before making a coordinator.
@MainActor
func useInertAppIndex() {
    AppIndex.current = inertAppIndex
}
