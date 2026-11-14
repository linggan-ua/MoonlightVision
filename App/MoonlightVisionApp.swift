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
