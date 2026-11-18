//
//  StreamFrameMailbox.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

@preconcurrency import RealityKit
import os

/// Hand-off between the decode thread and RealityKit's update loop.
///
/// The decoder publishes the queue its drawable came from; the view binds that
/// queue to its `TextureResource` on the next update. `OSAllocatedUnfairLock`
/// keeps the hand-off to a few nanoseconds so a 120 Hz update never misses a
/// frame to lock contention.
final class StreamFrameMailbox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<TextureResource.DrawableQueue?>(initialState: nil)

    func deposit(_ queue: TextureResource.DrawableQueue) {
        lock.withLock { $0 = queue }
    }

    func collect() -> TextureResource.DrawableQueue? {
        lock.withLock {
            let queue = $0
            $0 = nil
            return queue
        }
    }

    func clear() {
        lock.withLock { $0 = nil }
    }
}
