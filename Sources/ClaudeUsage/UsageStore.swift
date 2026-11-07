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
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderState] = [:]

    /// Background poll interval. The usage endpoints rate-limit aggressive polling, so stay conservative.
    private let pollInterval: TimeInterval = 5 * 60
    /// Opening the panel triggers a refresh, but no more often than this.
    private let minRefreshInterval: TimeInterval = 60

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

        for provider in providers where !state(provider).isLoading {
            states[provider, default: ProviderState()].isLoading = true
            Task {
                var s = state(provider)
                do {
                    s.snapshot = try await provider.fetch()
                    s.lastUpdated = Date()
                    s.errorMessage = nil
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
