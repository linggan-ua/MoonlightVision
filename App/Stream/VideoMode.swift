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
    /// True when a frame is the usual 32:9 side-by-side layout holding both
    /// eyes in one picture.
    static func isSideBySideFrame(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return abs(Double(width) / Double(height) - 32.0 / 9.0) < 0.01
    }

    /// Height ÷ width of the plane the window shows.
    static func planeHeightToWidth(width: Int, height: Int, mode: VideoMode) -> Double {
        guard width > 0, height > 0 else { return 9.0 / 16.0 }
        if mode == .sideBySide3D, isSideBySideFrame(width: width, height: height) {
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
