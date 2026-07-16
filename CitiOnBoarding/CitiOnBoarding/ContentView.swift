//
//  ContentView.swift
//  CitiOnBoarding
//
//  Created by Anto Jero on 16/07/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Documents", systemImage: "doc.text.magnifyingglass")
                }
            
            TemplatesView()
                .tabItem {
                    Label("Templates", systemImage: "square.stack.3d.up")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: DocumentSession.self, inMemory: true)
}
