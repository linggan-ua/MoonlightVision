//
//  StreamLocalCursor.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import CoreGraphics
import Observation

/// Local cursor overlay published by the input strategy and drawn by the
/// RealityKit video surface. The position is normalised in the picture rect
/// (0…1, origin at the top-left of the video).
@MainActor
@Observable
final class StreamLocalCursor {
    var position = CGPoint(x: 0.5, y: 0.5)
    /// True while the mouse is captured; the surface also checks the user's
    /// "Show Local Cursor" setting.
    var visible = false
}
