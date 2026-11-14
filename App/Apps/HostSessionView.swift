//
//  HostSessionView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI
import UIKit

struct HostSessionView: View {
    @Environment(\.openWindow) private var openWindow

    @State private var model: HostSessionModel
    @State private var pendingApp: TemporaryApp?
    @State private var showQuitConfirm = false
    @State private var actionError: String?

    init(host: TemporaryHost, discovery: DiscoveryManager?) {
        _model = State(initialValue: HostSessionModel(host: host, discovery: discovery))
    }

    var body: some View {
        content
            .navigationTitle(model.hostName)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.refreshApps() }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await model.start() }
        .confirmationDialog(
            "Another app is running",
            isPresented: $showQuitConfirm,
            titleVisibility: .visible
        ) {
            Button("Quit Running App and Start", role: .destructive) {
                startAfterQuitting()
            }
            Button("Cancel", role: .cancel) {
                pendingApp = nil
            }
        } message: {
            Text("Close the app that is currently running on the host, then start this one.")
        }
        .alert("Could Not Start", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .checking:
            ProgressView("Connecting to \(model.hostName)…")
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pairing(let pin):
            PairingView(pin: pin)
        case .loadingApps:
            ProgressView("Loading apps…")
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            AppsListView(
                apps: model.displayedApps,
                runningAppID: model.runningAppID,
                boxArtToken: model.boxArtToken,
                onLaunch: requestLaunch,
                onQuitRunningApp: { Task { _ = await model.quitCurrentApp() } },
                onRefresh: { await model.refreshApps() }
            )
        case .failed(let message):
            VStack(spacing: 15) {
                Label("Offline", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button {
                    model.retry()
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                Button {
                    WakeOnLanManager.wake(model.host)
                } label: {
                    Label("Wake PC", systemImage: "sun.horizon")
                }
                .disabled(model.host.mac == nil || model.host.mac == "00:00:00:00:00:00")
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private func requestLaunch(_ app: TemporaryApp) {
        if let running = model.runningAppID, running != app.id {
            pendingApp = app
            showQuitConfirm = true
        } else {
            startStream(app)
        }
    }

    private func startAfterQuitting() {
        guard let app = pendingApp else { return }
        pendingApp = nil
        Task {
            let quit = await model.quitCurrentApp()
            if quit {
                startStream(app)
            } else {
                actionError = String(localized: "The host is still running another app. Quit it on the PC or try again.")
            }
        }
    }

    private func startStream(_ app: TemporaryApp) {
        guard StreamPresentation.shared.session == nil else {
            openWindow(id: "stream")
            return
        }
        StreamPresentation.shared.session = StreamSessionModel(host: model.host, app: app)
        openWindow(id: "stream")
    }
}

private struct PairingView: View {
    let pin: String

    var body: some View {
        VStack(spacing: 15) {
            Label("Ready to pair", systemImage: "lock.desktopcomputer")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Enter this PIN in Sunshine on your PC to accept the pairing request.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text(pin)
                .font(.system(size: 48, weight: .semibold, design: .monospaced))
                .tracking(8)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AppsListView: View {
    let apps: [TemporaryApp]
    let runningAppID: String?
    let boxArtToken: Int
    let onLaunch: (TemporaryApp) -> Void
    let onQuitRunningApp: () -> Void
    let onRefresh: () async -> Void

    var body: some View {
        Group {
            if apps.isEmpty {
                ContentUnavailableView {
                    Label("No apps available", systemImage: "square.grid.2x2")
                } description: {
                    Text("Add apps in Sunshine on your PC, then refresh.")
                } actions: {
                    Button("Refresh") {
                        Task { await onRefresh() }
                    }
                }
            } else {
                List {
                    ForEach(apps, id: \.id) { app in
                        Button {
                            onLaunch(app)
                        } label: {
                            AppRow(
                                app: app,
                                isRunning: app.id == runningAppID,
                                boxArtToken: boxArtToken
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if app.id == runningAppID {
                                Button(role: .destructive, action: onQuitRunningApp) {
                                    Label("Stop", systemImage: "stop.circle")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .refreshable {
                    await onRefresh()
                }
            }
        }
    }
}

private struct AppRow: View {
    let app: TemporaryApp
    let isRunning: Bool
    let boxArtToken: Int

    private var boxArt: UIImage? {
        let path: String = AppAssetManager.boxArtPath(for: app)
        return UIImage(contentsOfFile: path)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                if let boxArt {
                    Image(uiImage: boxArt)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "app.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .id(boxArtToken)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name ?? String(localized: "Unknown App"))
                    .font(.body)
                if app.hdrSupported {
                    Text("HDR")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isRunning {
                Text("Running")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.2), in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
