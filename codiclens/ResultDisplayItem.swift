import AppKit

enum ResultIcon {
    case nsImage(NSImage)
    case sfSymbol(String)
}

struct ResultDisplayItem: Identifiable {
    /// The id of the thing this row *is*, as a string.
    ///
    /// Deliberately not a `UUID` any more. It used to be, and the one
    /// initialiser that could not supply one minted `UUID()` per call instead —
    /// so every rebuild handed `ForEach` a completely new set of rows and the
    /// whole list re-identified on every keystroke. A `String` makes it obvious
    /// that the id belongs to the source, and there is nothing convenient to
    /// invent when it doesn't.
    let id: String
    let name: String
    let icon: ResultIcon
    let subtitle: String

    /// Whether the subtitle is worth marking the Query's characters up in.
    ///
    /// True where the subtitle names the thing — "Clipboard History" under
    /// "Clipboard", the path under an app — because there the same characters
    /// the Query matched in the name usually appear again, and marking them
    /// says why the row is here. False where the subtitle is a *derived* value:
    /// a relative timestamp like "5m ago" can line up with a letter of the
    /// Query by pure coincidence, and an underline there is noise pretending to
    /// be information.
    let highlightsSubtitle: Bool

    init(from subject: Subject) {
        self.id = subject.id.uuidString
        self.name = subject.displayName
        self.icon = .nsImage(subject.icon)
        self.subtitle = subject.subtitle
        self.highlightsSubtitle = true
    }

    init(from action: SubjectAction) {
        self.id = action.id.uuidString
        self.name = action.name
        self.icon = switch action.icon {
        case .sfSymbol(let name): .sfSymbol(name)
        case .appIcon(let image): .nsImage(image)
        }
        self.subtitle = action.isFinal ? "" : "→"
        self.highlightsSubtitle = false
    }

    init(from target: ActionTarget) {
        self.id = target.id.uuidString
        self.name = target.name
        self.icon = .nsImage(target.icon)
        self.subtitle = target.subtitle
        self.highlightsSubtitle = true
    }

    init(from item: ClipboardItem) {
        self.id = item.id.uuidString
        self.name = item.displayName
        self.icon = item.isImage ? .sfSymbol("photo") : .sfSymbol("text.alignleft")
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        self.subtitle = formatter.localizedString(for: item.timestamp, relativeTo: Date())
        self.highlightsSubtitle = false
    }
}
