import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gear")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Codiclens Settings")
                .font(.title2.bold())

            Text("Preferences coming soon.")
                .foregroundStyle(.secondary)
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}
