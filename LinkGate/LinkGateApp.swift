//
//  LinkGateApp.swift
//  LinkGate
//
//  Created by Nick Hardwick on 9/9/26.
//

import SwiftUI

@main
struct LinkGateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
