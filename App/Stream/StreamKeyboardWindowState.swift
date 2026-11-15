//
//  StreamKeyboardWindowState.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Observation

/// Shared state for the auxiliary keyboard window. `wantsKeyboard` is the
/// user's intent and keeps the control-bar toggle in sync with the window.
@MainActor
@Observable
final class StreamKeyboardWindowState {
    static let shared = StreamKeyboardWindowState()

    var wantsKeyboard = false

    private init() {}
}
