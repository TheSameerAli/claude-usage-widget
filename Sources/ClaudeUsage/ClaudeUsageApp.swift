import AppKit
import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()

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
            header

            if let snapshot = store.snapshot {
                ForEach(snapshot.rows) { UsageRowView(row: $0) }
            } else if store.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Claude usage").font(.headline)
            Spacer()
            if let plan = store.snapshot?.plan {
                Text(plan.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
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
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            } label: {
                Image(systemName: "safari")
            }
            .help("Open claude.ai usage page")
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
