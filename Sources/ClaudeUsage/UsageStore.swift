import AppKit
import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var usagePage: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }

    func fetch() async throws -> UsageSnapshot {
        switch self {
        case .claude: return try await UsageClient.fetch()
        case .codex: return try await CodexClient.fetch()
        }
    }
}

struct ProviderState {
    var snapshot: UsageSnapshot?
    var errorMessage: String?
    var lastUpdated: Date?
    var isLoading = false
    /// After a 429, no requests go to this provider before this time, even from the refresh button.
    var backoffUntil: Date?
    /// 429s in a row, for exponential backoff. Reset on success.
    var rateLimitStrikes = 0
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderState] = [:]

    /// Background poll interval. The usage endpoints rate-limit aggressive polling, so stay conservative.
    private let pollInterval: TimeInterval = 5 * 60
    /// Opening the panel triggers a refresh, but no more often than this.
    private let minRefreshInterval: TimeInterval = 2 * 60
    /// Longest wait after repeated 429s.
    private let maxBackoff: TimeInterval = 60 * 60

    private var lastAttempt: Date?
    private var timer: Timer?

    /// Codex is shown only if it's set up on this Mac, so Claude-only users see no change.
    var providers: [Provider] {
        Provider.allCases.filter { $0 != .codex || CodexClient.isPresent }
    }

    var isLoading: Bool { states.values.contains { $0.isLoading } }

    var lastUpdated: Date? { providers.compactMap { states[$0]?.lastUpdated }.min() }

    init() {
        refresh(force: true)

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
        timer?.tolerance = 30

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        }
    }

    func state(_ provider: Provider) -> ProviderState { states[provider] ?? ProviderState() }

    func refresh(force: Bool = false) {
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < minRefreshInterval { return }
        lastAttempt = Date()

        let now = Date()
        for provider in providers where !state(provider).isLoading {
            if let until = state(provider).backoffUntil, until > now { continue }
            states[provider, default: ProviderState()].isLoading = true
            Task {
                var s = state(provider)
                do {
                    s.snapshot = try await provider.fetch()
                    s.lastUpdated = Date()
                    s.errorMessage = nil
                    s.backoffUntil = nil
                    s.rateLimitStrikes = 0
                } catch let error as RateLimited {
                    // 5, 10, 20, 40, 60 min… or longer if the server asks for it.
                    s.rateLimitStrikes += 1
                    let exponential = pollInterval * pow(2, Double(s.rateLimitStrikes - 1))
                    let delay = min(max(exponential, error.retryAfter ?? 0), maxBackoff)
                    let until = Date().addingTimeInterval(delay)
                    s.backoffUntil = until
                    let time = until.formatted(date: .omitted, time: .shortened)
                    s.errorMessage = s.snapshot == nil
                        ? "\(error.errorDescription ?? "Rate limited.") Trying again at \(time)."
                        : "\(error.errorDescription ?? "Rate limited.") Showing the last data; trying again at \(time)."
                } catch {
                    s.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                s.isLoading = false
                states[provider] = s
            }
        }
    }

    // MARK: Menu bar label

    /// "11% · 91%" per provider (session · weekly), joined with "│" (Claude first, then Codex).
    var menuBarText: String {
        let parts = providers.compactMap { provider -> String? in
            guard let snapshot = state(provider).snapshot else { return nil }
            let pcts = [snapshot.session, snapshot.weekly].compactMap { $0 }.map { "\(Int($0.percent.rounded()))%" }
            return pcts.isEmpty ? nil : pcts.joined(separator: " · ")
        }
        if parts.isEmpty {
            return providers.contains { state($0).errorMessage != nil } ? "!" : "…"
        }
        return parts.joined(separator: " │ ")
    }

    var menuBarSymbol: String {
        let peak = providers.flatMap { state($0).snapshot?.rows ?? [] }.map(\.percent).max() ?? 0
        switch peak {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<45: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}
