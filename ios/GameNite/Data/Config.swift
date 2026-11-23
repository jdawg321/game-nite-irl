import Foundation

/// Public client settings. The publishable key is safe to ship in the app:
/// row-level security and the database functions decide what each user can do.
enum AppConfig {
    static let supabaseURL = URL(string: "https://YOUR-PROJECT.supabase.co")!
    static let supabasePublishableKey = "YOUR-PUBLISHABLE-KEY"

    static let dashboardURL = URL(string: "https://game-nite-irl.vercel.app")!
    static let privacyURL = URL(string: "https://game-nite-irl.vercel.app/legal/privacy.html")!

    static var isConfigured: Bool {
        !supabaseURL.absoluteString.contains("YOUR-PROJECT") && !supabasePublishableKey.hasPrefix("YOUR-")
    }
}
