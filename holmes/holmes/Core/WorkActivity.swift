import Foundation
import Observation

/// One owner for each piece of work. A nested model request may update its
/// caller's activity, but only the caller ends that activity.
enum WorkActivityScope {
    @TaskLocal static var id: UUID?
}

@MainActor
@Observable
final class WorkActivityCenter {
    static let shared = WorkActivityCenter()

    enum Origin: Sendable { case user, background }
    enum Phase: Sendable {
        case preparing, queued, working, waitingForUser, listening, transcribing, speaking

        var label: String {
            switch self {
            case .preparing: return "Preparing"
            case .queued: return "Waiting for the local model"
            case .working: return "Working"
            case .waitingForUser: return "Waiting for your review"
            case .listening: return "Listening"
            case .transcribing: return "Finishing your words"
            case .speaking: return "Speaking"
            }
        }

        var symbol: String {
            switch self {
            case .preparing: return "sparkles"
            case .queued: return "clock"
            case .working: return "sparkles"
            case .waitingForUser: return "person.crop.circle.badge.questionmark"
            case .listening: return "mic.fill"
            case .transcribing: return "waveform"
            case .speaking: return "speaker.wave.2.fill"
            }
        }
    }
    enum Outcome: Sendable { case success, failure, cancelled }

    struct Activity: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        var detail: String
        let origin: Origin
        var phase: Phase
        var progress: Double?
        let sequence: UInt64
    }

    struct Completion: Equatable, Sendable {
        let id: UUID
        let outcome: Outcome
        let summary: String
        let origin: Origin
        let revision: UInt64
    }

    private(set) var activities: [Activity] = []
    private(set) var completion: Completion?
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var cancellationHandlers: [UUID: @MainActor () -> Void] = [:]

    /// The AppKit/Combine notch projects changes synchronously. Awaiting this
    /// main-actor mutation preserves queued → working → terminal ordering.
    @ObservationIgnored var onChange: (() -> Void)?

    var activeCount: Int { activities.count }
    var selectedActivity: Activity? {
        // Explicit work remains visible while unrelated background requests
        // finish. FIFO within each origin prevents flicker between concurrent
        // requests as their individual model turns complete.
        activities.first(where: { $0.origin == .user }) ?? activities.first
    }

    init() {}

    @discardableResult
    func begin(title: String, detail: String = "", origin: Origin = .user) -> UUID {
        sequence &+= 1
        let id = UUID()
        activities.append(Activity(id: id, title: title, detail: detail, origin: origin,
                                   phase: .preparing, progress: nil, sequence: sequence))
        changed()
        return id
    }

    func isActive(_ id: UUID) -> Bool { activities.contains { $0.id == id } }

    func setCancellationHandler(_ id: UUID, handler: @escaping @MainActor () -> Void) {
        guard isActive(id) else { return }
        cancellationHandlers[id] = handler
    }

    func cancelSelected() {
        guard let id = selectedActivity?.id else { return }
        cancel(id, summary: "Stopped.")
    }

    func update(_ id: UUID, phase: Phase, detail: String? = nil, progress: Double? = nil) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].phase = phase
        if let detail { activities[index].detail = detail }
        activities[index].progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        changed()
    }

    func finish(_ id: UUID, outcome: Outcome, summary: String) {
        guard let activity = activities.first(where: { $0.id == id }) else { return }
        let wasSelected = selectedActivity?.id == id
        activities.removeAll { $0.id == id }
        cancellationHandlers.removeValue(forKey: id)
        // An invisible background completion cannot replace the explicit
        // request's result or flash over it. The remaining active work stays.
        if wasSelected || activity.origin == .user {
            completion = Completion(id: id, outcome: outcome, summary: summary,
                                    origin: activity.origin, revision: revision &+ 1)
        }
        changed()
    }

    func cancel(_ id: UUID, summary: String? = nil) {
        guard isActive(id) else { return }
        let handler = cancellationHandlers.removeValue(forKey: id)
        if let summary {
            finish(id, outcome: .cancelled, summary: summary)
        } else {
            activities.removeAll { $0.id == id }
            changed()
        }
        handler?()
    }

    /// Sleep/shutdown discard the old epoch. UUID ownership makes every late
    /// update/completion harmless, including work finishing after a new wake.
    func invalidateAll() {
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        activities.removeAll()
        completion = nil
        changed()
        handlers.forEach { $0() }
    }

    private func changed() {
        revision &+= 1
        onChange?()
    }
}
