import Foundation

// MARK: - Autopilot
// Time-based scheduler for the autonomous pipeline. Where PlaybookEngine reacts
// to what's ON the screen, Autopilot fires playbooks the user should get without
// looking at anything: a morning brief, periodic email triage, and meeting prep
// shortly before each event. Every fire goes through PlaybookEngine.runManually
// with a synthetic PlaybookContext, so the output is a reviewable draft like any
// other — Autopilot itself can't send, post, or delete anything.
//
// Schedules:
//   • morning-brief — checked every 5 min; fires once per calendar day between
//     07:00 and 12:00 local, only when the local model is ready (needs MCP tools).
//     The fired day persists in UserDefaults so relaunches don't double-brief.
//   • email-triage  — every 30 min (first fire ~3 min after start), only when
//     the local model is ready; skipped silently otherwise.
//   • meeting-prep  — every 60 s scan of CalendarEngine.upcomingMeetings; any
//     meeting starting within 15 min fires once (in-memory prepped set; the
//     engine's per-eventId cooldown is a second line of defense).
//   • follow-up-chaser — checked every 5 min; fires once per calendar day
//     between 09:30 and 13:00 local (same success-only day-slot persistence
//     as morning-brief). Local model required.
//   • pr-radar        — every 45 min (first fire ~5 min after start), only
//     when the local model is ready; skipped silently otherwise.
//   • schedule-guard  — checked every 5 min; once per day, 15:00–19:00 local.
//   • evening-wrapup  — checked every 5 min; once per day, 17:00–21:00 local.
//
// All fires are gated on PlaybookEngine.isEnabled(playbookId) at fire time, so
// a toggle in settings takes effect immediately.

@MainActor
final class Autopilot {
    static let shared = Autopilot()

    // ── Debug state ─────────────────────────────────
    private(set) var lastFired: [String: Date] = [:]

    // ── Private state ───────────────────────────────
    private var started = false
    private var timers: [Timer] = []
    private var preppedEventIds: Set<String> = []
    // Day (yyyy-MM-dd) we already logged a morning-brief skip for, so an
    // unconfigured install logs the reason once per day instead of every 5 min.
    private var morningBriefSkipLogDay: String?
    // A morning-brief run is in flight (fired, completion not yet reported).
    // The daily slot is burned in the completion ON SUCCESS ONLY — a transient
    // failure at 7:05 (network down) must not cost the whole morning — so this
    // flag keeps the 5-minute tick from double-firing while a run is pending.
    private var morningBriefInFlight = false
    // Same two roles as the morning-brief fields above, for the other windowed
    // dailies (keyed by playbook id): once-per-day skip logging and in-flight
    // latches so the shared 5-minute tick can't double-fire a pending run.
    private var dailySkipLogDay: [String: String] = [:]
    private var dailyInFlight: Set<String> = []

    // Playbook ids (owned by DefaultPlaybooks; integrator reconciles).
    private static let morningBriefId   = "morning-brief"
    private static let emailTriageId    = "email-triage"
    private static let meetingPrepId    = "meeting-prep"
    private static let followUpChaserId = "follow-up-chaser"
    private static let prRadarId        = "pr-radar"
    private static let scheduleGuardId  = "schedule-guard"
    private static let eveningWrapupId  = "evening-wrapup"

    private static let morningBriefLastDayKey = "holmes.autopilot.morningbrief.lastDay"

    // Once-per-day windowed playbooks beyond morning-brief. Each mirrors the
    // morning-brief pattern exactly: checked on the shared 5-minute timer,
    // fires anywhere inside its local window, day slot persisted ON SUCCESS
    // ONLY so transient failures retry on the next tick.
    private struct DailySchedule {
        let playbookId: String
        let windowTitle: String
        let lastDayKey: String
        let startMinute: Int  // minutes since local midnight, inclusive
        let endMinute: Int    // exclusive
    }

    private static let dailySchedules: [DailySchedule] = [
        DailySchedule(
            playbookId: followUpChaserId,
            windowTitle: "Follow-up Chaser",
            lastDayKey: "holmes.autopilot.followup.lastDay",
            startMinute: 9 * 60 + 30,   // 09:30
            endMinute: 13 * 60          // 13:00
        ),
        DailySchedule(
            playbookId: scheduleGuardId,
            windowTitle: "Schedule Guard",
            lastDayKey: "holmes.autopilot.scheduleguard.lastDay",
            startMinute: 15 * 60,       // 15:00
            endMinute: 19 * 60          // 19:00
        ),
        DailySchedule(
            playbookId: eveningWrapupId,
            windowTitle: "Evening Wrap-up",
            lastDayKey: "holmes.autopilot.wrapup.lastDay",
            startMinute: 17 * 60,       // 17:00
            endMinute: 21 * 60          // 21:00
        ),
    ]

    // Schedule intervals (seconds).
    private static let morningBriefCheckInterval: TimeInterval = 5 * 60
    private static let emailTriageInterval: TimeInterval = 30 * 60
    private static let emailTriageInitialDelay: TimeInterval = 3 * 60
    private static let meetingPrepScanInterval: TimeInterval = 60
    private static let meetingPrepWindowMinutes: Double = 15
    private static let prRadarInterval: TimeInterval = 45 * 60
    private static let prRadarInitialDelay: TimeInterval = 5 * 60

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        print("[Holmes] Autopilot started — morning brief (5m check), email triage (30m), meeting prep (60s scan), follow-up/schedule-guard/wrap-up (5m windowed checks), PR radar (45m)")

        // All timers go on RunLoop.main in .common mode: .default-mode timers are
        // suspended during event-tracking (open status-item menus, window drags,
        // scroll momentum), which would silently stall the schedules.

        // Morning brief + the other once-per-day windows: check immediately
        // (launching inside a window should fire right away, not 5 minutes
        // later), then every 5 minutes. The engine is single-flight, so when
        // two windows overlap (schedule-guard/evening-wrapup 17:00–19:00) the
        // second simply retries on a later tick.
        morningBriefTick()
        for schedule in Self.dailySchedules { dailyTick(schedule) }
        let briefTimer = Timer(timeInterval: Self.morningBriefCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.morningBriefTick()
                for schedule in Self.dailySchedules { self.dailyTick(schedule) }
            }
        }
        RunLoop.main.add(briefTimer, forMode: .common)
        timers.append(briefTimer)

        // Email triage: first fire ~3 minutes after start (lets MCP/engines
        // settle), then every 30 minutes.
        let triageTimer = Timer(
            fire: Date().addingTimeInterval(Self.emailTriageInitialDelay),
            interval: Self.emailTriageInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emailTriageTick()
            }
        }
        RunLoop.main.add(triageTimer, forMode: .common)
        timers.append(triageTimer)

        // PR radar: first fire ~5 minutes after start (lets MCP settle and
        // staggers it away from email triage's ~3-minute first fire), then
        // every 45 minutes.
        let prRadarTimer = Timer(
            fire: Date().addingTimeInterval(Self.prRadarInitialDelay),
            interval: Self.prRadarInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.prRadarTick()
            }
        }
        RunLoop.main.add(prRadarTimer, forMode: .common)
        timers.append(prRadarTimer)

        // Meeting prep: scan immediately, then every 60 seconds.
        meetingPrepTick()
        let prepTimer = Timer(timeInterval: Self.meetingPrepScanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.meetingPrepTick()
            }
        }
        RunLoop.main.add(prepTimer, forMode: .common)
        timers.append(prepTimer)
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        started = false
    }

    // MARK: - Morning brief (once per day, 07:00–12:00 local, local model required)

    private func morningBriefTick() {
        guard !morningBriefInFlight else { return }
        let today = Self.dayString(Date())
        guard UserDefaults.standard.string(forKey: Self.morningBriefLastDayKey) != today else { return }

        // autoupdatingCurrent: a long-running Holmes must follow timezone
        // changes (travel) — Calendar.current freezes the zone at first access.
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: Date())
        guard hour >= 7 && hour < 12 else { return }

        // This playbook needs the local model + MCP (real calendar/email data); the local
        // model can't fetch anything, so skip — but keep retrying through the
        // window in case Ollama comes up mid-morning.
        guard OllamaConfig.isConfigured else {
            if morningBriefSkipLogDay != today {
                morningBriefSkipLogDay = today
                print("[Holmes] Autopilot: morning brief skipped — local model not ready (will keep checking until 12:00)")
            }
            return
        }
        guard PlaybookEngine.isEnabled(Self.morningBriefId) else {
            if morningBriefSkipLogDay != today {
                morningBriefSkipLogDay = today
                print("[Holmes] Autopilot: morning brief skipped — playbook disabled")
            }
            return
        }
        // Another playbook mid-run: runManually would drop the fire, so don't
        // burn today's slot — the next 5-minute check retries.
        guard !PlaybookEngine.shared.isExecuting else { return }

        // Burn today's slot only when the run actually produced a draft: a
        // transient failure (network still reconnecting after wake, API error)
        // retries on the next 5-minute tick instead of skipping the whole day.
        morningBriefInFlight = true
        fire(playbookId: Self.morningBriefId, windowTitle: "Morning Brief", entities: [:]) { [weak self] success in
            self?.morningBriefInFlight = false
            if success {
                UserDefaults.standard.set(Self.dayString(Date()), forKey: Self.morningBriefLastDayKey)
            }
        }
    }

    // MARK: - Email triage (every 30 min, local model required)

    private func emailTriageTick() {
        // Needs GMAIL_FETCH_EMAILS via MCP — without the model there is nothing to
        // triage, so skip silently (this runs 48 times a day).
        guard OllamaConfig.isConfigured else { return }
        guard PlaybookEngine.isEnabled(Self.emailTriageId) else { return }
        guard !PlaybookEngine.shared.isExecuting else { return }  // retry in 30 min

        fire(playbookId: Self.emailTriageId, windowTitle: "Email Triage", entities: [:])
    }

    // MARK: - Meeting prep (any meeting starting within 15 min, once per event)

    private func meetingPrepTick() {
        guard PlaybookEngine.isEnabled(Self.meetingPrepId) else { return }
        // The engine runs one playbook at a time and runManually drops fires
        // while busy — don't mark a meeting prepped we couldn't actually fire.
        guard !PlaybookEngine.shared.isExecuting else { return }

        for meeting in CalendarEngine.shared.upcomingMeetings
        where meeting.minutesUntil <= Self.meetingPrepWindowMinutes {
            guard !preppedEventIds.contains(meeting.id) else { continue }
            preppedEventIds.insert(meeting.id)
            fire(
                playbookId: Self.meetingPrepId,
                windowTitle: "Meeting Prep",
                entities: ["eventTitle": meeting.title, "eventId": meeting.id]
            )
            break  // one fire per scan — the engine is single-flight anyway
        }
    }

    // MARK: - Windowed dailies (follow-up chaser, schedule guard, evening wrap-up)
    // Same shape as morningBriefTick — driven by the shared 5-minute timer,
    // fires once per calendar day anywhere inside the schedule's local window,
    // and burns the day slot ON SUCCESS ONLY so a transient failure retries on
    // the next tick instead of costing the whole window.

    private func dailyTick(_ schedule: DailySchedule) {
        guard !dailyInFlight.contains(schedule.playbookId) else { return }
        let today = Self.dayString(Date())
        guard UserDefaults.standard.string(forKey: schedule.lastDayKey) != today else { return }

        // autoupdatingCurrent: a long-running Holmes must follow timezone
        // changes (travel) — Calendar.current freezes the zone at first access.
        let now = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: Date())
        let minuteOfDay = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        guard minuteOfDay >= schedule.startMinute && minuteOfDay < schedule.endMinute else { return }

        // These playbooks need the local model + MCP (Gmail/Calendar/GitHub data). Without
        // a key there is nothing to fall back to, so skip — but keep retrying
        // through the window in case Ollama comes up mid-window.
        guard OllamaConfig.isConfigured else {
            if dailySkipLogDay[schedule.playbookId] != today {
                dailySkipLogDay[schedule.playbookId] = today
                print("[Holmes] Autopilot: \(schedule.playbookId) skipped — local model not ready (will keep checking through the window)")
            }
            return
        }
        guard PlaybookEngine.isEnabled(schedule.playbookId) else {
            if dailySkipLogDay[schedule.playbookId] != today {
                dailySkipLogDay[schedule.playbookId] = today
                print("[Holmes] Autopilot: \(schedule.playbookId) skipped — playbook disabled")
            }
            return
        }
        // Another playbook mid-run: runManually would drop the fire, so don't
        // burn today's slot — the next 5-minute check retries.
        guard !PlaybookEngine.shared.isExecuting else { return }

        // Burn today's slot only when the run actually produced a result: a
        // transient failure retries on the next 5-minute tick instead of
        // skipping the whole day.
        dailyInFlight.insert(schedule.playbookId)
        fire(playbookId: schedule.playbookId, windowTitle: schedule.windowTitle, entities: [:]) { [weak self] success in
            self?.dailyInFlight.remove(schedule.playbookId)
            if success {
                UserDefaults.standard.set(Self.dayString(Date()), forKey: schedule.lastDayKey)
            }
        }
    }

    // MARK: - PR radar (every 45 min, local model required)

    private func prRadarTick() {
        // Needs GitHub via MCP — without the model there is nothing to scan, so
        // skip silently (this runs 32 times a day).
        guard OllamaConfig.isConfigured else { return }
        guard PlaybookEngine.isEnabled(Self.prRadarId) else { return }
        guard !PlaybookEngine.shared.isExecuting else { return }  // retry in 45 min

        fire(playbookId: Self.prRadarId, windowTitle: "PR Radar", entities: [:])
    }

    // MARK: - Manual / test hook (also wired to "Run now" in Settings)
    // Mirrors the schedule paths but skips the time-window / dedupe brakes.
    // Still isEnabled-gated, and a SUCCESSFUL once-per-day playbook (morning
    // brief, follow-up chaser, schedule guard, evening wrap-up) still burns
    // today's slot so a manual fire and the scheduled one can't double-fire
    // the same day.

    func fireNow(_ playbookId: String) {
        guard PlaybookEngine.isEnabled(playbookId) else {
            print("[Holmes] Autopilot fireNow('\(playbookId)') skipped — playbook disabled")
            return
        }

        switch playbookId {
        case Self.morningBriefId:
            guard OllamaConfig.isConfigured else {
                print("[Holmes] Autopilot fireNow('\(playbookId)') skipped — local model not ready")
                return
            }
            morningBriefInFlight = true
            fire(playbookId: playbookId, windowTitle: "Morning Brief", entities: [:]) { [weak self] success in
                self?.morningBriefInFlight = false
                if success {
                    UserDefaults.standard.set(Self.dayString(Date()), forKey: Self.morningBriefLastDayKey)
                }
            }

        case Self.emailTriageId:
            guard OllamaConfig.isConfigured else {
                print("[Holmes] Autopilot fireNow('\(playbookId)') skipped — local model not ready")
                return
            }
            fire(playbookId: playbookId, windowTitle: "Email Triage", entities: [:])

        case Self.meetingPrepId:
            if let meeting = CalendarEngine.shared.upcomingMeetings.first {
                preppedEventIds.insert(meeting.id)
                fire(
                    playbookId: playbookId,
                    windowTitle: "Meeting Prep",
                    entities: ["eventTitle": meeting.title, "eventId": meeting.id]
                )
            } else {
                print("[Holmes] Autopilot fireNow('\(playbookId)') — no upcoming meeting, firing without event context")
                fire(playbookId: playbookId, windowTitle: "Meeting Prep", entities: [:])
            }

        case Self.followUpChaserId, Self.scheduleGuardId, Self.eveningWrapupId:
            guard OllamaConfig.isConfigured else {
                print("[Holmes] Autopilot fireNow('\(playbookId)') skipped — local model not ready")
                return
            }
            guard let schedule = Self.dailySchedules.first(where: { $0.playbookId == playbookId }) else {
                print("[Holmes] Autopilot fireNow: no schedule for '\(playbookId)'")
                return
            }
            dailyInFlight.insert(playbookId)
            fire(playbookId: playbookId, windowTitle: schedule.windowTitle, entities: [:]) { [weak self] success in
                self?.dailyInFlight.remove(playbookId)
                if success {
                    UserDefaults.standard.set(Self.dayString(Date()), forKey: schedule.lastDayKey)
                }
            }

        case Self.prRadarId:
            guard OllamaConfig.isConfigured else {
                print("[Holmes] Autopilot fireNow('\(playbookId)') skipped — local model not ready")
                return
            }
            fire(playbookId: playbookId, windowTitle: "PR Radar", entities: [:])

        default:
            print("[Holmes] Autopilot fireNow: unknown playbookId '\(playbookId)'")
        }
    }

    // MARK: - Shared fire path

    private func fire(playbookId: String, windowTitle: String, entities: [String: String], onCompletion: ((Bool) -> Void)? = nil) {
        let ctx = PlaybookContext(
            appName: "Autopilot",
            windowTitle: windowTitle,
            contextType: "scheduled",
            screenText: "",
            entities: entities
        )
        lastFired[playbookId] = Date()
        print("[Holmes] Autopilot firing '\(playbookId)' (\(windowTitle))")
        // runManually shares the engine's per-context cooldown when the context
        // yields a match key (meeting-prep's eventId), so an Autopilot fire and
        // a screen-path fire can never double-prep the same meeting.
        PlaybookEngine.shared.runManually(playbookId: playbookId, context: ctx, onCompletion: onCompletion)
    }

    // MARK: - Day formatting (local calendar day, stable across locales)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // autoupdatingCurrent: .current freezes the zone the process launched
        // in, which can double-brief (or silently skip) a day after travel.
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
}
