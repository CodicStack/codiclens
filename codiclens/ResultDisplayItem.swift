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

    init(from subject: Subject) {
        self.id = subject.id.uuidString
        self.name = subject.displayName
        self.icon = .nsImage(subject.icon)
        self.subtitle = subject.subtitle
    }

    init(from action: SubjectAction) {
        self.id = action.id.uuidString
        self.name = action.name
        self.icon = switch action.icon {
        case .sfSymbol(let name): .sfSymbol(name)
        case .appIcon(let image): .nsImage(image)
        }
        self.subtitle = action.isFinal ? "" : "→"
    }

    init(from target: ActionTarget) {
        self.id = target.id.uuidString
        self.name = target.name
        self.icon = .nsImage(target.icon)
        self.subtitle = target.subtitle
    }

    init(from item: ClipboardItem) {
        self.id = item.id.uuidString
        self.name = item.displayName
        self.icon = item.isImage ? .sfSymbol("photo") : .sfSymbol("text.alignleft")
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        self.subtitle = formatter.localizedString(for: item.timestamp, relativeTo: Date())
    }
}
