import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if app.booting {
                ProgressView("Loading...")
            } else if !app.isSignedIn {
                AuthView()
            } else {
                MainTabs()
            }
        }
        .alert("Notice", isPresented: Binding(get: { app.banner != nil }, set: { if !$0 { app.banner = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.banner ?? "")
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView(selection: $app.selectedTab) {
            SessionTab()
                .tabItem { Label("Session", systemImage: "bolt.fill") }
                .tag(AppTab.session)
            WeakSpotsTab()
                .tabItem { Label("Weak spots", systemImage: "chart.bar.fill") }
                .tag(AppTab.weakSpots)
            LibraryTab()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .badge(app.ingestBusy ? max(app.ingestTotal - app.ingestDone, 1) : 0)
                .tag(AppTab.library)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }
}
