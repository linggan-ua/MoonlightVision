//
//  StreamPresentation.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Observation

/// Owns the single active stream, like a stream controller. The host
/// view asks it to start; the stream window asks it to close. No other view
/// mutates the session or calls stop directly.
@MainActor
@Observable
final class StreamPresentation {
    static let shared = StreamPresentation()

    private(set) var session: StreamSessionModel?

    /// Set when the standalone settings window closed with changes that only
    /// take effect on reconnect. The stream window watches this and offers the
    /// restart, since the settings window itself is gone by then.
    private(set) var restartRecommended = false

    private init() {}

    func requestRestart() {
        restartRecommended = true
    }

    func clearRestartRequest() {
        restartRecommended = false
    }

    /// Starts a new session unless one is already active. Returns true when a
    /// new session was created.
    @discardableResult
    func start(host: TemporaryHost, app: TemporaryApp) -> Bool {
        if let existing = session {
            if case .ended = existing.phase {
                existing.stop()
                session = nil
            } else {
                return false
            }
        }
        session = StreamSessionModel(host: host, app: app)
        return true
    }

    /// Stops and clears the active session. Safe to call more than once.
    func close() {
        let active = session
        session = nil
        active?.stop()
    }
}
