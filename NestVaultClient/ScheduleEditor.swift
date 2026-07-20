import SwiftUI

struct ScheduleEditor: View {
    @Binding var schedule: BackupSchedule
    @State private var local: BackupSchedule = BackupSchedule()

    private let rowPadding: CGFloat = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Frequency ───────────────────────────────────────
                sectionHeader("schedule.frequency")

                VStack(spacing: 0) {
                    ForEach(BackupSchedule.Frequency.allCases) { freq in
                        frequencyRow(freq)
                        if freq != BackupSchedule.Frequency.allCases.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4), lineWidth: 1))
                .padding(.horizontal, 16)

                // ── Time of day ─────────────────────────────────────
                if local.frequency == .daily || local.frequency == .weekly {
                    sectionHeader("schedule.time_of_day")

                    VStack(spacing: 0) {
                        HStack {
                            Text("schedule.hour")
                            Spacer()
                            Stepper(value: $local.hour, in: 0...23) {
                                Text(String(format: "%02d", local.hour))
                                    .font(.title3.monospacedDigit())
                                    .frame(minWidth: 36, alignment: .center)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, rowPadding)

                        Divider().padding(.leading, 16)

                        HStack {
                            Text("schedule.minute")
                            Spacer()
                            Stepper(value: $local.minute, in: 0...59) {
                                Text(String(format: "%02d", local.minute))
                                    .font(.title3.monospacedDigit())
                                    .frame(minWidth: 36, alignment: .center)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, rowPadding)
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4), lineWidth: 1))
                    .padding(.horizontal, 16)
                }

                // ── Day of week ──────────────────────────────────────
                if local.frequency == .weekly {
                    sectionHeader("schedule.day_of_week")

                    let days: [(String, Int)] = [
                        ("schedule.sun", 1), ("schedule.mon", 2), ("schedule.tue", 3),
                        ("schedule.wed", 4), ("schedule.thu", 5), ("schedule.fri", 6),
                        ("schedule.sat", 7)
                    ]

                    VStack(spacing: 0) {
                        ForEach(days, id: \.1) { (key, tag) in
                            weekdayRow(key: key, tag: tag)
                            if tag != 7 { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4), lineWidth: 1))
                    .padding(.horizontal, 16)
                }

                // ── Custom interval ──────────────────────────────────
                if local.frequency == .custom {
                    sectionHeader("schedule.interval")

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("schedule.every_n_minutes")
                            Spacer()
                            TextField("60", value: $local.customMinutes, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                                .frame(width: 80)
                                .font(.body.monospacedDigit())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, rowPadding)
                        Divider().padding(.leading, 16)
                        Text("schedule.custom_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, rowPadding)
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4), lineWidth: 1))
                    .padding(.horizontal, 16)
                }

                // ── Next run preview ─────────────────────────────────
                if local.enabled, let next = local.nextRun() {
                    sectionHeader("schedule.next_run")

                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.blue)
                        Text(next, style: .date)
                        Text("·").foregroundStyle(.secondary)
                        Text(next, style: .time).font(.body.monospacedDigit())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, rowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4), lineWidth: 1))
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        .onAppear { local = schedule }
        .onChange(of: local) { _, newLocal in
            schedule = newLocal
        }
    }

    @ViewBuilder
    private func frequencyRow(_ freq: BackupSchedule.Frequency) -> some View {
        let isSelected = local.frequency == freq
        Button { local.frequency = freq } label: {
            let label = Text(LocalizedStringKey(labelKey(freq))).foregroundStyle(.primary)
            let check = Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold)
            HStack {
                label
                Spacer()
                if isSelected { check }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    @ViewBuilder
    private func weekdayRow(key: String, tag: Int) -> some View {
        let isSelected = local.weekday == tag
        Button { local.weekday = tag } label: {
            HStack {
                Text(LocalizedStringKey(key)).foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    @ViewBuilder
    private func sectionHeader(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func labelKey(_ freq: BackupSchedule.Frequency) -> String {
        switch freq {
        case .off:    return "schedule.freq.off"
        case .hourly: return "schedule.freq.hourly"
        case .daily:  return "schedule.freq.daily"
        case .weekly: return "schedule.freq.weekly"
        case .custom: return "schedule.freq.custom"
        }
    }
}
