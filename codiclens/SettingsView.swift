import SwiftUI

struct SettingsView: View {
    @AppStorage("appTheme") private var selectedTheme: String = AppTheme.system.rawValue

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gear")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text("Codiclens Settings")
                .font(.title2.bold())

            Picker("Appearance", selection: $selectedTheme) {
                ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                    Text(theme.label).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Spacer()

            // Codiclens is an accessory app with no menu bar of its own, so
            // this is the only way out.
            Button("Quit Codiclens") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .controlSize(.large)
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}
