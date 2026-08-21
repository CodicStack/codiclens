import SwiftUI

enum AppTheme: String, CaseIterable {
    case light, dark, system

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    var resolvedColorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

struct ThemeWrapper<Content: View>: View {
    @AppStorage("appTheme") private var theme: String = AppTheme.system.rawValue
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .preferredColorScheme(AppTheme(rawValue: theme)?.resolvedColorScheme)
    }
}
