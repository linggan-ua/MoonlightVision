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
    private(set) var boxArtToken = 0
    var showHiddenApps = false

    private let discovery: DiscoveryManager?
    private let dataManager = DataManager()
    private let pairingFactory: PairingSessionFactory
    private var pairingFlow: PairingFlow?
    private var assetManager: AppAssetManager?
    private var assetDelegate: AppAssetDelegate?
    private var started = false

    init(host: TemporaryHost,
         discovery: DiscoveryManager?,
         pairingFactory: PairingSessionFactory = LimelightPairingSessionFactory()) {
        self.host = host
        self.discovery = discovery
        self.pairingFactory = pairingFactory
    }

    var hostName: String {
        host.name
    }

    var runningAppID: String? {
        guard let current = host.currentGame, !current.isEmpty, current != "0" else {
            return nil
        }
        return current
    }

    var displayedApps: [TemporaryApp] {
        showHiddenApps ? apps : apps.filter { !$0.hidden }
    }

    func toggleHidden(_ app: TemporaryApp) {
        app.hidden.toggle()
        apps = Array(apps)
        dataManager.updateApps(forExisting: host)
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
        let info = await fetchServerInfo()
        if info.isStatusOk() {
            info.populateHost(host)
            dataManager.update(host)
        }
        await loadApps()
    }

    /// Asks the host to quit whatever app is currently running and waits for its
    /// state to leave SERVER_BUSY before a new launch is attempted.
    func quitCurrentApp() async -> Bool {
        guard let http = HttpManager(host: host) else { return false }
        let response = HttpResponse()
        let request = HttpRequest(for: response, with: http.newQuitAppRequest())

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                http.executeRequestSynchronously(request)
                continuation.resume()
            }
        }

        guard response.statusCode == 200 else { return false }

        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(750))
            let info = await fetchServerInfo()
            guard info.isStatusOk() else { continue }
            info.populateHost(host)
            if host.currentGame == "0" || (host.currentGame?.isEmpty ?? true) {
                dataManager.update(host)
                return true
            }
        }
        return false
    }

    // MARK: - Server info

    private func checkHost() async {
        phase = .checking

        let response = await fetchServerInfo()
        guard response.isStatusOk() else {
            phase = .failed(response.statusMessage ?? String(localized: "Could not reach the host."))
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
            phase = .failed(String(localized: "Could not create the client certificate."))
            return
        }

        // Polling the host while pairing confuses Sunshine, so stop browsing first.
        let discovery = self.discovery
        await Task.detached(priority: .userInitiated) {
            discovery?.stopDiscoveryBlocking()
        }.value

        let flow = PairingFlow(factory: pairingFactory)
        flow.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handlePairingEvent(event)
            }
        }
        pairingFlow = flow
        flow.start(host: host, clientCert: clientCert)
    }

    private func handlePairingEvent(_ event: PairingFlow.Event) {
        switch event {
        case .pin(let pin):
            phase = .pairing(pin)
        case .paired(let serverCert):
            host.serverCert = serverCert
            host.pairState = .paired
            dataManager.update(host)
            discovery?.startDiscovery()
            Task { await self.loadApps() }
        case .alreadyPaired:
            host.pairState = .paired
            dataManager.update(host)
            discovery?.startDiscovery()
            Task { await self.loadApps() }
        case .failed(let message):
            discovery?.startDiscovery()
            phase = .failed(message)
        }
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
            phase = .failed(response?.statusMessage ?? String(localized: "Failed to load the app list."))
            return
        }

        mergeApps(serverApps)
        startAssetRetrieval()
        phase = .ready
    }

    private func startAssetRetrieval() {
        assetManager?.stopRetrieving()

        let delegate = AppAssetDelegate { [weak self] in
            Task { @MainActor in
                self?.boxArtToken &+= 1
            }
        }
        assetDelegate = delegate

        guard let manager = AppAssetManager(callback: delegate) else { return }
        assetManager = manager
        manager.retrieveAssets(from: host)
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

/// Forwards AppAssetManager's box-art downloads as a single change callback.
final class AppAssetDelegate: NSObject, AppAssetCallback {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func receivedAsset(for app: TemporaryApp!) {
        onChange()
    }
}
