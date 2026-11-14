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
    private var savedHostIDs = Set<String>()

    func start() {
        guard discoveryManager == nil else { return }

        hosts = (dataManager.getHosts() as? [TemporaryHost]) ?? []
        savedHostIDs = Set(hosts.map { $0.uuid })

        let delegate = DiscoveryDelegate { [weak self] discovered in
            Task { @MainActor in
                self?.upsert(discovered)
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
                        self.upsert([host])
                        self.dataManager.update(host)
                        self.savedHostIDs.insert(host.uuid)
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

    /// Discovery hands us fresh TemporaryHost objects. Merge them into the existing
    /// objects by UUID so the certificate, app list, and other persisted fields survive.
    private func upsert(_ discovered: [TemporaryHost]) {        var merged = hosts

        for newHost in discovered {
            if let existing = merged.first(where: { $0.uuid == newHost.uuid }) {
                existing.state = newHost.state
                existing.name = newHost.name
                existing.address = newHost.address ?? existing.address
                existing.localAddress = newHost.localAddress ?? existing.localAddress
                existing.externalAddress = newHost.externalAddress ?? existing.externalAddress
                existing.ipv6Address = newHost.ipv6Address ?? existing.ipv6Address
                existing.activeAddress = newHost.activeAddress ?? existing.activeAddress
                existing.mac = newHost.mac ?? existing.mac
                existing.httpsPort = newHost.httpsPort
            } else {
                merged.append(newHost)
                dataManager.update(newHost)
                savedHostIDs.insert(newHost.uuid)
            }
        }

        hosts = merged
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
