import Foundation

struct ClipboardItem: Identifiable, Codable {
    let id: UUID
    let content: String
    let imageFileName: String?
    let originalFilePath: String?
    let timestamp: Date

    var isImage: Bool { imageFileName != nil }
    var originalFileURL: URL? {
        originalFilePath.map { URL(fileURLWithPath: $0) }
    }

    init(content: String) {
        self.id = UUID()
        self.content = content
        self.imageFileName = nil
        self.originalFilePath = nil
        self.timestamp = Date()
    }

    init(imageFileName: String, originalFilePath: String? = nil, timestamp: Date = Date()) {
        self.id = UUID()
        self.content = "Image"
        self.imageFileName = imageFileName
        self.originalFilePath = originalFilePath
        self.timestamp = timestamp
    }

    var displayName: String {
        if isImage {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Image — \(formatter.string(from: timestamp))"
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 60 {
            return String(trimmed.prefix(60)) + "…"
        }
        return trimmed
    }
}
