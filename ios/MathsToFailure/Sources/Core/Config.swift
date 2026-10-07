import Foundation

/// Public connection details for the Supabase project. The publishable key is designed to ship inside apps.
/// All data is protected by Row Level Security, so it only opens the signed-in user's own rows.
/// Never put a service_role key or any AI provider key in this file.
enum AppConfig {
    static let supabaseURL = URL(string: "https://somkzckhtbjnkzbzhcjb.supabase.co")!
    static let supabasePublishableKey = "sb_publishable_H2eWGtvIDMG3VIbbHHvHSQ_fURfiOsK"
    static let papersBucket = "papers"
}
