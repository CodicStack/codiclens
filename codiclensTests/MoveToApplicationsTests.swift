import Foundation
import Testing
@testable import codiclens

/// Whether a launch offers to move the app, and what the move does, from
/// where the app runs. Plans only: nothing here copies, trashes or touches
/// /Applications.
@MainActor
struct MoveToApplicationsTests {
    private let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)

    private func plan(_ path: String, original: String? = nil, diskImage: String? = nil) -> MoveToApplications.Plan {
        MoveToApplications.plan(
            running: URL(filePath: path, directoryHint: .isDirectory),
            original: original.map { URL(filePath: $0, directoryHint: .isDirectory) },
            diskImageVolume: diskImage.map { URL(filePath: $0, directoryHint: .isDirectory) },
            applications: applications
        )
    }

    @Test func inApplicationsItStays() {
        #expect(plan("/Applications/Codiclens.app") == .stay)
        #expect(plan("/Applications/Utilities/Codiclens.app") == .stay)
    }

    @Test func fromDownloadsItMovesAndTrashesTheOriginal() {
        #expect(plan("/Users/someone/Downloads/Codiclens.app") == .move(
            copy: URL(filePath: "/Users/someone/Downloads/Codiclens.app", directoryHint: .isDirectory),
            to: URL(filePath: "/Applications/Codiclens.app", directoryHint: .isDirectory),
            trash: URL(filePath: "/Users/someone/Downloads/Codiclens.app", directoryHint: .isDirectory),
            eject: nil
        ))
    }

    /// A folder whose name only starts like Applications is somewhere else.
    @Test func aLookalikeFolderIsNotApplications() {
        #expect(plan("/ApplicationsOld/Codiclens.app") != .stay)
    }

    /// On a mounted DMG the original cannot be trashed; the disk image is
    /// ejected once the app has quit.
    @Test func fromADiskImageItCopiesAndEjects() {
        #expect(plan("/Volumes/Codiclens/Codiclens.app", diskImage: "/Volumes/Codiclens") == .move(
            copy: URL(filePath: "/Volumes/Codiclens/Codiclens.app", directoryHint: .isDirectory),
            to: URL(filePath: "/Applications/Codiclens.app", directoryHint: .isDirectory),
            trash: nil,
            eject: URL(filePath: "/Volumes/Codiclens", directoryHint: .isDirectory)
        ))
    }

    /// Translocated, the app runs from a random read-only path; the copy is
    /// made from there and it is the original in Downloads that goes.
    @Test func translocatedItTrashesTheOriginalItCameFrom() {
        let running = "/private/var/folders/xy/T/AppTranslocation/1234/d/Codiclens.app"
        #expect(plan(running, original: "/Users/someone/Downloads/Codiclens.app") == .move(
            copy: URL(filePath: running, directoryHint: .isDirectory),
            to: URL(filePath: "/Applications/Codiclens.app", directoryHint: .isDirectory),
            trash: URL(filePath: "/Users/someone/Downloads/Codiclens.app", directoryHint: .isDirectory),
            eject: nil
        ))
    }

    /// Translocated straight off a DMG: copy, and eject rather than trash.
    @Test func translocatedOffADiskImageEjects() {
        let running = "/private/var/folders/xy/T/AppTranslocation/1234/d/Codiclens.app"
        let move = plan(running, original: "/Volumes/Codiclens/Codiclens.app", diskImage: "/Volumes/Codiclens")
        #expect(move == .move(
            copy: URL(filePath: running, directoryHint: .isDirectory),
            to: URL(filePath: "/Applications/Codiclens.app", directoryHint: .isDirectory),
            trash: nil,
            eject: URL(filePath: "/Volumes/Codiclens", directoryHint: .isDirectory)
        ))
    }
}
