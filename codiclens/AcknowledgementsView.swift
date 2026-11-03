import SwiftUI

/// Settings' Acknowledgements sheet: every entry of `Acknowledgements.all` on
/// the left, the selected one's notice on the right, read from the bundle.
struct AcknowledgementsView: View {
    let done: () -> Void
    @State private var selection: Acknowledgement.ID? = Acknowledgements.all.first?.id

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(Acknowledgements.all, selection: $selection) { acknowledgement in
                    Text(acknowledgement.title).tag(acknowledgement.id)
                }
                .listStyle(.sidebar)
                .frame(width: 190)

                Divider()

                if let acknowledgement = Acknowledgements.all.first(where: { $0.id == selection }) {
                    NoticeView(acknowledgement: acknowledgement)
                        .id(acknowledgement.id)
                } else {
                    Text("Choose an entry to read its notice.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 480)
    }
}

private struct NoticeView: View {
    let acknowledgement: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(acknowledgement.title).font(.headline)
                Text(acknowledgement.summary)
                    .foregroundStyle(.secondary)
                Text(Acknowledgements.text(of: acknowledgement)
                     ?? "This notice is missing from the app. Reinstall Codiclens to restore it.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
