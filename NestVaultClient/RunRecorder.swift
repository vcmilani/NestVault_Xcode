import AppKit

// MARK: - Run Recorder
//
// The single place where a finished run turns into persisted state.
// Before this existed, `lastRun`/`lastRunStatus` were written only by the scheduler,
// so manual and queued runs left the profile looking like it had never run.
//
// Every runner goes through `attach` exactly once, and the runner's own `defer` hook
// guarantees the callback fires on every exit path — including cancellation and the
// smart-skip early success.

@MainActor
enum RunRecorder {

    // MARK: - Backup

    static func attach(_ runner: BackupRunner,
                       trigger: ActivityEvent.Trigger,
                       store: ConfigStore,
                       activity: ActivityLog,
                       notify: Bool = true) {

        // Captures `store` and `activity` (app-lifetime objects that hold no reference
        // back to any runner) and never the runner itself — no retain cycle.
        runner.onFinish = { r, profile, startedAt in
            let outcome = backupOutcome(r)

            // Re-read the live profile: it may have been edited (or deleted) mid-run,
            // and the captured copy would clobber those edits.
            if var updated = store.profiles.first(where: { $0.id == profile.id }) {
                updated.lastRun       = Date()
                updated.lastRunStatus = outcome.rawValue
                if r.wasFullBackup && r.status == .done {
                    updated.lastFullBackupDate = Date()
                }
                store.update(updated)
            }

            var counters = ActivityEvent.Counters()
            counters.uploaded   = r.stats.uploaded
            counters.registered = r.stats.registered
            counters.cached     = r.stats.cached
            counters.ignored    = r.stats.ignored
            counters.errors     = r.stats.errors
            counters.inherited  = r.stats.inherited

            activity.append(ActivityEvent(
                startedAt:   startedAt,
                kind:        .backup,
                trigger:     trigger,
                profileId:   profile.id,
                profileName: profile.name,
                label:       profile.label,
                outcome:     outcome,
                counters:    counters,
                logExcerpt:  ActivityExcerpt.make(r.entries.map { ($0.text, $0.kind.activityKind) })
            ))

            guard notify, shouldNotify(trigger: trigger, outcome: outcome) else { return }
            switch outcome {
            case .failed:
                BackupNotifier.notify(title: L("notify.failed_title"),
                                      body:  L("notify.failed_body", profile.name))
            default:
                BackupNotifier.notify(title: L("notify.done_title"),
                                      body:  L("notify.done_body", profile.name,
                                               r.stats.uploaded, r.stats.registered, r.stats.errors))
            }
        }
    }

    // MARK: - Restore

    static func attach(_ runner: RestoreRunner,
                       activity: ActivityLog,
                       profileName: String?,
                       notify: Bool = true) {

        runner.onFinish = { r, request, startedAt in
            let outcome: ActivityEvent.Outcome
            switch r.status {
            case .done:      outcome = .done
            case .cancelled: outcome = .cancelled
            default:         outcome = .failed
            }

            var counters = ActivityEvent.Counters()
            counters.restored = r.stats.restored
            counters.skipped  = r.stats.skipped
            counters.errors   = r.stats.errors
            counters.bytes    = r.stats.doneBytes

            activity.append(ActivityEvent(
                startedAt:   startedAt,
                kind:        .restore,
                trigger:     .manual,
                profileId:   nil,
                profileName: profileName ?? request.label,
                label:       request.label,
                outcome:     outcome,
                counters:    counters,
                detail:      request.versionKey,
                logExcerpt:  ActivityExcerpt.make(r.entries.map { ($0.text, $0.kind.activityKind) })
            ))

            guard notify, shouldNotify(trigger: .manual, outcome: outcome) else { return }
            BackupNotifier.notify(
                title: L("notify.restore_title"),
                body:  L("notify.restore_body", request.label, r.stats.restored, r.stats.errors))
        }
    }

    // MARK: - Queue

    /// One summary event per queue run. The individual profiles have already recorded
    /// their own `.backup` events (with trigger `.queued`), so this only adds the roll-up.
    static func recordQueue(_ queue: BackupQueue,
                            trigger: ActivityEvent.Trigger,
                            startedAt: Date,
                            activity: ActivityLog) {

        let outcome: ActivityEvent.Outcome
        if queue.status == .cancelled      { outcome = .cancelled }
        else if queue.failedCount > 0      { outcome = .failed }
        else                               { outcome = .done }

        var counters = ActivityEvent.Counters()
        counters.itemsDone   = queue.doneCount
        counters.itemsFailed = queue.failedCount

        activity.append(ActivityEvent(
            startedAt:   startedAt,
            kind:        .queue,
            trigger:     trigger,
            profileId:   nil,
            profileName: L("activity.kind.queue"),
            label:       "",
            outcome:     outcome,
            counters:    counters,
            detail:      "\(queue.doneCount)/\(queue.items.count)"
        ))

        BackupNotifier.notify(title: L("notify.queue_title"),
                              body:  L("notify.queue_body", queue.doneCount, queue.failedCount))
    }

    // MARK: - Policy

    private static func backupOutcome(_ r: BackupRunner) -> ActivityEvent.Outcome {
        switch r.status {
        case .done:      return r.wasFullBackup ? .done : .skipped
        case .cancelled: return .cancelled
        default:         return .failed
        }
    }

    /// Scheduled runs always notify — they happen while the user is elsewhere.
    /// Manual runs only notify when the app isn't frontmost (the sheet already shows the
    /// result), except failures, which are worth interrupting for. Cancellations never
    /// notify: the user just did it.
    private static func shouldNotify(trigger: ActivityEvent.Trigger,
                                     outcome: ActivityEvent.Outcome) -> Bool {
        guard outcome != .cancelled else { return false }
        switch trigger {
        case .scheduled: return true
        case .queued:    return false          // the queue summary notifies instead
        case .manual:    return outcome == .failed || !NSApp.isActive
        }
    }
}

// MARK: - Log kind bridging
//
// The two runners each declare their own nested LogEntry.Kind. They're structurally
// identical but distinct types, so each gets a small mapping rather than a shared
// protocol that would buy nothing.

extension BackupRunner.LogEntry.Kind {
    var activityKind: ActivityEvent.LogLine.Kind {
        switch self {
        case .info:    return .info
        case .success: return .success
        case .warning: return .warning
        case .error:   return .error
        }
    }
}

extension RestoreRunner.LogEntry.Kind {
    var activityKind: ActivityEvent.LogLine.Kind {
        switch self {
        case .info:    return .info
        case .success: return .success
        case .warning: return .warning
        case .error:   return .error
        }
    }
}
