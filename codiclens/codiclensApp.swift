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

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.panelController?.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
