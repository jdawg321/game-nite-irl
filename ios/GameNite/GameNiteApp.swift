import SwiftUI

@main
struct GameNiteApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.surface)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.neon)
                .preferredColorScheme(.dark)
                .task { await app.start() }
                .onOpenURL { url in
                    // gamenite://join/GN-ABCD
                    guard url.scheme == "gamenite", url.host == "join" else { return }
                    app.pendingCode = url.lastPathComponent
                    app.selectedTab = .events
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await app.resume() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch app.phase {
            case .loading:
                ProgressView().tint(Theme.neon)
            case .signedOut:
                SignInView()
            case .needsProfile:
                ProfileSetupView()
            case .ready:
                TabView(selection: $app.selectedTab) {
                    EventsView()
                        .tabItem { Label("Events", systemImage: "calendar") }
                        .tag(AppState.Tab.events)
                    GameView()
                        .tabItem { Label("Game", systemImage: "location.north.circle") }
                        .tag(AppState.Tab.game)
                        .badge(app.current != nil && !(app.current?.status.isOver ?? true) ? "•" : nil)
                    ProfileView()
                        .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                        .tag(AppState.Tab.profile)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}
