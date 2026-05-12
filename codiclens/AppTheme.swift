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

struct ThemedGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 32

    func body(content: Content) -> some View {
        content.background(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(colorScheme == .dark
                        ? Color.black.opacity(0.92)
                        : Color.white.opacity(0.7))
            }
        )
    }
}
