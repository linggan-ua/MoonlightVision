//
//  MoonlightVisionApp.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import SwiftUI

@main
// The vendored Core Data model defines an Objective-C class named `App`,
// which collides with SwiftUI's `App` protocol in the bridging header.
struct MoonlightVisionApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HostListView()
        }

        Window("Stream", id: "stream") {
            StreamWindowRootView()
        }
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1280, height: 720)

        Window("Keyboard", id: "stream-keyboard") {
            StreamKeyboardWindowView()
        }
        .defaultSize(width: 800, height: 410)
        .defaultWindowPlacement { _, context in
            if let stream = context.windows.first(where: { $0.id == "stream" }) {
                return WindowPlacement(.below(stream))
            }
            return WindowPlacement(.none)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        #if DEBUG
        Window("Stream UI Preview", id: "stream-preview") {
            StreamChromePreview()
        }
        .windowStyle(.plain)
        .defaultLaunchBehavior(
            ProcessInfo.processInfo.arguments.contains("-streamPreview") ? .presented : .suppressed
        )
        .defaultSize(width: 1280, height: 720)
        #endif
    }
}
