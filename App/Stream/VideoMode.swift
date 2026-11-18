//
//  VideoMode.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// How the window presents the stream picture.
///
/// `sideBySide3D` keeps the host's 32:9 side-by-side frame but shows the left
/// half to the left eye and the right half to the right eye, so the picture
/// fuses into a single 16:9 3D image.
enum VideoMode: Equatable {
    case standard2D
    case sideBySide3D
}

enum StreamPictureGeometry {
    /// A stream at least this wide is plausibly packed side-by-side. 32:9 is
    /// 3.56; a 21:9 ultrawide (2.33) stays mono.
    static let packedAspectThreshold: Double = 3.0

    /// True when a frame is the usual 32:9 side-by-side layout holding both
    /// eyes in one picture.
    static func isSideBySideFrame(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return abs(Double(width) / Double(height) - 32.0 / 9.0) < 0.01
    }

    static func isPackedFrame(aspect: Double) -> Bool {
        aspect.isFinite && aspect >= packedAspectThreshold
    }

    /// Packed detection with the user's explicit "Packed SBS Input" assertion:
    /// it extends the automatic 32:9 rule to any 3:1-or-wider frame, but never
    /// claims a normal wide picture.
    static func isPackedStream(width: Int, height: Int, allowWide: Bool) -> Bool {
        guard width > 0, height > 0 else { return false }
        if allowWide, isPackedFrame(aspect: Double(width) / Double(height)) {
            return true
        }
        return isSideBySideFrame(width: width, height: height)
    }

    /// Height ÷ width of the plane the window shows.
    static func planeHeightToWidth(
        width: Int,
        height: Int,
        mode: VideoMode,
        assumePacked: Bool = false
    ) -> Double {
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        if mode == .sideBySide3D,
           assumePacked || isSideBySideFrame(width: width, height: height) {
            return Double(height) / (Double(width) / 2)
        }
        return Double(height) / Double(width)
    }

    /// Width ÷ height of the picture the window shows.
    ///
    /// A host sends 32:9 side-by-side 3D as one frame holding both eyes, so in
    /// 3D the window must use one eye's half-width aspect. Every other frame
    /// keeps its own aspect; the SBS material still samples the halves, exactly
    /// like the core client.
    static func aspectRatio(width: Int, height: Int, mode: VideoMode) -> Double {
        1 / planeHeightToWidth(width: width, height: height, mode: mode)
    }
}
