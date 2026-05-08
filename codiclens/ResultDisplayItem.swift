import AppKit

enum ResultIcon {
    case nsImage(NSImage)
    case sfSymbol(String)
}

struct ResultDisplayItem: Identifiable {
    let id: UUID
    let name: String
    let icon: ResultIcon
    let subtitle: String

    init(from subject: Subject) {
        self.id = subject.id
        self.name = subject.displayName
        self.icon = .nsImage(subject.icon)
        self.subtitle = subject.subtitle
    }

    init(from action: SubjectAction) {
        self.id = action.id
        self.name = action.name
        self.icon = switch action.icon {
        case .sfSymbol(let name): .sfSymbol(name)
        case .appIcon(let image): .nsImage(image)
        }
        self.subtitle = action.isFinal ? "" : "→"
    }

    init(from target: ActionTarget) {
        self.id = target.id
        self.name = target.name
        self.icon = .nsImage(target.icon)
        self.subtitle = target.subtitle
    }

    init(from item: ClipboardItem) {
        self.id = item.id
        self.name = item.displayName
        self.icon = item.isImage ? .sfSymbol("photo") : .sfSymbol("text.alignleft")
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        self.subtitle = formatter.localizedString(for: item.timestamp, relativeTo: Date())
    }
}
