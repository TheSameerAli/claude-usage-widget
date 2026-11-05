import Foundation

// MARK: - Display model

enum Severity {
    case normal, warning, critical

    init(api: String?, percent: Double) {
        switch api {
        case "critical": self = .critical
        case "warning", "high", "elevated": self = .warning
        case "normal": self = percent >= 75 ? .warning : .normal
        default: self = percent >= 90 ? .critical : (percent >= 75 ? .warning : .normal)
        }
    }
}

struct UsageRow: Identifiable {
    let id: String
    let kind: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let severity: Severity
}

struct UsageSnapshot {
    let rows: [UsageRow]
    let plan: String?

    var session: UsageRow? { rows.first { $0.kind == "session" } }
    var weekly: UsageRow? { rows.first { $0.kind == "weekly_all" } }
}

// MARK: - Errors

enum UsageError: LocalizedError {
    case notLoggedIn
    case tokenExpired
    case rateLimited
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "No Claude Code login found. Run `claude` and log in."
        case .tokenExpired: return "Login token expired. Open Claude Code once to refresh it."
        case .rateLimited: return "Rate limited by the usage API. Will retry shortly."
        case .http(let code): return "Usage API returned HTTP \(code)."
        case .badResponse: return "Unexpected response from the usage API."
        }
    }
}

// MARK: - API response (decoded leniently: unknown fields are ignored)

private struct APIResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct Limit: Decodable {
        let kind: String
        let percent: Double?
        let severity: String?
        let resets_at: String?
        let scope: Scope?
    }

    struct Scope: Decodable {
        let name: String?

        private struct Named: Decodable { let display_name: String? }
        private enum Keys: String, CodingKey { case model, surface }

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: Keys.self)
            let model = try? c?.decodeIfPresent(Named.self, forKey: .model)
            let surface = try? c?.decodeIfPresent(Named.self, forKey: .surface)
            name = model?.display_name ?? surface?.display_name
        }
    }

    let five_hour: Window?
    let seven_day: Window?
    let limits: [Limit]?
}

// MARK: - Client

enum UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    private struct Credentials {
        let accessToken: String
        let plan: String?
    }

    static func fetch() async throws -> UsageSnapshot {
        let creds = try loadCredentials()

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-usage-widget/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError.tokenExpired
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }

        let api: APIResponse
        do { api = try JSONDecoder().decode(APIResponse.self, from: data) } catch { throw UsageError.badResponse }
        return UsageSnapshot(rows: rows(from: api), plan: creds.plan)
    }

    private static func rows(from api: APIResponse) -> [UsageRow] {
        if let limits = api.limits, !limits.isEmpty {
            return limits.enumerated().map { index, limit in
                let pct = limit.percent ?? 0
                return UsageRow(
                    id: "\(limit.kind)-\(index)",
                    kind: limit.kind,
                    title: title(kind: limit.kind, scope: limit.scope?.name),
                    percent: pct,
                    resetsAt: parseDate(limit.resets_at),
                    severity: Severity(api: limit.severity, percent: pct)
                )
            }
        }

        // Fallback for the older response shape.
        var rows: [UsageRow] = []
        if let w = api.five_hour, let u = w.utilization {
            rows.append(UsageRow(id: "session", kind: "session", title: title(kind: "session", scope: nil),
                                 percent: u, resetsAt: parseDate(w.resets_at), severity: Severity(api: nil, percent: u)))
        }
        if let w = api.seven_day, let u = w.utilization {
            rows.append(UsageRow(id: "weekly_all", kind: "weekly_all", title: title(kind: "weekly_all", scope: nil),
                                 percent: u, resetsAt: parseDate(w.resets_at), severity: Severity(api: nil, percent: u)))
        }
        return rows
    }

    private static func title(kind: String, scope: String?) -> String {
        switch kind {
        case "session": return "Session (5-hour)"
        case "weekly_all": return "Weekly · all models"
        case "weekly_scoped": return "Weekly · \(scope ?? "scoped")"
        default:
            let base = kind.replacingOccurrences(of: "_", with: " ").capitalized
            return scope.map { "\(base) · \($0)" } ?? base
        }
    }

    /// Parses "2026-11-05T15:29:59.610913+00:00" (microsecond fractions aren't handled by ISO8601DateFormatter).
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    // MARK: Credentials

    /// Reads the OAuth token that Claude Code stores. It shells out to `security` because Claude Code's
    /// keychain item already trusts that binary, so reading it doesn't trigger a keychain prompt.
    /// The token is never written anywhere or refreshed here, so Claude Code's own login is left untouched.
    private static func loadCredentials() throws -> Credentials {
        if let json = readKeychain() ?? readCredentialsFile(), let creds = parse(json) {
            return creds
        }
        throw UsageError.notLoggedIn
    }

    private static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func readCredentialsFile() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return Credentials(accessToken: token, plan: oauth["subscriptionType"] as? String)
    }
}
