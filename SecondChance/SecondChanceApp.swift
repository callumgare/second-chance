//
//  SecondChanceApp.swift
//  SecondChance
//
//  Created for bringing Nancy Drew games to modern macOS

import SwiftUI

@main
struct SecondChanceApp: App {
    @StateObject private var installationViewModel = InstallationViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(installationViewModel)
                .frame(minWidth: 700, idealWidth: 700, minHeight: 550, idealHeight: 550)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
