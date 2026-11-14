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
    private(set) var discoveryManager: DiscoveryManager?

    private let dataManager = DataManager()
    private var discoveryDelegate: DiscoveryDelegate?

    func start() {
        guard discoveryManager == nil else { return }

        hosts = (dataManager.getHosts() as? [TemporaryHost]) ?? []

        let delegate = DiscoveryDelegate { [weak self] discovered in
            Task { @MainActor in
                self?.applyDiscoveredHosts(discovered)
            }
        }
        discoveryDelegate = delegate

        let manager = DiscoveryManager(hosts: hosts, andCallback: delegate)
        discoveryManager = manager
        manager?.startDiscovery()
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

    func addHost(address: String, completion: @escaping (String?) -> Void) {
        guard let manager = discoveryManager else {
            completion(String(localized: "Discovery is not running."))
            return
        }

        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(String(localized: "Enter an IP address or hostname."))
            return
        }

        // The underlying discovery call performs blocking HTTP requests. Keep
        // it off the main actor so adding a host cannot freeze the library.
        DispatchQueue.global(qos: .userInitiated).async {
            manager.discoverHost(trimmed, withCallback: { [weak self] host, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let host {
                        if !self.hosts.contains(where: { $0.uuid == host.uuid }) {
                            self.hosts.append(host)
                        }
                        self.dataManager.update(host)
                        completion(nil)
                    } else {
                        completion(error ?? String(localized: "Host not found."))
                    }
                }
            })
        }
    }

    func wakeHost(_ host: TemporaryHost) {
        WakeOnLanManager.wake(host)
    }

    func deleteHost(_ host: TemporaryHost) {
        discoveryManager?.removeHost(fromDiscovery: host)
        dataManager.remove(host)
        hosts.removeAll { $0 === host }
    }

    func renameHost(_ host: TemporaryHost, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        host.name = trimmed
        dataManager.update(host)
        hosts = Array(hosts)
    }

    /// DiscoveryManager already merges address/state fields in place and hands
    /// back its canonical TemporaryHost objects, so use that snapshot directly
    /// instead of copying fields (which could clobber persisted values).
    private func applyDiscoveredHosts(_ discovered: [TemporaryHost]) {
        let known = Set(hosts.map { $0.uuid })
        hosts = discovered
        for host in discovered {
            if known.contains(host.uuid) {
                continue
            }
            dataManager.update(host)
        }
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
