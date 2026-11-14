//
//  StreamPresentation.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Observation

/// Owns the single active stream, like Starlight's StreamController. The host
/// view asks it to start; the stream window asks it to close. No other view
/// mutates the session or calls stop directly.
@MainActor
@Observable
final class StreamPresentation {
    static let shared = StreamPresentation()

    private(set) var session: StreamSessionModel?

    private init() {}

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
