import SwiftUI
import AppKit

// MARK: - Activity View

struct ActivityView: View {
    @EnvironmentObject var activity: ActivityLog

    @State private var outcomeFilter: ActivityEvent.Outcome?
    @State private var kindFilter: ActivityEvent.Kind?
    @State private var labelFilter: String?
    @State private var search = ""
    @State private var expanded: Set<UUID> = []
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !activity.events.isEmpty { filterBar }
                content
            }
            .padding(28)
        }
        .onAppear {
            activity.markAllSeen()
            // A notification tap asks for one specific event — open it.
            if let focus = activity.focusEventId {
                expanded.insert(focus)
                activity.focusEventId = nil
            }
        }
        // A run finishing while this screen is open must not leave a stale badge.
        .onChange(of: activity.events.count) { _, _ in activity.markAllSeen() }
        .alert("activity.clear_history_title", isPresented: $showClearConfirm) {
            Button("common.cancel", role: .cancel) {}
            Button("common.delete", role: .destructive) { activity.clearAll() }
        } message: {
            Text("activity.clear_history_msg")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("activity.title")
                    .font(.largeTitle.bold())
                Text(L("activity.subtitle", filtered.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("activity.mark_read") { activity.markAllSeen() }
                    .disabled(activity.unreadCount == 0)
                Divider()
                Button("activity.clear_history", role: .destructive) { showClearConfirm = true }
                    .disabled(activity.events.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Filters

    private var availableLabels: [String] {
        Array(Set(activity.events.map(\.label))).filter { !$0.isEmpty }.sorted()
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $outcomeFilter) {
                Text("activity.filter.all").tag(ActivityEvent.Outcome?.none)
                Text("activity.outcome.done").tag(ActivityEvent.Outcome?.some(.done))
                Text("activity.outcome.failed").tag(ActivityEvent.Outcome?.some(.failed))
                Text("activity.outcome.cancelled").tag(ActivityEvent.Outcome?.some(.cancelled))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Picker("", selection: $kindFilter) {
                Text("activity.filter.kind").tag(ActivityEvent.Kind?.none)
                Text("activity.kind.backup").tag(ActivityEvent.Kind?.some(.backup))
                Text("activity.kind.restore").tag(ActivityEvent.Kind?.some(.restore))
                Text("activity.kind.queue").tag(ActivityEvent.Kind?.some(.queue))
                Text("activity.kind.cleanup").tag(ActivityEvent.Kind?.some(.cleanup))
            }
            .labelsHidden()
            .fixedSize()

            if !availableLabels.isEmpty {
                Picker("", selection: $labelFilter) {
                    Text("activity.filter.profile").tag(String?.none)
                    ForEach(availableLabels, id: \.self) { l in
                        Text(l).tag(String?.some(l))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            TextField("activity.search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4), lineWidth: 1))
    }

    private var hasActiveFilter: Bool {
        outcomeFilter != nil || kindFilter != nil || labelFilter != nil || !search.isEmpty
    }

    private var filtered: [ActivityEvent] {
        activity.events.filter { e in
            if let outcomeFilter, e.outcome != outcomeFilter {
                // "done" also covers smart-skipped runs — they succeeded, just without work.
                if !(outcomeFilter == .done && e.outcome == .skipped) { return false }
            }
            if let kindFilter, e.kind != kindFilter { return false }
            if let labelFilter, e.label != labelFilter { return false }
            if !search.isEmpty {
                let hit = e.profileName.localizedCaseInsensitiveContains(search)
                    || e.label.localizedCaseInsensitiveContains(search)
                    || (e.detail?.localizedCaseInsensitiveContains(search) ?? false)
                if !hit { return false }
            }
            return true
        }
    }

    // MARK: - Grouping

    private var groups: [(day: Date, events: [ActivityEvent])] {
        let cal = Calendar.current
        return Dictionary(grouping: filtered, by: { cal.startOfDay(for: $0.date) })
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day)     { return L("activity.today") }
        if cal.isDateInYesterday(day) { return L("activity.yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if activity.events.isEmpty {
            PlaceholderView(title: "activity.empty",
                            icon: "clock.badge.checkmark",
                            description: "activity.empty_hint")
                .frame(minHeight: 280)
        } else if filtered.isEmpty {
            VStack(spacing: 14) {
                PlaceholderView(title: "activity.no_results",
                                icon: "line.3.horizontal.decrease.circle",
                                description: "activity.no_results_hint")
                Button("activity.clear_filters") {
                    outcomeFilter = nil; kindFilter = nil; labelFilter = nil; search = ""
                }
                .buttonStyle(.bordered)
            }
            .frame(minHeight: 280)
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(dayTitle(group.day))
                                .font(.headline)
                            Spacer()
                            Text("\(group.events.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(group.events.enumerated()), id: \.element.id) { idx, event in
                                ActivityRowView(event: event,
                                                isExpanded: expanded.contains(event.id),
                                                onToggle: { toggle(event) })
                                if idx < group.events.count - 1 {
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(.separator.opacity(0.5), lineWidth: 1))
                    }
                }
            }
        }
    }

    private func toggle(_ event: ActivityEvent) {
        guard !event.logExcerpt.isEmpty else { return }
        if expanded.contains(event.id) { expanded.remove(event.id) }
        else                           { expanded.insert(event.id) }
    }
}

// MARK: - Row

struct ActivityRowView: View {
    let event: ActivityEvent
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(event.tint.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: event.glyph)
                        .font(.system(size: 15))
                        .foregroundStyle(event.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.profileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if !event.label.isEmpty {
                            Text(event.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(LocalizedStringKey(event.trigger.localizationKey))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(event.triggerTint.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(event.triggerTint)
                    }
                }

                Spacer(minLength: 8)

                if !event.counters.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(event.counterChips, id: \.key) { chip in
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(chip.value)")
                                    .font(.subheadline.weight(.medium).monospacedDigit())
                                    .foregroundStyle(chip.tint)
                                Text(LocalizedStringKey(chip.key))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.medium).monospacedDigit())
                    Text(event.formattedDuration)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 70, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(event.logExcerpt.isEmpty ? 0 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if isExpanded, !event.logExcerpt.isEmpty {
                ActivityLogExcerptView(lines: event.logExcerpt)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Log excerpt

struct ActivityLogExcerptView: View {
    let lines: [ActivityEvent.LogLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("activity.log_excerpt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let text = lines.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("activity.copy_log", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(line.kind.color)
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(line.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(line.kind.textColor)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Color(NSColor.textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - Presentation helpers

extension ActivityEvent {

    var glyph: String {
        switch kind {
        case .restore: return outcome == .done ? "arrow.down.circle.fill" : outcomeGlyph
        case .queue:   return outcome == .done ? "list.bullet.rectangle.fill" : outcomeGlyph
        case .cleanup: return outcome == .done ? "trash.circle.fill" : outcomeGlyph
        case .backup:  return outcomeGlyph
        }
    }

    private var outcomeGlyph: String {
        switch outcome {
        case .done:      return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .skipped:   return "bolt.circle.fill"
        }
    }

    var tint: Color {
        switch outcome {
        case .failed:    return .red
        case .cancelled: return .orange
        case .skipped:   return .teal
        case .done:
            switch kind {
            case .restore: return .blue
            case .queue:   return .purple
            case .cleanup: return .orange
            case .backup:  return .green
            }
        }
    }

    var triggerTint: Color {
        switch trigger {
        case .manual:    return .blue
        case .queued:    return .purple
        case .scheduled: return .secondary
        }
    }

    var formattedDuration: String {
        let s = Int(duration.rounded())
        if s < 60  { return L("activity.duration.seconds", s) }
        if s < 3600 { return L("activity.duration.minutes", s / 60, s % 60) }
        return L("activity.duration.hours", s / 3600, (s % 3600) / 60)
    }

    struct CounterChip { let key: String; let value: Int; let tint: Color }

    /// Only the counters that actually moved, so a quiet run stays quiet.
    var counterChips: [CounterChip] {
        var chips: [CounterChip] = []
        switch kind {
        case .backup:
            if counters.uploaded   > 0 { chips.append(.init(key: "runner.stat.uploaded",   value: counters.uploaded,   tint: .blue)) }
            if counters.registered > 0 { chips.append(.init(key: "runner.stat.registered", value: counters.registered, tint: .green)) }
            if counters.inherited  > 0 { chips.append(.init(key: "runner.stat.inherited",  value: counters.inherited,  tint: .indigo)) }
        case .restore:
            if counters.restored > 0 { chips.append(.init(key: "restore.stat.restored", value: counters.restored, tint: .blue)) }
            if counters.skipped  > 0 { chips.append(.init(key: "restore.stat.skipped",  value: counters.skipped,  tint: .secondary)) }
        case .queue:
            if counters.itemsDone   > 0 { chips.append(.init(key: "activity.outcome.done",   value: counters.itemsDone,   tint: .green)) }
            if counters.itemsFailed > 0 { chips.append(.init(key: "activity.outcome.failed", value: counters.itemsFailed, tint: .red)) }
        case .cleanup:
            break
        }
        if counters.errors > 0 {
            chips.append(.init(key: "runner.stat.errors", value: counters.errors, tint: .red))
        }
        return chips
    }
}

extension ActivityEvent.Trigger {
    var localizationKey: String {
        switch self {
        case .manual:    return "activity.trigger.manual"
        case .scheduled: return "activity.trigger.scheduled"
        case .queued:    return "activity.trigger.queued"
        }
    }
}

private extension ActivityEvent.LogLine.Kind {
    var color: Color {
        switch self {
        case .info:    return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }
    var textColor: Color {
        switch self {
        case .info:    return .primary
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
