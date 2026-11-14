//
//  StreamPresentation.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Observation

/// The one active stream, shared between the host session and the dedicated
/// stream window. visionOS windows cannot carry a reference type directly, so
/// the window reads the session from here.
@MainActor
@Observable
final class StreamPresentation {
    static let shared = StreamPresentation()

    var session: StreamSessionModel?

    private init() {}
}
