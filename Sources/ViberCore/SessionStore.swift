// Copied from claude-cache/Sources/CompanionCore/SessionStore.swift. Keep in sync by hand.
import Foundation

public struct Alert: Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let projectPath: String
}

public struct SessionStore {
    public private(set) var sessions: [String: Session] = [:]
    private var stateEvents: [String: Date] = [:]
    private var cacheMessages: [String: Date] = [:]
    public init() {}

    public mutating func apply(_ incoming: Event) {
        var event = incoming
        var session = sessions[event.sessionID] ?? Session(id: event.sessionID, project: event.project, lastActivity: event.time)
        if event.genericPermissionNotice, [.input, .plan].contains(session.state) {
            // Delayed generic permission notifications must not create a second alert for the
            // same question/plan dialog whose more specific request was already observed.
            event.state = session.state
        }
        if event.time >= session.lastActivity {
            session.lastActivity = event.time
            session.project = event.project
        }
        if let path = event.transcriptPath { session.transcriptPath = path }
        if let automated = event.automatedTurn, event.time >= session.turnStartedAt {
            session.automatedTurn = automated
            session.turnStartedAt = event.time
        }
        if let ttl = event.cacheTTL {
            let message = event.messageID ?? event.id
            let key = "\(event.sessionID):\(message)"
            let firstObserved = cacheMessages[key] ?? event.time
            cacheMessages[key] = firstObserved
            // Streaming transcript rows can share a message ID. They must not restart the clock.
            if message != session.lastCacheMessage, firstObserved >= session.cacheMessageAt {
                session.lastCacheMessage = message
                session.cacheMessageAt = firstObserved
                session.cache = CacheEstimate(observedAt: firstObserved, ttl: ttl,
                    basis: event.cacheBasis ?? "Assumed TTL", generation: message)
            } else if message == session.lastCacheMessage, let basis = event.cacheBasis, !basis.hasPrefix("TTL unavailable") {
                session.cache?.ttl = ttl
                session.cache?.basis = basis
            }
        }
        let stateKey = "\(event.sessionID):\(event.id):\(event.state?.rawValue ?? "")"
        if let state = event.state, event.time >= session.stateAt,
           stateEvents[stateKey] == nil || state == session.state {
            // The same tool request may arrive through a hook and transcript with different timestamps.
            // Upgrade evidence without downgrading a hook-confirmed state to an inference.
            if state != session.state || event.id != session.stateEventID || !event.estimated {
                let sameState = state == session.state
                session.estimatedState = sameState ? session.estimatedState && event.estimated : event.estimated
                session.state = state
                session.stateAt = event.time
                session.stateEventID = event.id
            }
            stateEvents[stateKey] = event.time
        }
        sessions[event.sessionID] = session
    }

    public mutating func prune(at now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastActivity) < 2 * 86_400 }
        stateEvents = stateEvents.filter { now.timeIntervalSince($0.value) < 2 * 86_400 }
        cacheMessages = cacheMessages.filter { now.timeIntervalSince($0.value) < 2 * 86_400 }
    }
}

/// Persisted notification receipts survive restart. Bootstrap never replays historical state alerts.
public struct AlertLedger: Codable {
    public var receipts: [String: Date] = [:]
    public init() {}
    public mutating func alerts(previous: [String: Session], current: [String: Session],
                                now: Date, threshold: TimeInterval, bootstrap: Bool) -> [Alert] {
        receipts = receipts.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }
        var alerts: [Alert] = []
        for session in current.values where session.isRecent(at: now) {
            if !bootstrap, previous[session.id]?.state != session.state,
               session.state.alerts, now.timeIntervalSince(session.stateAt) < 120,
               // Replies to agent reports finish turns the user did not start; only alert if they need the user.
               !(session.automatedTurn && session.state == .finished) {
                let key = "state:\(session.id):\(session.state.rawValue):\(session.stateEventID)"
                // Cross-source duplicates may briefly pass through working. Coalesce within 10s.
                let cooldown = "cooldown:\(session.id):\(session.state.rawValue)"
                if receipts[key] == nil, now.timeIntervalSince(receipts[cooldown] ?? .distantPast) > 10 {
                    receipts[key] = now
                    receipts[cooldown] = now
                    alerts.append(Alert(id: key, title: "Claude: \(session.state.rawValue)",
                                        body: "\(session.projectName)\(session.estimatedState ? " — estimated from activity" : " — hook observed")",
                                        projectPath: session.project))
                }
            }
            if let cache = session.cache {
                let remaining = cache.remaining(at: now)
                let key = "cache:\(session.id):\(cache.generation)"
                if remaining > 0, remaining <= threshold, receipts[key] == nil {
                    // Mark a currently-low cache on launch as seen, avoiding startup floods.
                    receipts[key] = now
                    if !bootstrap {
                        alerts.append(Alert(id: key, title: "Claude cache may expire soon",
                            body: "\(session.projectName): about \(max(1, Int(ceil(remaining / 60))))m remaining (estimated).",
                            projectPath: session.project))
                    }
                }
            }
        }
        return alerts
    }
}
