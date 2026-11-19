//
//  StreamHDRTrimState.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// Thread-safe HDR trims shared by the session model (writer, main actor) and
/// the decoder's VideoToolbox render thread (reader).
final class StreamHDRTrimState: @unchecked Sendable {
    private let lock = NSLock()
    private var sdrBrightness: Float = 1.0
    private var highlightHeadroom: Float = 2.0

    var sdrSnapshot: Float {
        lock.lock()
        defer { lock.unlock() }
        return sdrBrightness
    }

    var headroomSnapshot: Float {
        lock.lock()
        defer { lock.unlock() }
        return highlightHeadroom
    }

    func setSDRBrightness(_ value: Float) {
        lock.lock()
        sdrBrightness = min(max(value, 0.1), 3.0)
        lock.unlock()
    }

    func setHighlightHeadroom(_ value: Float) {
        lock.lock()
        highlightHeadroom = min(max(value, 1.0), 8.0)
        lock.unlock()
    }
}
