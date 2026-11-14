import Foundation

/// Serializes stream starts against in-flight stops.
///
/// A stop holds the gate closed until LiStopConnection() has actually returned.
/// Starting a new session while an old one is still tearing down races the
/// common-c global state, which shows up as black screens and initLock timeouts.
final class StreamStartGate {
    static let shared = StreamStartGate()

    private let lock = NSLock()
    private var stopping = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func beginStop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    func endStop() {
        lock.lock()
        guard stopping else {
            lock.unlock()
            return
        }
        stopping = false
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func waitUntilStartable() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopping {
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }
}
