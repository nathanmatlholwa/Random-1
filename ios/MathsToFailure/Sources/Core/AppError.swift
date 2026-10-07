import Foundation

enum AppError: LocalizedError {
    case message(String)
    case notSignedIn
    case missingKey(Provider)
    case keychain(OSStatus)
    case server(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .notSignedIn: return "You are signed out. Sign in again."
        case .missingKey(let p): return "Add your \(p.title) API key in Settings first."
        case .keychain(let s): return "Keychain error (\(s)). Check that the app has a signing team selected."
        case .server(let code, let m): return "Server error \(code): \(m)"
        case .badResponse(let m): return m
        }
    }
}
