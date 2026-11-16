import AppKit
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()

    init() {
        // Only one copy may run: two copies poll the same endpoints with the same token and get rate limited.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsageView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.menuBarSymbol)
                Text(store.menuBarText)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Panel

struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(store.providers.enumerated()), id: \.element) { index, provider in
                if index > 0 { Divider() }
                ProviderSection(provider: provider, state: store.state(provider))
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { store.refresh() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updatedText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: store.isLoading)
            }
            .help("Refresh now")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.borderless)
    }

    private func updatedText(now: Date) -> String {
        guard let updated = store.lastUpdated else { return store.isLoading ? "Loading…" : "Not updated yet" }
        let seconds = now.timeIntervalSince(updated)
        if seconds < 60 { return "Updated just now" }
        return "Updated \(Int(seconds / 60)) min ago"
    }
}

// MARK: - Provider section

struct ProviderSection: View {
    let provider: Provider
    let state: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let snapshot = state.snapshot {
                ForEach(snapshot.rows) { UsageRowView(row: $0) }
                if let note = snapshot.note {
                    Label(note, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if state.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }

            if let error = state.errorMessage, state.snapshot?.note == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(provider.name) usage").font(.headline)
            Spacer()
            if let plan = state.snapshot?.plan {
                Text(plan.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Button {
                NSWorkspace.shared.open(provider.usagePage)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open \(provider.name) usage page")
        }
    }
}

// MARK: - Row

struct UsageRowView: View {
    let row: UsageRow

    private var color: Color {
        switch row.severity {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: max(0, geo.size.width * min(row.percent, 100) / 100))
                }
            }
            .frame(height: 6)

            if let reset = row.resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(resetText(reset, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resetText(_ date: Date, now: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return "Resetting now" }

        let minutes = Int(remaining / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        let relative: String
        if days > 0 { relative = "\(days)d \(hours)h" }
        else if hours > 0 { relative = "\(hours)h \(mins)m" }
        else { relative = "\(max(mins, 1))m" }

        let absolute = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "Resets in \(relative) · \(absolute)"
    }
}
