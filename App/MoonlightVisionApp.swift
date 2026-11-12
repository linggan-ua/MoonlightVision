//
//  MoonlightVisionApp.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

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
    }
}
