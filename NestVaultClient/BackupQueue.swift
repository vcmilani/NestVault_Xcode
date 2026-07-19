import Foundation

@MainActor
final class BackupQueue: ObservableObject {

    // MARK: - State

    @Published var items: [QueueItem] = []
    @Published var currentIndex: Int = -1
    @Published var status: QueueStatus = .idle
    @Published var currentRunner: BackupRunner?

    enum QueueStatus { case idle, running, done, cancelled }

    struct QueueItem: Identifiable {
        let id   = UUID()
        let profile: BackupProfile
        var status:  ItemStatus = .waiting

        enum ItemStatus { case waiting, running, done, failed, cancelled, skipped }

        var icon: String {
            switch status {
            case .waiting:   return "clock"
            case .running:   return "arrow.up.circle.fill"
            case .done:      return "checkmark.circle.fill"
            case .failed:    return "xmark.circle.fill"
            case .cancelled: return "stop.circle.fill"
            case .skipped:   return "minus.circle"
            }
        }
    }

    private let api: APIService
    private var isCancelled = false

    init(api: APIService, profiles: [BackupProfile]) {
        self.api   = api
        self.items = profiles.map { QueueItem(profile: $0) }
    }

    // MARK: - Run

    func run() async {
        guard !items.isEmpty else { return }
        status      = .running
        isCancelled = false
        currentIndex = -1

        for i in items.indices {
            guard !isCancelled else {
                markFrom(index: i, as: .cancelled)
                break
            }

            currentIndex = i
            items[i].status = .running
            DockProgress.shared.setBadge("\(i + 1)/\(items.count)")

            let runner = BackupRunner(api: api)
            currentRunner = runner
            await runner.run(profile: items[i].profile)

            switch runner.status {
            case .done:      items[i].status = .done
            case .failed:    items[i].status = .failed
            case .cancelled: items[i].status = .cancelled
            default:         items[i].status = .failed
            }

            if isCancelled { markFrom(index: i + 1, as: .cancelled); break }
        }

        currentRunner = nil
        currentIndex  = -1
        status = isCancelled ? .cancelled : .done
        DockProgress.shared.update(progress: nil)
    }

    func cancel() {
        guard status == .running else { return }
        isCancelled = true
        currentRunner?.cancel()
    }

    // MARK: - Helpers

    private func markFrom(index: Int, as s: QueueItem.ItemStatus) {
        for i in index..<items.count { items[i].status = s }
    }

    var doneCount:    Int { items.filter { $0.status == .done }.count }
    var failedCount:  Int { items.filter { $0.status == .failed }.count }
    var currentProfile: BackupProfile? {
        items.indices.contains(currentIndex) ? items[currentIndex].profile : nil
    }
    var progress: Double {
        guard !items.isEmpty else { return 0 }
        let base = Double(currentIndex < 0 ? 0 : currentIndex)
        let sub  = currentRunner?.progress ?? 0
        return (base + sub) / Double(items.count)
    }
}
