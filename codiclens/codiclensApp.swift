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
    private let pasteboardWatcher: PasteboardWatcher

    init() {
        pasteboardWatcher = PasteboardWatcher(history: .shared)
        pasteboardWatcher.start()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
