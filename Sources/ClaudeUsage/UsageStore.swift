import AppKit
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?

    /// Background poll interval. The usage endpoint rate-limits aggressive polling, so stay conservative.
    private let pollInterval: TimeInterval = 5 * 60
    /// Opening the panel triggers a refresh, but no more often than this.
    private let minRefreshInterval: TimeInterval = 60

    private var lastAttempt: Date?
    private var timer: Timer?

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

    func refresh(force: Bool = false) {
        guard !isLoading else { return }
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < minRefreshInterval { return }

        lastAttempt = Date()
        isLoading = true
        Task {
            do {
                snapshot = try await UsageClient.fetch()
                lastUpdated = Date()
                errorMessage = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: Menu bar label

    var menuBarText: String {
        guard let snapshot else { return errorMessage == nil ? "…" : "!" }
        let parts = [snapshot.session, snapshot.weekly].compactMap { $0 }.map { "\(Int($0.percent.rounded()))%" }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    var menuBarSymbol: String {
        guard let snapshot else { return "gauge.with.dots.needle.0percent" }
        let peak = snapshot.rows.map(\.percent).max() ?? 0
        switch peak {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<45: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}
