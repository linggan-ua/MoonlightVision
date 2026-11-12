//
//  HostListModel.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import Observation

@MainActor
@Observable
final class HostListModel {
    private(set) var hosts: [TemporaryHost] = []
    private(set) var isDiscovering = false

    private var dataManager: DataManager?
    private var discoveryManager: DiscoveryManager?
    private var discoveryDelegate: DiscoveryDelegate?

    func start() {
        guard dataManager == nil else { return }

        let dataManager = DataManager()
        self.dataManager = dataManager
        hosts = (dataManager.getHosts() as? [TemporaryHost]) ?? []

        let delegate = DiscoveryDelegate { [weak self] hosts in
            Task { @MainActor in
                self?.hosts = hosts
            }
        }
        discoveryDelegate = delegate

        let discoveryManager = DiscoveryManager(hosts: hosts, andCallback: delegate)
        self.discoveryManager = discoveryManager
        discoveryManager?.startDiscovery()
        isDiscovering = true
    }

    func refresh() {
        stop()
        start()
    }

    func stop() {
        discoveryManager?.stopDiscovery()
        discoveryManager = nil
        discoveryDelegate = nil
        isDiscovering = false
    }
}

/// ObjC discovery callbacks can arrive on any thread; this object forwards
/// them as a plain Swift closure and lets the model hop back to the main actor.
final class DiscoveryDelegate: NSObject, DiscoveryCallback {
    private let onChange: ([TemporaryHost]) -> Void

    init(onChange: @escaping ([TemporaryHost]) -> Void) {
        self.onChange = onChange
    }

    func updateAllHosts(_ hosts: [Any]!) {
        onChange((hosts as? [TemporaryHost]) ?? [])
    }
}
