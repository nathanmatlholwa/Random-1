import Foundation

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var email: String?
}

/// A small dependency-free client for Supabase Auth, PostgREST and Storage.
actor SupabaseClient {
    private struct TokenResponse: Decodable {
        struct User: Decodable {
            let id: String
            let email: String?
        }
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let user: User?
    }

    private static let sessionAccount = "supabase_session"
    private let baseURL = AppConfig.supabaseURL
    private let apiKey = AppConfig.supabasePublishableKey
    private let http: URLSession
    private var session: AuthSession?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        http = URLSession(configuration: cfg)
        if let raw = KeychainStore.get(SupabaseClient.sessionAccount),
           let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = saved
        }
    }

    // MARK: session info

    var isSignedIn: Bool { session != nil }
    var userId: String? { session?.userId }
    var email: String? { session?.email }

    // MARK: auth

    func signIn(email: String, password: String) async throws {
        let data = try await authRequest(
            path: "token",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: ["email": email, "password": password]
        )
        try adopt(data)
    }

    /// Returns true when signed in, or false when the email must be confirmed first.
    func signUp(email: String, password: String) async throws -> Bool {
        let data = try await authRequest(path: "signup", query: [], body: ["email": email, "password": password])
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        if resp.access_token == nil { return false }
        try adopt(data)
        return true
    }

    func signOut() {
        session = nil
        KeychainStore.delete(SupabaseClient.sessionAccount)
    }

    private func adopt(_ data: Data) throws {
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let access = resp.access_token, let refresh = resp.refresh_token, let user = resp.user else {
            throw AppError.badResponse("The sign-in reply was incomplete.")
        }
        let s = AuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in ?? 3600)),
            userId: user.id,
            email: user.email
        )
        session = s
        if let enc = try? JSONEncoder().encode(s), let str = String(data: enc, encoding: .utf8) {
            try? KeychainStore.set(str, for: SupabaseClient.sessionAccount)
        }
    }

    private func authRequest(path: String, query: [URLQueryItem], body: [String: String]) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(req)
    }

    private func validToken() async throws -> String {
        guard let current = session else { throw AppError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        do {
            let data = try await authRequest(
                path: "token",
                query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                body: ["refresh_token": current.refreshToken]
            )
            try adopt(data)
        } catch AppError.server(let code, _) where code == 400 || code == 401 {
            signOut()
            throw AppError.notSignedIn
        }
        guard let refreshed = session else { throw AppError.notSignedIn }
        return refreshed.accessToken
    }

    // MARK: PostgREST

    func rest(_ method: String, _ table: String, query: [URLQueryItem] = [], body: Data? = nil, prefer: [String] = []) async throws -> Data {
        let token = try await validToken()
        var comps = URLComponents(url: baseURL.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !prefer.isEmpty { req.setValue(prefer.joined(separator: ","), forHTTPHeaderField: "Prefer") }
        return try await perform(req)
    }

    /// Reads every row, following the 1000-row page limit.
    func selectAll<T: Decodable>(_ table: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> [T] {
        var all: [T] = []
        var offset = 0
        let page = 1000
        while true {
            var q = query
            q.append(URLQueryItem(name: "limit", value: String(page)))
            q.append(URLQueryItem(name: "offset", value: String(offset)))
            let data = try await rest("GET", table, query: q)
            let rows = try JSONDecoder().decode([T].self, from: data)
            all.append(contentsOf: rows)
            if rows.count < page { break }
            offset += page
        }
        return all
    }

    func insert<T: Encodable>(_ table: String, rows: [T], onConflict: String? = nil, ignoreDuplicates: Bool = false) async throws -> Data {
        var q: [URLQueryItem] = []
        if let c = onConflict { q.append(URLQueryItem(name: "on_conflict", value: c)) }
        var prefer = ["return=representation"]
        if ignoreDuplicates { prefer.append("resolution=ignore-duplicates") }
        return try await rest("POST", table, query: q, body: JSONEncoder().encode(rows), prefer: prefer)
    }

    func update<T: Encodable>(_ table: String, id: UUID, row: T) async throws {
        _ = try await rest("PATCH", table, query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                           body: JSONEncoder().encode(row), prefer: ["return=minimal"])
    }

    func delete(_ table: String, id: UUID) async throws {
        _ = try await rest("DELETE", table, query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")], prefer: ["return=minimal"])
    }

    // MARK: Storage

    func upload(path: String, data: Data) async throws {
        let token = try await validToken()
        var req = URLRequest(url: storageURL(path, authenticated: false))
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        _ = try await perform(req)
    }

    func download(path: String) async throws -> Data {
        let token = try await validToken()
        var req = URLRequest(url: storageURL(path, authenticated: true))
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(req)
    }

    func removeFiles(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let token = try await validToken()
        var req = URLRequest(url: baseURL.appendingPathComponent("storage/v1/object/\(AppConfig.papersBucket)"))
        req.httpMethod = "DELETE"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prefixes": paths])
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(req)
    }

    private func storageURL(_ path: String, authenticated: Bool) -> URL {
        let mode = authenticated ? "object/authenticated" : "object"
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(baseURL.absoluteString)/storage/v1/\(mode)/\(AppConfig.papersBucket)/\(encoded)")!
    }

    // MARK: transport

    private func perform(_ req: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await http.data(for: req)
        } catch {
            throw AppError.message("Network error: \(error.localizedDescription)")
        }
        let (data, resp) = result
        guard let h = resp as? HTTPURLResponse else { throw AppError.badResponse("No response from the server.") }
        if h.statusCode >= 400 { throw AppError.server(h.statusCode, SupabaseClient.errorText(data)) }
        return data
    }

    static func errorText(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "msg", "error_description", "error"] {
                if let s = obj[key] as? String { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
