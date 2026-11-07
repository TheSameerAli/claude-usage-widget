import Foundation

// MARK: - Errors

enum CodexError: LocalizedError {
    case notLoggedIn
    case tokenExpired
    case rateLimited
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "No Codex login found. Run `codex` and log in with ChatGPT."
        case .tokenExpired: return "Codex login token expired. Open Codex once to refresh it."
        case .rateLimited: return "Rate limited by the Codex usage API. Will retry shortly."
        case .http(let code): return "Codex usage API returned HTTP \(code)."
        case .badResponse: return "Unexpected response from the Codex usage API."
        }
    }
}

// MARK: - API response (decoded leniently: unknown fields are ignored)

private struct CodexAPIResponse: Decodable {
    struct Window: Decodable {
        let used_percent: Double?
        let limit_window_seconds: Double?
        let reset_at: Double?
    }

    struct RateLimit: Decodable {
        let limit_reached: Bool?
        let primary_window: Window?
        let secondary_window: Window?
    }

    struct Additional: Decodable {
        let limit_name: String?
        let metered_feature: String?
        let rate_limit: RateLimit?
    }

    let plan_type: String?
    let rate_limit: RateLimit?
    let code_review_rate_limit: RateLimit?
    let additional_rate_limits: [Additional]?
}

// MARK: - Client

/// Reads Codex (ChatGPT plan) rate limits: the same data `codex` shows in `/status`.
/// It calls the live usage endpoint with the login Codex stores in `~/.codex/auth.json`. If that fails
/// (no network, expired token), it falls back to the last rate-limit snapshot in Codex's session logs.
/// The token is never refreshed, copied, or written anywhere.
enum CodexClient {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private struct Credentials {
        let accessToken: String
        let accountID: String?
    }

    static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// True when Codex looks installed/used on this Mac, so the panel can hide the section otherwise.
    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: codexHome.path)
    }

    static func fetch() async throws -> UsageSnapshot {
        do {
            return try await fetchLive()
        } catch {
            if let fallback = snapshotFromSessionLogs(reason: error) { return fallback }
            throw error
        }
    }

    private static func fetchLive() async throws -> UsageSnapshot {
        let creds = try loadCredentials()

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = creds.accountID { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-usage-widget/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexError.badResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw CodexError.tokenExpired
        case 429: throw CodexError.rateLimited
        default: throw CodexError.http(http.statusCode)
        }

        let api: CodexAPIResponse
        do { api = try JSONDecoder().decode(CodexAPIResponse.self, from: data) } catch { throw CodexError.badResponse }

        var rows = rows(from: api.rate_limit, idPrefix: "codex", label: nil)
        if let review = api.code_review_rate_limit {
            rows += self.rows(from: review, idPrefix: "codex-review", label: "Code review")
        }
        for (i, extra) in (api.additional_rate_limits ?? []).enumerated() {
            let label = extra.limit_name ?? extra.metered_feature?.replacingOccurrences(of: "_", with: " ").capitalized
            rows += self.rows(from: extra.rate_limit, idPrefix: "codex-extra-\(i)", label: label ?? "Additional")
        }
        if rows.isEmpty { throw CodexError.badResponse }
        return UsageSnapshot(rows: rows, plan: api.plan_type, note: nil)
    }

    /// `label == nil` marks the main Codex limit, whose windows count as the session/weekly figures in the menu bar.
    private static func rows(from limit: CodexAPIResponse.RateLimit?, idPrefix: String, label: String?) -> [UsageRow] {
        guard let limit else { return [] }
        let reached = limit.limit_reached ?? false
        return [("primary", limit.primary_window), ("secondary", limit.secondary_window)].compactMap { slot, window in
            guard let window, let pct = window.used_percent else { return nil }
            let seconds = window.limit_window_seconds
            let kind = label == nil ? mainKind(windowSeconds: seconds, slot: slot) : "\(idPrefix)-\(slot)"
            let base = windowTitle(seconds: seconds, slot: slot)
            return UsageRow(
                id: "\(idPrefix)-\(slot)",
                kind: kind,
                title: label.map { "\(base) · \($0)" } ?? base,
                percent: pct,
                resetsAt: window.reset_at.map { Date(timeIntervalSince1970: $0) },
                severity: reached && pct >= 100 ? .critical : Severity(api: nil, percent: pct)
            )
        }
    }

    private static func mainKind(windowSeconds: Double?, slot: String) -> String {
        guard let s = windowSeconds else { return slot == "primary" ? "session" : "weekly_all" }
        return s >= 86_400 * 6 ? "weekly_all" : (s <= 86_400 ? "session" : "codex-\(slot)")
    }

    private static func windowTitle(seconds: Double?, slot: String) -> String {
        guard let seconds, seconds > 0 else { return slot == "primary" ? "Session" : "Weekly" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return "Session (\(hours)-hour)" }
        let days = Int((seconds / 86_400).rounded())
        if days == 7 { return "Weekly" }
        if days >= 28 && days <= 31 { return "Monthly" }
        return "\(days)-day"
    }

    // MARK: Credentials

    private static func loadCredentials() throws -> Credentials {
        let url = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { throw CodexError.notLoggedIn }
        return Credentials(accessToken: token, accountID: tokens["account_id"] as? String)
    }

    // MARK: Session-log fallback

    /// Codex writes a `rate_limits` snapshot into each session log (`sessions/YYYY/MM/DD/rollout-*.jsonl`)
    /// after every turn. Use the newest one when the live endpoint isn't reachable.
    private static func snapshotFromSessionLogs(reason: Error) -> UsageSnapshot? {
        guard let file = newestSessionFile(),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            let now = Date()
            let rows: [UsageRow] = [("primary", "session"), ("secondary", "weekly_all")].compactMap { slot, kind in
                guard let w = limits[slot] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue
                else { return nil }
                let minutes = (w["window_minutes"] as? NSNumber)?.doubleValue
                var reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                // If the window has rolled over since the snapshot, usage has reset too.
                var percent = pct
                if let r = reset, r < now { percent = 0; reset = nil }
                return UsageRow(id: "codex-log-\(slot)", kind: kind,
                                title: windowTitle(seconds: minutes.map { $0 * 60 }, slot: slot),
                                percent: percent, resetsAt: reset, severity: Severity(api: nil, percent: percent))
            }
            guard !rows.isEmpty else { continue }

            let stamp = (obj["timestamp"] as? String).flatMap(parseISO) ?? modificationDate(file)
            let age = stamp.map { " from \($0.formatted(.relative(presentation: .named)))" } ?? ""
            let why: String
            switch reason as? CodexError {
            case .tokenExpired: why = "Login expired, so this is the last Codex session\(age). Open Codex to refresh."
            case .notLoggedIn: why = "Not logged in, so this is the last Codex session\(age)."
            default: why = "Couldn't reach the usage API, so this is the last Codex session\(age)."
            }
            return UsageSnapshot(rows: rows, plan: nil, note: why)
        }
        return nil
    }

    private static func newestSessionFile() -> URL? {
        let fm = FileManager.default
        var dir = codexHome.appendingPathComponent("sessions")
        // Descend year → month → day, newest first.
        for _ in 0..<3 {
            guard let next = (try? fm.contentsOfDirectory(atPath: dir.path))?
                .filter({ Int($0) != nil }).sorted(by: >).first else { return nil }
            dir.appendPathComponent(next)
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "jsonl" } ?? []
        return files.max { (modificationDate($0) ?? .distantPast) < (modificationDate($1) ?? .distantPast) }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func parseISO(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
