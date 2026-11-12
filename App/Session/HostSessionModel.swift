//
//  HostSessionModel.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import Observation

/// Drives one host through server-info → pairing (if needed) → app list.
@MainActor
@Observable
final class HostSessionModel {
    enum Phase: Equatable {
        case checking
        case pairing(String)
        case loadingApps
        case ready
        case failed(String)
    }

    let host: TemporaryHost

    private(set) var phase: Phase = .checking
    private(set) var apps: [TemporaryApp] = []

    private let discovery: DiscoveryManager?
    private let dataManager = DataManager()
    private let operationQueue = OperationQueue()
    private var pairingDelegate: PairingDelegate?
    private var pairManager: PairManager?
    private var started = false

    init(host: TemporaryHost, discovery: DiscoveryManager?) {
        self.host = host
        self.discovery = discovery
    }

    var hostName: String {
        host.name
    }

    func start() async {
        guard !started else { return }
        started = true
        await checkHost()
    }

    func retry() {
        started = false
        Task { await start() }
    }

    func refreshApps() async {
        guard phase == .ready else { return }
        await loadApps()
    }

    // MARK: - Server info

    private func checkHost() async {
        phase = .checking

        let response = await fetchServerInfo()
        guard response.isStatusOk() else {
            phase = .failed(response.statusMessage ?? "Could not reach the host.")
            return
        }

        response.populateHost(host)
        host.state = .online
        dataManager.update(host)

        if host.pairState == .paired {
            await loadApps()
        } else {
            await pair()
        }
    }

    private func fetchServerInfo() async -> ServerInfoResponse {
        guard let http = HttpManager(host: host) else {
            return ServerInfoResponse()
        }
        let response = ServerInfoResponse()
        let request = HttpRequest(for: response,
                                  with: http.newServerInfoRequest(false),
                                  fallbackError: 401,
                                  fallbackRequest: http.newHttpServerInfoRequest())

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                http.executeRequestSynchronously(request)
                continuation.resume()
            }
        }
        return response
    }

    // MARK: - Pairing

    private func pair() async {
        guard let clientCert = await ClientCertificateStore.shared.certificate() else {
            phase = .failed("Could not create the client certificate.")
            return
        }

        // Polling the host while pairing confuses Sunshine, so stop browsing first.
        let discovery = self.discovery
        await Task.detached(priority: .userInitiated) {
            discovery?.stopDiscoveryBlocking()
        }.value

        guard let http = HttpManager(host: host) else {
            phase = .failed("Could not create the HTTP client.")
            return
        }
        let delegate = PairingDelegate()
        delegate.onPIN = { [weak self] pin in
            Task { @MainActor in
                self?.phase = .pairing(pin)
            }
        }
        delegate.onPaired = { [weak self] serverCert in
            Task { @MainActor in
                guard let self else { return }
                self.host.serverCert = serverCert
                self.host.pairState = .paired
                self.dataManager.update(self.host)
                self.discovery?.startDiscovery()
                await self.loadApps()
            }
        }
        delegate.onAlreadyPaired = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.host.pairState = .paired
                self.dataManager.update(self.host)
                self.discovery?.startDiscovery()
                await self.loadApps()
            }
        }
        delegate.onFailed = { [weak self] message in
            Task { @MainActor in
                self?.discovery?.startDiscovery()
                self?.phase = .failed(message)
            }
        }

        pairingDelegate = delegate
        guard let manager = PairManager(manager: http, clientCert: clientCert, callback: delegate) else {
            phase = .failed("Could not start pairing.")
            return
        }
        pairManager = manager
        operationQueue.addOperation(manager)
    }

    // MARK: - App list

    private func loadApps() async {
        phase = .loadingApps
        discovery?.pauseDiscovery(for: host)

        let host = self.host
        let response: AppListResponse? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ConnectionHelper.getAppList(for: host))
            }
        }

        discovery?.resumeDiscovery(for: host)

        guard let response, response.isStatusOk(),
              let serverApps = response.getAppList() as? Set<TemporaryApp> else {
            phase = .failed(response?.statusMessage ?? "Failed to load the app list.")
            return
        }

        mergeApps(serverApps)
        phase = .ready
    }

    private func mergeApps(_ serverApps: Set<TemporaryApp>) {
        var merged: [TemporaryApp] = host.appList.compactMap { $0 as? TemporaryApp }

        for serverApp in serverApps {
            if let index = merged.firstIndex(where: { $0.id == serverApp.id }) {
                let existing = merged[index]
                existing.name = serverApp.name
                existing.hdrSupported = serverApp.hdrSupported
                existing.installPath = serverApp.installPath
                existing.host = host
            } else {
                serverApp.host = host
                merged.append(serverApp)
            }
        }

        let serverIDs = Set(serverApps.compactMap { $0.id })
        let removed = merged.filter { app in
            guard let id = app.id else { return false }
            return !serverIDs.contains(id)
        }
        for app in removed {
            merged.removeAll { $0 === app }
            dataManager.remove(app)
        }

        host.appList = Set(merged.map { $0 as AnyHashable })
        dataManager.updateApps(forExisting: host)

        apps = merged.sorted {
            ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
        }
    }
}

/// Forwards PairManager callbacks (delivered on its operation queue) as closures.
final class PairingDelegate: NSObject, PairCallback {
    var onPIN: ((String) -> Void)?
    var onPaired: ((Data) -> Void)?
    var onAlreadyPaired: (() -> Void)?
    var onFailed: ((String) -> Void)?

    func startPairing(_ PIN: String!) {
        onPIN?(PIN ?? "")
    }

    func pairSuccessful(_ serverCert: Data!) {
        guard let serverCert else {
            onFailed?("The host returned an invalid certificate.")
            return
        }
        onPaired?(serverCert)
    }

    func pairFailed(_ message: String!) {
        onFailed?(message ?? "Pairing failed.")
    }

    func alreadyPaired() {
        onAlreadyPaired?()
    }
}
