//
//  codiclensApp.swift
//  codiclens
//
//  Created by Emil Lykke Grann on 07/05/2026.
//

import SwiftUI

@main
struct codiclensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let clipboardManager = ClipboardManager.shared

    var body: some Scene {
        MenuBarExtra("Codiclens", systemImage: "magnifyingglass") {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
